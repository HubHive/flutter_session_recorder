import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'recorder_event.dart';
import 'replay_document.dart';
import 'session_batch.dart';
import 'session_recorder_config.dart';
import 'session_recorder_native_bridge.dart';
import 'session_recorder_transport.dart';
import 'session_snapshot.dart';

typedef ScreenViewListener = void Function(
  String screenName,
  Map<String, Object?> properties,
);

typedef CaptureStateListener = void Function(bool isPaused);

class SessionRecorder {
  SessionRecorder({
    this.config = const SessionRecorderConfig(),
    String Function()? idGenerator,
    SessionRecorderNativeBridge? nativeBridge,
    DateTime Function()? now,
    this.transport = const NoopSessionRecorderTransport(),
  })  : _idGenerator = idGenerator ?? _defaultIdGenerator,
        _nativeBridge =
            nativeBridge ?? MethodChannelSessionRecorderNativeBridge(),
        _now = now ?? DateTime.now;

  final SessionRecorderConfig config;
  final String Function() _idGenerator;
  final SessionRecorderNativeBridge _nativeBridge;
  final DateTime Function() _now;
  final SessionRecorderTransport transport;

  final List<RecorderEvent> _buffer = <RecorderEvent>[];
  final List<SessionSnapshotUpload> _pendingSnapshotUploads =
      <SessionSnapshotUpload>[];
  final List<RecorderEvent> _sessionHistory = <RecorderEvent>[];
  final List<CaptureStateListener> _captureStateListeners =
      <CaptureStateListener>[];
  final List<ScreenViewListener> _screenViewListeners = <ScreenViewListener>[];

  Timer? _flushTimer;
  Timer? _recordingAccessCheckTimer;
  Timer? _snapshotUploadTimer;
  StreamSubscription<Map<String, Object?>>? _nativeEventSubscription;
  DateTime? _pausedAt;
  bool _isCheckingRecordingAccess = false;
  bool _isRecordingAccessDenied = false;
  bool _isCapturePaused = false;
  bool _isFlushing = false;
  bool _isUploadingSnapshots = false;
  bool _nativeSnapshotCaptureRequested = false;
  int _pendingSnapshotUploadBytes = 0;
  Future<void>? _snapshotUploadInFlight;
  String? _sessionId;
  Map<String, Object?> _sessionContext = <String, Object?>{};
  Map<String, Object?> _sessionProperties = <String, Object?>{};
  DateTime? _startedAt;
  String? _userId;
  Map<String, Object?> _userProperties = <String, Object?>{};

  bool get isRecording => _sessionId != null;

  bool get isCapturePaused => _isCapturePaused;

  bool get isRecordingAccessDenied => _isRecordingAccessDenied;

  String? get sessionId => _sessionId;

  String? get userId => _userId;

  Map<String, Object?> get userProperties =>
      Map<String, Object?>.unmodifiable(_userProperties);

  void addScreenViewListener(ScreenViewListener listener) {
    if (_screenViewListeners.contains(listener)) {
      return;
    }
    _screenViewListeners.add(listener);
  }

  void removeScreenViewListener(ScreenViewListener listener) {
    _screenViewListeners.remove(listener);
  }

  void addCaptureStateListener(CaptureStateListener listener) {
    if (_captureStateListeners.contains(listener)) {
      return;
    }
    _captureStateListeners.add(listener);
  }

  void removeCaptureStateListener(CaptureStateListener listener) {
    _captureStateListeners.remove(listener);
  }

  ReplayDocument? buildReplayDocument() {
    final String? sessionId = _sessionId;
    final DateTime? startedAt = _startedAt;
    if (sessionId == null || startedAt == null) {
      return null;
    }

    final ReplayAssembler assembler = ReplayAssembler()
      ..addAll(_sessionHistory);
    return assembler.build(
      sessionId: sessionId,
      sessionContext: Map<String, Object?>.from(_sessionContext),
      startedAt: startedAt,
      sessionProperties: Map<String, Object?>.from(_sessionProperties),
      userId: _userId,
      userProperties: Map<String, Object?>.from(_userProperties),
    );
  }

