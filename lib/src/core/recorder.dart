import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' as widgets;

import '../flutter/session_recorder_navigator_observer.dart';
import '../flutter/session_recorder_scope.dart';
import 'replay_document.dart';
import 'session_recorder.dart';
import 'session_recorder_config.dart';
import 'session_recorder_native_bridge.dart';
import 'session_recorder_transport.dart';

final Recorder recorder = Recorder._();

class Recorder with widgets.WidgetsBindingObserver {
  static const String _internalLogPrefix =
      '[flutter_session_recorder transport]';

  Recorder._();

  SessionRecorder _sessionRecorder = SessionRecorder(
    config: const SessionRecorderConfig.lightweight(),
  );
  final List<void Function(SessionRecorder recorder)> _pendingActions =
      <void Function(SessionRecorder recorder)>[];
  bool _hasPendingUserAssignment = false;
  String? _pendingUserId;
  Map<String, Object?> _pendingUserProperties = <String, Object?>{};
  DebugPrintCallback? _previousDebugPrint;
  FlutterExceptionHandler? _previousFlutterErrorHandler;
  bool _logCaptureInstalled = false;
  ui.PlatformDispatcher? _platformDispatcher;
  ui.ErrorCallback? _previousPlatformErrorHandler;
  bool _isLifecycleObserverRegistered = false;

  SessionRecorder get engine => _sessionRecorder;

  bool get isRecording => _sessionRecorder.isRecording;

  String? get sessionId => _sessionRecorder.sessionId;

  String? get userId =>
      _hasPendingUserAssignment ? _pendingUserId : _sessionRecorder.userId;

  ReplayDocument? get replayDocument => _sessionRecorder.buildReplayDocument();

  Future<void> initialize({
    SessionRecorderConfig config = const SessionRecorderConfig.lightweight(),
    SessionRecorderNativeBridge? nativeBridge,
    SessionRecorderTransport transport = const NoopSessionRecorderTransport(),
    Map<String, Object?> sessionProperties = const <String, Object?>{},
    String? userId,
    Map<String, Object?> userProperties = const <String, Object?>{},
  }) async {
    if (_sessionRecorder.isRecording) {
      await _sessionRecorder.stop();
    }

    _sessionRecorder = SessionRecorder(
      config: config,
      nativeBridge: nativeBridge,
      transport: transport,
    );
    _syncLifecycleObserver(config);
    _syncLogCapture(config);
    await _sessionRecorder.start(
      sessionProperties: sessionProperties,
      userId: userId,
      userProperties: userProperties,
    );
    await _applyPendingUserAssignmentIfNeeded();
    _flushPendingActions();
  }

  Future<void> start({
    Map<String, Object?> sessionProperties = const <String, Object?>{},
    String? userId,
    Map<String, Object?> userProperties = const <String, Object?>{},
  }) async {
    _syncLogCapture(_sessionRecorder.config);
    await _sessionRecorder.start(
      sessionProperties: sessionProperties,
      userId: userId,
      userProperties: userProperties,
    );
    await _applyPendingUserAssignmentIfNeeded();
    _flushPendingActions();
  }

  Future<void> stop({
    Map<String, Object?> endProperties = const <String, Object?>{},
  }) {
    return _sessionRecorder.stop(endProperties: endProperties);
  }

  Future<void> pauseCapture({
    String reason = 'manual_pause',
  }) {
    return _sessionRecorder.pauseCapture(reason: reason);
  }

  Future<void> resumeCapture({
    String reason = 'manual_resume',
  }) {
    return _sessionRecorder.resumeCapture(reason: reason);
  }

  Future<void> flush() {
    return _sessionRecorder.flush();
  }