  Future<void> start({
    Map<String, Object?> sessionProperties = const <String, Object?>{},
    bool startNativeSnapshots = true,
    String? userId,
    Map<String, Object?> userProperties = const <String, Object?>{},
  }) async {
    if (isRecording) {
      return;
    }

    _sessionId = _idGenerator();
    _startedAt = _now().toUtc();
    _userId = userId;
    _userProperties = Map<String, Object?>.from(userProperties);
    _sessionContext = await _collectSessionContext();
    _sessionProperties = Map<String, Object?>.from(sessionProperties);
    _nativeSnapshotCaptureRequested = true;

    await _startNativeCapture();
    if (_nativeSnapshotCaptureRequested && startNativeSnapshots) {
      await _startNativeSnapshotCapture();
    }
    _startFlushTimer();

    _enqueue(
      RecorderEvent(
        type: 'session.started',
        timestamp: _startedAt,
        attributes: <String, Object?>{
          'sessionId': _sessionId,
          'sessionContext': _sessionContext,
          'userId': _userId,
          'userProperties': _userProperties,
          'sessionProperties': _sessionProperties,
        },
      ),
    );
  }

  Future<void> stop({
    Map<String, Object?> endProperties = const <String, Object?>{},
  }) async {
    if (!isRecording) {
      return;
    }

    _flushTimer?.cancel();
    _flushTimer = null;
    _recordingAccessCheckTimer?.cancel();
    _recordingAccessCheckTimer = null;
    await _stopNativeCapture();
    await _flushSnapshotUploads();
    _nativeSnapshotCaptureRequested = false;

    _enqueue(
      RecorderEvent(
        type: 'session.stopped',
        attributes: <String, Object?>{
          'sessionId': _sessionId,
          'endProperties': endProperties,
        },
      ),
      allowWhilePaused: true,
    );

    try {
      await flush();
    } finally {
      _buffer.clear();
      _clearPendingSnapshotUploads();
      _sessionHistory.clear();
      _pausedAt = null;
      _sessionId = null;
      _isRecordingAccessDenied = false;
      _isCheckingRecordingAccess = false;
      _isCapturePaused = false;
      _sessionContext = <String, Object?>{};
      _startedAt = null;
      _sessionProperties = <String, Object?>{};
      _userId = null;
      _userProperties = <String, Object?>{};
    }
  }

  Future<void> identify(
    String userId, {
    Map<String, Object?> userProperties = const <String, Object?>{},
  }) {
    return setUser(
      userId,
      userProperties: userProperties,
    );
  }

  Future<void> setUser(
    String? userId, {
    Map<String, Object?> userProperties = const <String, Object?>{},
    bool splitSessionOnChange = true,
  }) async {
    if (!isRecording) {
      return;
    }

    final Map<String, Object?> nextUserProperties =
        Map<String, Object?>.from(userProperties);
    final String? currentUserId = _userId;
    final bool isSameUser = currentUserId == userId;

    if (!isSameUser && splitSessionOnChange && currentUserId != null) {
      await _restartSession(
        endProperties: <String, Object?>{
          'reason': userId == null ? 'user_cleared' : 'user_changed',
          'nextUserId': userId,
        },
        nextUserId: userId,
        nextUserProperties: nextUserProperties,
      );
      return;
    }

    _userId = userId;
    if (userId == null) {
      _userProperties = nextUserProperties;
    } else if (isSameUser) {
      _userProperties = <String, Object?>{
        ..._userProperties,
        ...nextUserProperties,
      };
    } else {
      _userProperties = nextUserProperties;
    }

    _enqueue(
      RecorderEvent(
        type: userId == null ? 'user.cleared' : 'user.identified',
        attributes: <String, Object?>{
          'userId': userId,
          'userProperties': _userProperties,
        },
      ),
    );
    await flush();
  }

  Future<void> startNewSession({
    Map<String, Object?> endProperties = const <String, Object?>{},
    Map<String, Object?> nextSessionProperties = const <String, Object?>{},
  }) async {
    if (!isRecording) {
      await start(
        sessionProperties: nextSessionProperties,
        userId: _userId,
        userProperties: _userProperties,
      );
      return;
    }

    _sessionProperties = <String, Object?>{
      ..._sessionProperties,
      ...nextSessionProperties,
    };

    await _restartSession(
      endProperties: <String, Object?>{
        'reason': 'manual_restart',
        ...endProperties,
      },
      nextUserId: _userId,
      nextUserProperties: _userProperties,
      restartCaptureIfNeeded: !_isCapturePaused,
    );
  }

  Future<void> pauseCapture({
    String reason = 'app_backgrounded',
  }) async {
    if (!isRecording || _isCapturePaused) {
      return;
    }

    _isCapturePaused = true;
    _pausedAt = _now().toUtc();
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_nativeSnapshotCaptureRequested) {
      await _stopNativeSnapshotCapture();
    }
    await _flushSnapshotUploads();

    _enqueue(
      RecorderEvent(
        type: 'session.paused',
        timestamp: _pausedAt,
        attributes: <String, Object?>{
          'reason': reason,
          'sessionId': _sessionId,
        },
      ),
      allowWhilePaused: true,
    );
    _notifyCaptureStateListeners(isPaused: true);
    await flush();
    await _pauseNativeCapture();
  }

  Future<void> resumeCapture({
    String reason = 'app_foregrounded',
  }) async {
    if (!isRecording || !_isCapturePaused) {
      return;
    }
    if (_isRecordingAccessDenied) {
      return;
    }

    final DateTime resumedAt = _now().toUtc();
    final DateTime? pausedAt = _pausedAt;
    final Duration? pausedDuration =
        pausedAt == null ? null : resumedAt.difference(pausedAt);
    final Duration? timeout = config.backgroundSessionTimeout;
    final bool shouldSplitSession =
        timeout != null && pausedDuration != null && pausedDuration >= timeout;

    if (shouldSplitSession) {
      _isCapturePaused = false;
      _pausedAt = null;
      await _restartSession(
        endProperties: <String, Object?>{
          'reason': 'background_timeout',
          'pausedDurationMs': pausedDuration.inMilliseconds,
        },
        nextUserId: _userId,
        nextUserProperties: _userProperties,
        restartCaptureIfNeeded: true,
      );
      return;
    }

    _isCapturePaused = false;
    _pausedAt = null;
    await _resumeNativeCapture();
    _notifyCaptureStateListeners(isPaused: false);
    _startFlushTimer();
    _enqueue(
      RecorderEvent(
        type: 'session.resumed',
        timestamp: resumedAt,
        attributes: <String, Object?>{
          'reason': reason,
          'sessionId': _sessionId,
          'pausedDurationMs': pausedDuration?.inMilliseconds,
        },
      ),
      allowWhilePaused: true,
    );
  }

  Future<void> startSnapshotCapture() async {
    _nativeSnapshotCaptureRequested = true;
    if (!isRecording || _isCapturePaused || _isRecordingAccessDenied) {
      return;
    }
    await _startNativeSnapshotCapture();
  }

  Future<void> stopSnapshotCapture() async {
    _nativeSnapshotCaptureRequested = false;
    await _stopNativeSnapshotCapture();
  }

  void setUserProperties(Map<String, Object?> properties) {
    if (!isRecording) {
      return;
    }

    _userProperties = <String, Object?>{
      ..._userProperties,
      ...properties,
    };

    _enqueue(
      RecorderEvent(
        type: 'user.properties.updated',
        attributes: <String, Object?>{
          'userId': _userId,
          'userProperties': _userProperties,
        },
      ),
    );
  }

  void setSessionProperties(Map<String, Object?> properties) {
    if (!isRecording) {
      return;
    }

    _sessionProperties = <String, Object?>{
      ..._sessionProperties,
      ...properties,
    };

    _enqueue(
      RecorderEvent(
        type: 'session.properties.updated',
        attributes: <String, Object?>{'sessionProperties': _sessionProperties},
      ),
    );
  }

  void trackCustomEvent(
    String name, {
    Map<String, Object?> properties = const <String, Object?>{},
  }) {
    _enqueue(
      RecorderEvent(
        type: 'custom',
        attributes: <String, Object?>{'name': name, 'properties': properties},
      ),
    );
  }

  void trackLog({
    required String message,
    String level = 'info',
    String? logger,
    Map<String, Object?> properties = const <String, Object?>{},
  }) {
    _enqueue(
      RecorderEvent(
        type: 'log',
        attributes: <String, Object?>{
          'level': level,
          'logger': logger,
          'message': _truncateLogText(message),
          'properties': properties,
        },
      ),
    );
  }

  void trackError({
    required Object error,
    StackTrace? stackTrace,
    String? message,
    String? logger,
    Map<String, Object?> properties = const <String, Object?>{},
  }) {
    _enqueue(
      RecorderEvent(
        type: 'error',
        attributes: <String, Object?>{
          'error': _truncateLogText(error.toString()),
          'logger': logger,
          'message': message == null ? null : _truncateLogText(message),
          'properties': properties,
          'stackTrace': stackTrace == null
              ? null
              : _truncateLogText(stackTrace.toString()),
        },
      ),
    );
  }

  void trackScreenView(
    String screenName, {
    Map<String, Object?> properties = const <String, Object?>{},
  }) {
    final Map<String, Object?> normalizedProperties =
        Map<String, Object?>.from(properties);
    unawaited(_nativeBridge.setScreenName(screenName));
    _enqueue(
      RecorderEvent(
        type: 'screen.view',
        attributes: <String, Object?>{
          'screenName': screenName,
          'properties': normalizedProperties,
        },
      ),
    );
    for (final ScreenViewListener listener
        in List<ScreenViewListener>.from(_screenViewListeners)) {
      listener(screenName, normalizedProperties);
    }
  }

  void trackTap({
    required double dx,
    required double dy,
    Map<String, Object?> properties = const <String, Object?>{},
    String? screenName,
    String? target,
  }) {
    _enqueue(
      RecorderEvent(
        type: 'interaction.tap',
        attributes: <String, Object?>{
          'dx': dx,
          'dy': dy,
          'screenName': screenName,
          'target': target,
          'properties': properties,
        },
      ),
    );
  }

  void trackScroll({
    required double pixels,
    required double viewportDimension,
    required double maxScrollExtent,
    String axis = 'vertical',
    Map<String, Object?> properties = const <String, Object?>{},
    String? screenName,
  }) {
    _enqueue(
      RecorderEvent(
        type: 'interaction.scroll',
        attributes: <String, Object?>{
          'axis': axis,
          'maxScrollExtent': maxScrollExtent,
          'pixels': pixels,
          'screenName': screenName,
          'viewportDimension': viewportDimension,
          'properties': properties,
        },
      ),
    );
  }

  Future<void> trackNativeSnapshot({
    required String filePath,
    required String snapshotId,
    required DateTime timestamp,
    required int width,
    required int height,
    required String format,
    required String contentType,
    String? screenName,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    final String? activeSessionId = _sessionId;
    if (activeSessionId == null ||
        _isCapturePaused ||
        _isRecordingAccessDenied) {
      await _deleteFileQuietly(File(filePath));
      return;
    }

    final File file = File(filePath);
    if (!await file.exists()) {
      return;
    }

    final List<int> bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      await _deleteFileQuietly(file);
      return;
    }
    await _deleteFileQuietly(file);

    final Map<String, Object?> sessionContext =
        Map<String, Object?>.from(_sessionContext);
    final Map<String, Object?> sessionProperties =
        Map<String, Object?>.from(_sessionProperties);
    final String? userId = _userId;
    final Map<String, Object?> userProperties =
        Map<String, Object?>.from(_userProperties);

    final SessionSnapshotUpload upload = SessionSnapshotUpload(
      bytes: bytes,
      contentType: contentType,
      filename: '$snapshotId.$format',
      format: format,
      height: height,
      metadata: metadata,
      screenName: screenName,
      sessionContext: sessionContext,
      sessionId: activeSessionId,
      sessionProperties: sessionProperties,
      snapshotId: snapshotId,
      timestamp: timestamp,
      userId: userId,
      userProperties: userProperties,
      width: width,
    );

    _queueSnapshotUpload(upload);
  }

  void _queueSnapshotUpload(SessionSnapshotUpload upload) {
    if (!isRecording || _isCapturePaused || _isRecordingAccessDenied) {
      return;
    }

    _pendingSnapshotUploads.add(upload);
    _pendingSnapshotUploadBytes += upload.bytes.length;

    final int maxBatchSize = config.maxSnapshotUploadBatchSize;
    final int maxBatchBytes = config.maxSnapshotUploadBatchBytes;
    if ((maxBatchSize > 0 && _pendingSnapshotUploads.length >= maxBatchSize) ||
        (maxBatchBytes > 0 && _pendingSnapshotUploadBytes >= maxBatchBytes)) {
      unawaited(_flushSnapshotUploads());
      return;
    }

    _startSnapshotUploadTimer();
  }

  void _startSnapshotUploadTimer() {
    if (_snapshotUploadTimer != null ||
        _pendingSnapshotUploads.isEmpty ||
        _isRecordingAccessDenied) {
      return;
    }

    _snapshotUploadTimer = Timer(config.snapshotUploadFlushInterval, () {
      _snapshotUploadTimer = null;
      unawaited(_flushSnapshotUploads());
    });
  }

  Future<void> _flushSnapshotUploads() async {
    if (_isUploadingSnapshots) {
      await _snapshotUploadInFlight;
      if (_isRecordingAccessDenied || _pendingSnapshotUploads.isEmpty) {
        return;
      }
    }
    if (_isRecordingAccessDenied || _pendingSnapshotUploads.isEmpty) {
      return;
    }

    _snapshotUploadTimer?.cancel();
    _snapshotUploadTimer = null;

    final List<SessionSnapshotUpload> uploads =
        List<SessionSnapshotUpload>.from(_pendingSnapshotUploads);
    _pendingSnapshotUploads.clear();
    _pendingSnapshotUploadBytes = 0;
    _isUploadingSnapshots = true;
    final Future<void> inFlight = _uploadSnapshotBatch(uploads);
    _snapshotUploadInFlight = inFlight;
    try {
      await inFlight;
    } finally {
      if (identical(_snapshotUploadInFlight, inFlight)) {
        _snapshotUploadInFlight = null;
      }
      _isUploadingSnapshots = false;
    }

    if (_pendingSnapshotUploads.isNotEmpty) {
      _startSnapshotUploadTimer();
    }
  }

  Future<void> _uploadSnapshotBatch(
    List<SessionSnapshotUpload> uploads,
  ) async {
    late final List<UploadedSnapshot> uploadedSnapshots;
    try {
      uploadedSnapshots = await transport.uploadSnapshots(uploads);
    } catch (error, stackTrace) {
      if (await _handleTransportError(error)) {
        _clearPendingSnapshotUploads();
        return;
      }

      _pendingSnapshotUploads.insertAll(0, uploads);
      _pendingSnapshotUploadBytes += uploads.fold<int>(
        0,
        (int total, SessionSnapshotUpload upload) =>
            total + upload.bytes.length,
      );
      _startSnapshotUploadTimer();
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'flutter_session_recorder',
          context: ErrorDescription('while uploading a snapshot batch'),
        ),
      );
      return;
    }

    for (int index = 0; index < uploads.length; index += 1) {
      final SessionSnapshotUpload upload = uploads[index];
      final UploadedSnapshot uploadedSnapshot = index < uploadedSnapshots.length
          ? uploadedSnapshots[index]
          : UploadedSnapshot(snapshotRef: upload.snapshotId);
      if (_sessionId != upload.sessionId ||
          _isCapturePaused ||
          _isRecordingAccessDenied) {
        continue;
      }

      _enqueue(
        RecorderEvent(
          type: 'replay.snapshot',
          timestamp: upload.timestamp,
          attributes: <String, Object?>{
            'format': upload.format,
            'height': upload.height,
            'metadata': upload.metadata,
            'screenName': upload.screenName,
            'sessionContext': upload.sessionContext,
            'sessionProperties': upload.sessionProperties,
            'snapshotId': upload.snapshotId,
            'snapshotRef': uploadedSnapshot.snapshotRef,
            'userId': upload.userId,
            'userProperties': upload.userProperties,
            'width': upload.width,
          },
        ),
      );
    }
  }

  void _clearPendingSnapshotUploads() {
    _snapshotUploadTimer?.cancel();
    _snapshotUploadTimer = null;
    _pendingSnapshotUploads.clear();
    _pendingSnapshotUploadBytes = 0;
  }

  Future<void> flush() async {
    await _flushSnapshotUploads();

    final String? sessionId = _sessionId;
    final DateTime? startedAt = _startedAt;
    if (_isFlushing ||
        _isRecordingAccessDenied ||
        sessionId == null ||
        startedAt == null ||
        _buffer.isEmpty) {
      return;
    }

    _isFlushing = true;

    final List<RecorderEvent> events = List<RecorderEvent>.from(_buffer);
    _buffer.clear();

    try {
      await transport.send(
        SessionBatch(
          events: events,
          sentAt: _now().toUtc(),
          sessionId: sessionId,
          sessionContext: Map<String, Object?>.from(_sessionContext),
          sessionProperties: Map<String, Object?>.from(_sessionProperties),
          startedAt: startedAt,
          userId: _userId,
          userProperties: Map<String, Object?>.from(_userProperties),
        ),
      );
    } catch (error, stackTrace) {
      if (await _handleTransportError(error)) {
        return;
      }
      _buffer.insertAll(0, events);
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'flutter_session_recorder',
          context: ErrorDescription('while uploading a session batch'),
        ),
      );
      rethrow;
    } finally {
      _isFlushing = false;
      if (_buffer.length >= config.maxBatchSize) {
        unawaited(flush());
      }
    }
  }

  void _enqueue(
    RecorderEvent event, {
    bool allowWhilePaused = false,
  }) {
    if (!isRecording ||
        _isRecordingAccessDenied ||
        (_isCapturePaused && !allowWhilePaused)) {
      return;
    }

    _buffer.add(event);
    _sessionHistory.add(event);

    if (_buffer.length >= config.maxBatchSize) {
      unawaited(flush());
    }
  }

  void _notifyCaptureStateListeners({
    required bool isPaused,
  }) {
    for (final CaptureStateListener listener
        in List<CaptureStateListener>.from(_captureStateListeners)) {
      listener(isPaused);
    }
  }

  static String _defaultIdGenerator() {
    final int now = DateTime.now().microsecondsSinceEpoch;
    return 'session_$now';
  }

  void _startFlushTimer() {
    if (_isRecordingAccessDenied) {
      return;
    }
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(config.flushInterval, (_) {
      unawaited(flush());
    });
  }

  Future<void> _restartSession({
    required Map<String, Object?> endProperties,
    String? nextUserId,
    Map<String, Object?> nextUserProperties = const <String, Object?>{},
    bool restartCaptureIfNeeded = true,
  }) async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_nativeSnapshotCaptureRequested) {
      await _stopNativeSnapshotCapture();
    }
    await _flushSnapshotUploads();

    _enqueue(
      RecorderEvent(
        type: 'session.stopped',
        attributes: <String, Object?>{
          'sessionId': _sessionId,
          'endProperties': endProperties,
        },
      ),
    );

    await flush();

    _buffer.clear();
    _sessionHistory.clear();
    _sessionId = _idGenerator();
    _startedAt = _now().toUtc();
    _userId = nextUserId;
    _userProperties = Map<String, Object?>.from(nextUserProperties);
    _pausedAt = null;

    if (restartCaptureIfNeeded) {
      await _resumeNativeCapture();
      _notifyCaptureStateListeners(isPaused: false);
      _startFlushTimer();
    }

    _enqueue(
      RecorderEvent(
        type: 'session.started',
        timestamp: _startedAt,
        attributes: <String, Object?>{
          'sessionId': _sessionId,
          'sessionContext': _sessionContext,
          'userId': _userId,
          'userProperties': _userProperties,
          'sessionProperties': _sessionProperties,
        },
      ),
    );

    if (nextUserId != null || nextUserProperties.isNotEmpty) {
      _enqueue(
        RecorderEvent(
          type: nextUserId == null ? 'user.cleared' : 'user.identified',
          attributes: <String, Object?>{
            'userId': nextUserId,
            'userProperties': _userProperties,
          },
        ),
      );
    }
  }

  Future<bool> _handleTransportError(Object error) async {
    if (error is SessionRecorderTransportException && error.isForbidden) {
      await _enterRecordingAccessDeniedMode();
      return true;
    }
    return false;
  }

  Future<void> _enterRecordingAccessDeniedMode() async {
    if (!isRecording || _isRecordingAccessDenied) {
      return;
    }

    _isRecordingAccessDenied = true;
    _isCapturePaused = true;
    _pausedAt = _now().toUtc();
    _flushTimer?.cancel();
    _flushTimer = null;
    _clearPendingSnapshotUploads();
    _buffer.clear();
    _sessionHistory.clear();
    _notifyCaptureStateListeners(isPaused: true);
    await _pauseNativeCapture();
    _startRecordingAccessCheckTimer();
  }

  void _startRecordingAccessCheckTimer() {
    _recordingAccessCheckTimer?.cancel();
    _recordingAccessCheckTimer = Timer.periodic(
      config.recordingAccessCheckInterval,
      (_) => unawaited(_checkRecordingAccess()),
    );
  }

  Future<void> _checkRecordingAccess() async {
    if (!isRecording ||
        !_isRecordingAccessDenied ||
        _isCheckingRecordingAccess) {
      return;
    }

    _isCheckingRecordingAccess = true;
    try {
      final bool hasAccess = await transport.checkRecordingAccess();
      if (hasAccess) {
        await _restoreRecordingAccess();
      }
    } catch (error, stackTrace) {
      if (error is SessionRecorderTransportException && error.isForbidden) {
        return;
      }
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'flutter_session_recorder',
          context: ErrorDescription('while checking recording access'),
        ),
      );
    } finally {
      _isCheckingRecordingAccess = false;
    }
  }

  Future<void> _restoreRecordingAccess() async {
    if (!isRecording || !_isRecordingAccessDenied) {
      return;
    }

    final DateTime resumedAt = _now().toUtc();
    _recordingAccessCheckTimer?.cancel();
    _recordingAccessCheckTimer = null;
    _buffer.clear();
    _clearPendingSnapshotUploads();
    _sessionHistory.clear();
    _sessionId = _idGenerator();
    _startedAt = resumedAt;
    _isRecordingAccessDenied = false;
    _isCapturePaused = false;
    _pausedAt = null;
    await _resumeNativeCapture();
    _notifyCaptureStateListeners(isPaused: false);
    _startFlushTimer();
    _enqueue(
      RecorderEvent(
        type: 'session.started',
        timestamp: resumedAt,
        attributes: <String, Object?>{
          'reason': 'recording_access_restored',
          'sessionId': _sessionId,
          'sessionContext': _sessionContext,
          'userId': _userId,
          'userProperties': _userProperties,
          'sessionProperties': _sessionProperties,
        },
      ),
    );
    if (_userId != null || _userProperties.isNotEmpty) {
      _enqueue(
        RecorderEvent(
          type: _userId == null ? 'user.cleared' : 'user.identified',
          attributes: <String, Object?>{
            'userId': _userId,
            'userProperties': _userProperties,
          },
        ),
      );
    }
  }

  String _truncateLogText(String value) {
    if (value.length <= config.maxLogLength) {
      return value;
    }

    return '${value.substring(0, config.maxLogLength)}...';
  }

  Future<Map<String, Object?>> _collectSessionContext() async {
    final Map<String, Object?> deviceContext =
        await _safeCollectDeviceContext();
    final String? recordingDomain = config.recordingDomain?.trim();

    return <String, Object?>{
      if (deviceContext.isNotEmpty) 'device': deviceContext,
      if (recordingDomain != null && recordingDomain.isNotEmpty)
        'recordingDomain': recordingDomain,
    };
  }

  Future<Map<String, Object?>> _safeCollectDeviceContext() async {
    try {
      return await _nativeBridge.getDeviceContext();
    } catch (_) {
      return <String, Object?>{};
    }
  }

  Future<void> _startNativeCapture() async {
    await _nativeEventSubscription?.cancel();
    _nativeEventSubscription = _nativeBridge.eventStream.listen(
      _handleNativeEvent,
      onError: (Object error, StackTrace stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'flutter_session_recorder',
            context:
                ErrorDescription('while listening to native replay events'),
          ),
        );
      },
    );

    try {
      await _nativeBridge.startCapture(config);
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'flutter_session_recorder',
          context: ErrorDescription('while starting native capture'),
        ),
      );
    }
  }

  Future<void> _stopNativeCapture() async {
    await _stopNativeSnapshotCapture();
    try {
      await _nativeBridge.stopCapture();
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'flutter_session_recorder',
          context: ErrorDescription('while stopping native capture'),
        ),
      );
    } finally {
      _nativeEventSubscription?.resume();
      await _nativeEventSubscription?.cancel();
      _nativeEventSubscription = null;
    }
  }

  Future<void> _pauseNativeCapture() async {
    await _stopNativeSnapshotCapture();
    try {
      await _nativeBridge.pauseCapture();
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'flutter_session_recorder',
          context: ErrorDescription('while pausing native capture'),
        ),
      );
    }
  }

  Future<void> _resumeNativeCapture() async {
    if (_nativeEventSubscription == null) {
      await _startNativeCapture();
      return;
    }

    try {
      await _nativeBridge.resumeCapture(config);
      if (_nativeSnapshotCaptureRequested) {
        await _startNativeSnapshotCapture();
      }
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'flutter_session_recorder',
          context: ErrorDescription('while resuming native capture'),
        ),
      );
    }
  }

  void _handleNativeEvent(Map<String, Object?> event) {
    final String? type = event['type'] as String?;
    if (type == null || type.isEmpty) {
      return;
    }
    final Map<String, Object?> attributes = Map<String, Object?>.from(
      (event['attributes'] as Map<Object?, Object?>?) ?? <Object?, Object?>{},
    );
    final int? timestampMs = event['timestampMs'] as int?;
    if (type == 'replay.snapshot.ready') {
      unawaited(_handleNativeSnapshot(attributes, timestampMs));
      return;
    }
    if (type == 'native.snapshot_capture.error') {
      trackError(
        error: attributes['message'] ?? 'Native visual capture error',
        logger: 'native_snapshot_capture',
        properties: attributes,
      );
      return;
    }
    if (type == 'native.snapshot_capture.status') {
      return;
    }
    if (!_isSupportedNativeEventType(type)) {
      return;
    }

    _enqueue(
      RecorderEvent(
        id: event['id'] as String?,
        type: type,
        timestamp: timestampMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                timestampMs,
                isUtc: true,
              ),
        attributes: attributes,
      ),
    );
  }

  bool _isSupportedNativeEventType(String type) {
    return type == 'screen.view' ||
        type == 'interaction.tap' ||
        type == 'interaction.scroll' ||
        type == 'native.lifecycle';
  }

  Future<void> _handleNativeSnapshot(
    Map<String, Object?> attributes,
    int? fallbackTimestampMs,
  ) async {
    final String? filePath = attributes['filePath'] as String?;
    final String? snapshotId = attributes['snapshotId'] as String?;
    if (filePath == null ||
        filePath.isEmpty ||
        snapshotId == null ||
        snapshotId.isEmpty) {
      return;
    }

    final Object? timestampValue = attributes['timestampMs'];
    final int? nativeTimestampMs = timestampValue is int
        ? timestampValue
        : int.tryParse(timestampValue?.toString() ?? '');
    final int timestampMs = nativeTimestampMs ??
        fallbackTimestampMs ??
        _now().millisecondsSinceEpoch;

    await trackNativeSnapshot(
      filePath: filePath,
      snapshotId: snapshotId,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        timestampMs,
        isUtc: true,
      ),
      width: _intAttribute(attributes, 'width'),
      height: _intAttribute(attributes, 'height'),
      format: (attributes['format'] as String?) ?? 'jpg',
      contentType: (attributes['contentType'] as String?) ?? 'image/jpeg',
      screenName: attributes['screenName'] as String?,
      metadata: <String, Object?>{
        'captureStrategy':
            attributes['captureStrategy']?.toString() ?? 'native_snapshot',
        'fileSize': attributes['fileSize'],
        'platform':
            attributes['platform']?.toString() ?? defaultTargetPlatform.name,
        'sequence': attributes['sequence'],
      },
    );
  }

  Future<void> _startNativeSnapshotCapture() async {
    try {
      await _nativeBridge.startSnapshotCapture(config);
    } catch (error, stackTrace) {
      trackError(
        error: error,
        stackTrace: stackTrace,
        logger: 'native_snapshot_capture',
        message: 'Native visual capture failed to start',
        properties: <String, Object?>{
          'phase': 'start',
          'platform': defaultTargetPlatform.name,
        },
      );
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'flutter_session_recorder',
          context: ErrorDescription('while starting native visual capture'),
        ),
      );
    }
  }

  Future<void> _stopNativeSnapshotCapture() async {
    try {
      await _nativeBridge.stopSnapshotCapture();
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'flutter_session_recorder',
          context: ErrorDescription('while stopping native visual capture'),
        ),
      );
    }
  }

  int _intAttribute(Map<String, Object?> attributes, String key) {
    final Object? value = attributes[key];
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<void> _deleteFileQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