  Future<void> runApp(
    widgets.Widget app, {
    SessionRecorderConfig config = const SessionRecorderConfig.lightweight(),
    SessionRecorderNativeBridge? nativeBridge,
    SessionRecorderTransport transport = const NoopSessionRecorderTransport(),
    Map<String, Object?> sessionProperties = const <String, Object?>{},
    String? userId,
    Map<String, Object?> userProperties = const <String, Object?>{},
  }) async {
    widgets.WidgetsFlutterBinding.ensureInitialized();
    if (!_sessionRecorder.isRecording) {
      await initialize(
        config: config,
        nativeBridge: nativeBridge,
        transport: transport,
        sessionProperties: sessionProperties,
        userId: userId,
        userProperties: userProperties,
      );
    } else {
      _syncLifecycleObserver(_sessionRecorder.config);
      _syncLogCapture(_sessionRecorder.config);
    }

    final widgets.Widget instrumentedApp = _wrapRootApp(app);

    try {
      widgets.runApp(instrumentedApp);
    } catch (error, stackTrace) {
      this.error(
        error,
        stackTrace: stackTrace,
        logger: 'flutter',
        message: 'Failed to start the Flutter application',
      );
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'flutter_session_recorder',
          context: ErrorDescription('while starting the Flutter application'),
        ),
      );
      rethrow;
    }
  }

  widgets.Widget _wrapRootApp(widgets.Widget app) {
    if (app is SessionRecorderScope) {
      return app;
    }

    return SessionRecorderScope(
      recorder: _sessionRecorder,
      child: app,
    );
  }

  void identify(
    String userId, {
    Map<String, Object?> userProperties = const <String, Object?>{},
  }) {
    unawaited(
      setUser(
        userId,
        userProperties: userProperties,
      ),
    );
  }

  Future<void> setUser(
    String? userId, {
    Map<String, Object?> userProperties = const <String, Object?>{},
    bool splitSessionOnChange = true,
  }) async {
    if (_sessionRecorder.isRecording) {
      await _sessionRecorder.setUser(
        userId,
        userProperties: userProperties,
        splitSessionOnChange: splitSessionOnChange,
      );
      return;
    }

    _hasPendingUserAssignment = true;
    _pendingUserId = userId;
    _pendingUserProperties = Map<String, Object?>.from(userProperties);
  }

  Future<void> clearUser({
    bool splitSessionOnChange = true,
  }) async {
    if (_sessionRecorder.isRecording) {
      await _sessionRecorder.setUser(
        null,
        splitSessionOnChange: splitSessionOnChange,
      );
      return;
    }

    _hasPendingUserAssignment = true;
    _pendingUserId = null;
    _pendingUserProperties = <String, Object?>{};
  }

  Future<void> startNewSession({
    Map<String, Object?> endProperties = const <String, Object?>{},
    Map<String, Object?> nextSessionProperties = const <String, Object?>{},
  }) {
    return _sessionRecorder.startNewSession(
      endProperties: endProperties,
      nextSessionProperties: nextSessionProperties,
    );
  }

  void setUserProperties(Map<String, Object?> properties) {
    if (_sessionRecorder.isRecording) {
      _sessionRecorder.setUserProperties(properties);
      return;
    }

    _hasPendingUserAssignment = true;
    _pendingUserProperties = <String, Object?>{
      ..._pendingUserProperties,
      ...properties,
    };
  }

  void setSessionProperties(Map<String, Object?> properties) {
    _runOrQueue(
      (SessionRecorder sessionRecorder) =>
          sessionRecorder.setSessionProperties(properties),
    );
  }

  void recordEvent(
    String name, {
    Map<String, Object?> properties = const <String, Object?>{},
  }) {
    _runOrQueue(
      (SessionRecorder sessionRecorder) =>
          sessionRecorder.trackCustomEvent(name, properties: properties),
    );
  }

  // ignore: non_constant_identifier_names
  void RecordEvent(
    String name, {
    Map<String, Object?> properties = const <String, Object?>{},
  }) {
    recordEvent(name, properties: properties);
  }

  void log(
    String message, {
    String level = 'info',
    String? logger,
    Map<String, Object?> properties = const <String, Object?>{},
  }) {
    _runOrQueue(
      (SessionRecorder sessionRecorder) => sessionRecorder.trackLog(
        level: level,
        logger: logger,
        message: message,
        properties: properties,
      ),
    );
  }

  void error(
    Object error, {
    StackTrace? stackTrace,
    String? message,
    String? logger,
    Map<String, Object?> properties = const <String, Object?>{},
  }) {
    _runOrQueue(
      (SessionRecorder sessionRecorder) => sessionRecorder.trackError(
        error: error,
        stackTrace: stackTrace,
        logger: logger,
        message: message,
        properties: properties,
      ),
    );
  }

  void trackScreenView(
    String screenName, {
    Map<String, Object?> properties = const <String, Object?>{},
  }) {
    _runOrQueue(
      (SessionRecorder sessionRecorder) =>
          sessionRecorder.trackScreenView(screenName, properties: properties),
    );
  }

  widgets.TransitionBuilder appBuilder({
    bool captureInitialScreenView = true,
    String? screenName,
  }) {
    return (widgets.BuildContext context, widgets.Widget? child) {
      return SessionRecorderScope(
        captureInitialScreenView: captureInitialScreenView,
        recorder: _sessionRecorder,
        screenName: screenName,
        child: child ?? const widgets.SizedBox.shrink(),
      );
    };
  }

  widgets.NavigatorObserver navigatorObserver() {
    return SessionRecorderNavigatorObserver(recorder: _sessionRecorder);
  }

  List<widgets.NavigatorObserver> navigatorObservers() {
    return <widgets.NavigatorObserver>[navigatorObserver()];
  }

  @visibleForTesting
  Future<void> resetForTest() async {
    if (_sessionRecorder.isRecording) {
      await _sessionRecorder.stop();
    }
    _uninstallLogCapture();
    _uninstallLifecycleObserver();
    _pendingActions.clear();
    _hasPendingUserAssignment = false;
    _pendingUserId = null;
    _pendingUserProperties = <String, Object?>{};
    _sessionRecorder = SessionRecorder(
      config: const SessionRecorderConfig.lightweight(),
    );
  }

  void _flushPendingActions() {
    if (!_sessionRecorder.isRecording || _pendingActions.isEmpty) {
      return;
    }

    final pending = List<void Function(SessionRecorder recorder)>.from(
      _pendingActions,
    );
    _pendingActions.clear();
    for (final action in pending) {
      action(_sessionRecorder);
    }
  }

  void _runOrQueue(void Function(SessionRecorder recorder) action) {
    if (_sessionRecorder.isRecording) {
      action(_sessionRecorder);
      return;
    }

    _pendingActions.add(action);
  }

  Future<void> _applyPendingUserAssignmentIfNeeded() async {
    if (!_hasPendingUserAssignment || !_sessionRecorder.isRecording) {
      return;
    }

    final String? pendingUserId = _pendingUserId;
    final Map<String, Object?> pendingUserProperties =
        Map<String, Object?>.from(_pendingUserProperties);

    _hasPendingUserAssignment = false;
    _pendingUserId = null;
    _pendingUserProperties = <String, Object?>{};

    if (pendingUserId == null && pendingUserProperties.isEmpty) {
      return;
    }

    if (pendingUserId == null) {
      _sessionRecorder.setUserProperties(pendingUserProperties);
      return;
    }

    await _sessionRecorder.setUser(
      pendingUserId,
      userProperties: pendingUserProperties,
    );
  }

  void _syncLogCapture(SessionRecorderConfig config) {
    _uninstallLogCapture();

    if (!config.captureLogs) {
      return;
    }

    _installLogCapture(config);
  }

  void _syncLifecycleObserver(SessionRecorderConfig config) {
    if (!config.pauseOnBackground) {
      _uninstallLifecycleObserver();
      return;
    }

    if (_isLifecycleObserverRegistered) {
      return;
    }

    widgets.WidgetsBinding.instance.addObserver(this);
    _isLifecycleObserverRegistered = true;
  }

  void _uninstallLifecycleObserver() {
    if (!_isLifecycleObserverRegistered) {
      return;
    }

    widgets.WidgetsBinding.instance.removeObserver(this);
    _isLifecycleObserverRegistered = false;
  }

  void _installLogCapture(SessionRecorderConfig config) {
    if (_logCaptureInstalled) {
      return;
    }

    _logCaptureInstalled = true;

    if (config.captureConsoleLogs) {
      _previousDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null &&
            message.isNotEmpty &&
            !message.startsWith(_internalLogPrefix)) {
          log(
            message,
            level: 'debug',
            logger: 'debugPrint',
          );
        }
        _previousDebugPrint?.call(message, wrapWidth: wrapWidth);
      };
    }

    if (config.captureFlutterErrors) {
      _previousFlutterErrorHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        error(
          details.exception,
          stackTrace: details.stack,
          logger: 'flutter',
          message: details.exceptionAsString(),
          properties: <String, Object?>{
            'context': details.context?.toDescription(),
            'library': details.library,
            'silent': details.silent,
          },
        );
        _previousFlutterErrorHandler?.call(details);
      };
    }

    if (config.capturePlatformErrors) {
      _platformDispatcher ??=
          widgets.WidgetsFlutterBinding.ensureInitialized().platformDispatcher;
      _previousPlatformErrorHandler = _platformDispatcher!.onError;
      _platformDispatcher!.onError =
          (Object errorValue, StackTrace stackTrace) {
        error(
          errorValue,
          stackTrace: stackTrace,
          logger: 'platform',
          message: 'Unhandled platform error',
        );
        final bool handled =
            _previousPlatformErrorHandler?.call(errorValue, stackTrace) ??
                false;
        return handled || true;
      };
    }
  }

  void _uninstallLogCapture() {
    if (!_logCaptureInstalled) {
      return;
    }

    _logCaptureInstalled = false;
    if (_previousDebugPrint != null) {
      debugPrint = _previousDebugPrint!;
    }
    _previousDebugPrint = null;

    FlutterError.onError = _previousFlutterErrorHandler;
    _previousFlutterErrorHandler = null;

    if (_platformDispatcher != null) {
      _platformDispatcher!.onError = _previousPlatformErrorHandler;
    }
    _previousPlatformErrorHandler = null;
  }

  @override
  void didChangeAppLifecycleState(widgets.AppLifecycleState state) {
    if (!_sessionRecorder.config.pauseOnBackground ||
        !_sessionRecorder.isRecording) {
      return;
    }

    switch (state) {
      case widgets.AppLifecycleState.resumed:
        unawaited(resumeCapture(reason: 'app_foregrounded'));
        break;
      case widgets.AppLifecycleState.hidden:
      case widgets.AppLifecycleState.paused:
      case widgets.AppLifecycleState.detached:
        unawaited(pauseCapture(reason: 'app_backgrounded'));
        break;
      case widgets.AppLifecycleState.inactive:
        break;
    }
  }
}
