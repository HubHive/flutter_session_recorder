import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_session_recorder/flutter_session_recorder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeTransport implements SessionRecorderTransport {
  final List<SessionBatch> batches = <SessionBatch>[];
  final List<int> snapshotUploadBatchSizes = <int>[];
  final List<_UploadedSnapshotRecord> uploadedSnapshots =
      <_UploadedSnapshotRecord>[];
  int accessCheckCount = 0;
  bool hasRecordingAccess = true;
  Object? sendError;
  Object? uploadError;

  @override
  Future<void> send(SessionBatch batch) async {
    final Object? error = sendError;
    if (error != null) {
      throw error;
    }
    batches.add(batch);
  }

  @override
  Future<UploadedSnapshot> uploadSnapshot(SessionSnapshotUpload upload) async {
    return (await uploadSnapshots(<SessionSnapshotUpload>[upload])).single;
  }

  @override
  Future<List<UploadedSnapshot>> uploadSnapshots(
    List<SessionSnapshotUpload> uploads,
  ) async {
    final Object? error = uploadError;
    if (error != null) {
      throw error;
    }
    snapshotUploadBatchSizes.add(uploads.length);
    return uploads.map((SessionSnapshotUpload upload) {
      final String snapshotRef =
          'snapshot_${uploadedSnapshots.length + 1}_${upload.snapshotId}';
      uploadedSnapshots.add(
        _UploadedSnapshotRecord(
          snapshotRef: snapshotRef,
          upload: upload,
        ),
      );
      return UploadedSnapshot(snapshotRef: snapshotRef);
    }).toList(growable: false);
  }

  @override
  Future<bool> checkRecordingAccess() async {
    accessCheckCount += 1;
    return hasRecordingAccess;
  }
}

class _UploadedSnapshotRecord {
  const _UploadedSnapshotRecord({
    required this.snapshotRef,
    required this.upload,
  });

  final String snapshotRef;
  final SessionSnapshotUpload upload;
}

class _FakeNativeBridge implements SessionRecorderNativeBridge {
  final StreamController<Map<String, Object?>> _controller =
      StreamController<Map<String, Object?>>.broadcast();

  bool started = false;
  bool snapshotStarted = false;
  SessionRecorderConfig? lastConfig;
  String? lastScreenName;
  Map<String, Object?> deviceContext = <String, Object?>{
    'deviceType': 'iphone',
    'model': 'iPhone XR',
    'osName': 'iOS',
    'osVersion': '17.0',
  };

  @override
  Stream<Map<String, Object?>> get eventStream => _controller.stream;

  @override
  Future<Map<String, Object?>> getDeviceContext() async => deviceContext;

  @override
  Future<void> setScreenName(String? screenName) async {
    lastScreenName = screenName;
  }

  void emit(
    String type, {
    Map<String, Object?> attributes = const <String, Object?>{},
    int? timestampMs,
  }) {
    _controller.add(<String, Object?>{
      'id': '${type}_${timestampMs ?? DateTime.now().millisecondsSinceEpoch}',
      'type': type,
      'timestampMs': timestampMs ?? DateTime.now().millisecondsSinceEpoch,
      'attributes': attributes,
    });
  }

  @override
  Future<void> pauseCapture() async {
    started = false;
    snapshotStarted = false;
  }

  @override
  Future<void> resumeCapture(SessionRecorderConfig config) async {
    started = true;
    lastConfig = config;
  }

  @override
  Future<void> startCapture(SessionRecorderConfig config) async {
    started = true;
    lastConfig = config;
  }

  @override
  Future<void> startSnapshotCapture(SessionRecorderConfig config) async {
    snapshotStarted = true;
    lastConfig = config;
  }

  @override
  Future<void> stopSnapshotCapture() async {
    snapshotStarted = false;
  }

  @override
  Future<void> stopCapture() async {
    started = false;
    snapshotStarted = false;
  }

  Future<void> dispose() => _controller.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await recorder.resetForTest();
  });

  test('lightweight config is snapshot-first with no old visual mode knobs',
      () {
    const config = SessionRecorderConfig.lightweight(
      recordingDomain: 'app.hubhive.com',
    );

    expect(config.nativeSnapshotInterval, const Duration(milliseconds: 500));
    expect(config.nativeSnapshotJpegQuality, 0.65);
    expect(config.nativeSnapshotMaxDimension, 720);
    expect(config.maxSnapshotUploadBatchSize, 10);
    expect(config.snapshotUploadFlushInterval, const Duration(seconds: 5));
    expect(config.recordingDomain, 'app.hubhive.com');
    expect(config.toJson(), containsPair('nativeSnapshotIntervalMs', 500));
    expect(config.toJson(), containsPair('nativeSnapshotJpegQuality', 0.65));
    expect(config.toJson(), containsPair('nativeSnapshotMaxDimension', 720));
    expect(config.toJson(), containsPair('maxSnapshotUploadBatchSize', 10));
    expect(
      config.toJson(),
      containsPair('snapshotUploadFlushIntervalMs', 5000),
    );
    expect(config.toJson(), containsPair('recordingDomain', 'app.hubhive.com'));
    expect(config.toJson(), isNot(contains('captureSchematicFrames')));
    expect(config.toJson(), isNot(contains('captureScreenshotKeyframes')));
    expect(config.toJson(), isNot(contains('uploadAssetImages')));
  });

  test('records lifecycle and custom events into a visual session batch',
      () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();
    final sessionRecorder = SessionRecorder(
      config: const SessionRecorderConfig.lightweight(
        maxSnapshotUploadBatchSize: 1,
        recordingDomain: 'app.hubhive.com',
      ),
      nativeBridge: nativeBridge,
      transport: transport,
    );

    await sessionRecorder.start(
      sessionProperties: <String, Object?>{'environment': 'test'},
      userId: 'user-1',
      userProperties: <String, Object?>{'plan': 'pro'},
    );
    sessionRecorder.trackScreenView('Home');
    sessionRecorder.trackCustomEvent(
      'checkout_started',
      properties: <String, Object?>{'cartValue': 42},
    );
    await sessionRecorder.stop();

    final List<RecorderEvent> events = transport.batches
        .expand((SessionBatch batch) => batch.events)
        .toList(growable: false);

    expect(nativeBridge.started, isFalse);
    expect(nativeBridge.snapshotStarted, isFalse);
    expect(
        events.map((RecorderEvent event) => event.type),
        containsAll(
          <String>[
            'session.started',
            'screen.view',
            'custom',
            'session.stopped'
          ],
        ));
    expect(transport.batches.single.userId, 'user-1');
    expect(transport.batches.single.sessionProperties['environment'], 'test');
    expect(
      transport.batches.single.sessionContext['recordingDomain'],
      'app.hubhive.com',
    );

    await nativeBridge.dispose();
  });

  test('changing the current user starts a new session without app restart',
      () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();

    await recorder.initialize(
      nativeBridge: nativeBridge,
      transport: transport,
      userId: 'user-a',
    );

    final String firstSessionId = recorder.sessionId!;
    await recorder.setUser(
      'user-b',
      userProperties: <String, Object?>{'role': 'owner'},
    );

    expect(recorder.sessionId, isNot(firstSessionId));
    expect(recorder.userId, 'user-b');
    recorder.recordEvent('after_user_change');
    await recorder.stop();

    final List<SessionBatch> userBBatches = transport.batches
        .where((SessionBatch batch) => batch.userId == 'user-b')
        .toList(growable: false);
    expect(userBBatches, isNotEmpty);
    expect(userBBatches.last.userProperties['role'], 'owner');

    await nativeBridge.dispose();
  });

  test('HTTP transport posts only sessions, snapshots, and access checks',
      () async {
    final List<Uri> requestedUris = <Uri>[];
    final Map<String, String> snapshotFields = <String, String>{};
    final client = MockClient((http.Request request) async {
      requestedUris.add(request.url);
      if (request.url.path == '/snapshots') {
        final String body = request.body;
        for (final String field in <String>[
          'metadata',
          'sessionContext',
          'sessionProperties',
          'userId',
          'userProperties',
        ]) {
          final RegExpMatch? match = RegExp(
            'name="$field"\\r\\n\\r\\n([^\\r]*)',
          ).firstMatch(body);
          if (match != null) {
            snapshotFields[field] = match.group(1)!;
          }
        }
        return http.Response('{"snapshotRef":"snapshot-from-server"}', 200);
      }
      return http.Response('{}', 200);
    });
    final transport = HttpSessionRecorderTransport(
      endpoint: Uri.parse('http://recorder.test:8081'),
      apiKey: 'demo-key',
      client: client,
    );
    final DateTime timestamp = DateTime.utc(2026);

    await transport.send(
      SessionBatch(
        events: <RecorderEvent>[RecorderEvent(type: 'custom')],
        sentAt: timestamp,
        sessionId: 'session-1',
        sessionContext: const <String, Object?>{},
        sessionProperties: const <String, Object?>{},
        startedAt: timestamp,
        userId: null,
        userProperties: const <String, Object?>{},
      ),
    );
    final UploadedSnapshot uploadedSnapshot = await transport.uploadSnapshot(
      SessionSnapshotUpload(
        bytes: <int>[7, 8, 9],
        contentType: 'image/jpeg',
        filename: 'snapshot.jpg',
        format: 'jpg',
        height: 844,
        metadata: <String, Object?>{
          'unsafe': double.infinity,
        },
        screenName: 'Checkout',
        sessionContext: const <String, Object?>{
          'device': <String, Object?>{'model': 'iPhone XR'},
          'recordingDomain': 'app.hubhive.com',
        },
        snapshotId: 'snapshot-1',
        sessionId: 'session-1',
        sessionProperties: const <String, Object?>{
          'environment': 'test',
        },
        timestamp: timestamp,
        userId: 'user-1',
        userProperties: const <String, Object?>{
          'plan': 'pro',
        },
        width: 390,
      ),
    );
    final bool hasRecordingAccess = await transport.checkRecordingAccess();

    expect(requestedUris, <Uri>[
      Uri.parse('http://recorder.test:8081/sessions'),
      Uri.parse('http://recorder.test:8081/snapshots'),
      Uri.parse('http://recorder.test:8081/recording-access-test'),
    ]);
    expect(uploadedSnapshot.snapshotRef, 'snapshot-from-server');
    expect(hasRecordingAccess, isTrue);
    expect(
      jsonDecode(snapshotFields['sessionContext']!) as Map<String, Object?>,
      containsPair('recordingDomain', 'app.hubhive.com'),
    );
    expect(
      jsonDecode(snapshotFields['sessionProperties']!) as Map<String, Object?>,
      containsPair('environment', 'test'),
    );
    expect(snapshotFields['userId'], 'user-1');
    expect(
      jsonDecode(snapshotFields['userProperties']!) as Map<String, Object?>,
      containsPair('plan', 'pro'),
    );
  });

  test('HTTP transport posts multiple snapshots in one multipart request',
      () async {
    final List<Uri> requestedUris = <Uri>[];
    String multipartBody = '';
    final client = MockClient((http.Request request) async {
      requestedUris.add(request.url);
      multipartBody = request.body;
      return http.Response(
        '{"snapshots":[{"snapshotId":"snapshot-1","snapshotRef":"ref-1"},{"snapshotId":"snapshot-2","snapshotRef":"ref-2"}]}',
        200,
      );
    });
    final transport = HttpSessionRecorderTransport(
      endpoint: Uri.parse('http://recorder.test:8081'),
      client: client,
    );

    final List<UploadedSnapshot> uploadedSnapshots =
        await transport.uploadSnapshots(<SessionSnapshotUpload>[
      SessionSnapshotUpload(
        bytes: <int>[1, 2, 3],
        contentType: 'image/jpeg',
        format: 'jpg',
        height: 844,
        metadata: const <String, Object?>{},
        screenName: 'Home',
        sessionContext: const <String, Object?>{},
        sessionId: 'session-1',
        sessionProperties: const <String, Object?>{},
        snapshotId: 'snapshot-1',
        timestamp: DateTime.utc(2026),
        userProperties: const <String, Object?>{},
        width: 390,
      ),
      SessionSnapshotUpload(
        bytes: <int>[4, 5, 6],
        contentType: 'image/jpeg',
        format: 'jpg',
        height: 844,
        metadata: const <String, Object?>{},
        screenName: 'Home',
        sessionContext: const <String, Object?>{},
        sessionId: 'session-1',
        sessionProperties: const <String, Object?>{},
        snapshotId: 'snapshot-2',
        timestamp: DateTime.utc(2026),
        userProperties: const <String, Object?>{},
        width: 390,
      ),
    ]);

    expect(requestedUris, <Uri>[
      Uri.parse('http://recorder.test:8081/snapshots'),
    ]);
    expect(
      uploadedSnapshots.map((UploadedSnapshot upload) => upload.snapshotRef),
      <String>['ref-1', 'ref-2'],
    );
    expect(multipartBody, contains('name="snapshots"'));
    expect(multipartBody, contains('"fileField":"snapshot_0"'));
    expect(multipartBody, contains('name="snapshot_0"'));
    expect(multipartBody, contains('name="snapshot_1"'));
  });

  test('native interactions are captured and unsupported events are ignored',
      () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();

    await recorder.initialize(
      nativeBridge: nativeBridge,
      transport: transport,
    );

    nativeBridge.emit(
      'native.unsupported',
      attributes: <String, Object?>{'screenName': 'HomeScreen'},
    );
    nativeBridge.emit(
      'interaction.tap',
      attributes: <String, Object?>{
        'screenName': 'HomeScreen',
        'dx': 40.0,
        'dy': 90.0,
      },
    );

    await Future<void>.delayed(Duration.zero);
    await recorder.stop();

    final List<String> eventTypes = transport.batches
        .expand((SessionBatch batch) => batch.events)
        .map((RecorderEvent event) => event.type)
        .toList(growable: false);

    expect(eventTypes, isNot(contains('native.unsupported')));
    expect(eventTypes, contains('interaction.tap'));

    await nativeBridge.dispose();
  });

  test('native visual capture errors are recorded as error events', () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();

    await recorder.initialize(
      nativeBridge: nativeBridge,
      transport: transport,
    );

    nativeBridge.emit(
      'native.snapshot_capture.error',
      attributes: <String, Object?>{
        'message': 'Native visual capture stopped unexpectedly',
        'platform': 'ios',
      },
    );

    await Future<void>.delayed(Duration.zero);
    await recorder.stop();

    final RecorderEvent errorEvent = transport.batches
        .expand((SessionBatch batch) => batch.events)
        .singleWhere((RecorderEvent event) => event.type == 'error');

    expect(errorEvent.attributes['logger'], 'native_snapshot_capture');
    expect(
      errorEvent.attributes['error'],
      'Native visual capture stopped unexpectedly',
    );
    expect(
      errorEvent.attributes['properties'],
      containsPair('platform', 'ios'),
    );

    await nativeBridge.dispose();
  });

  test('native visual capture status events are recorded as logs', () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();

    await recorder.initialize(
      nativeBridge: nativeBridge,
      transport: transport,
    );

    nativeBridge.emit(
      'native.snapshot_capture.status',
      attributes: <String, Object?>{
        'message': 'Window snapshot captured.',
        'phase': 'snapshot_captured',
        'platform': 'ios',
      },
    );

    await Future<void>.delayed(Duration.zero);
    await recorder.stop();

    final RecorderEvent logEvent = transport.batches
        .expand((SessionBatch batch) => batch.events)
        .singleWhere(
          (RecorderEvent event) =>
              event.type == 'log' &&
              event.attributes['logger'] == 'native_snapshot_capture' &&
              event.attributes['message'] == 'Window snapshot captured.',
        );

    expect(
      logEvent.attributes['properties'],
      containsPair('phase', 'snapshot_captured'),
    );

    await nativeBridge.dispose();
  });

  test('uploads native snapshots and records snapshot refs', () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();
    final sessionRecorder = SessionRecorder(
      config: const SessionRecorderConfig.lightweight(
        recordingDomain: 'app.hubhive.com',
      ),
      nativeBridge: nativeBridge,
      transport: transport,
    );
    final Directory tempDir =
        await Directory.systemTemp.createTemp('session-recorder-test-');
    final File snapshotFile = File('${tempDir.path}/snapshot.jpg');
    await snapshotFile.writeAsBytes(<int>[1, 2, 3, 4, 5]);

    await sessionRecorder.start(
      sessionProperties: <String, Object?>{'environment': 'test'},
      userId: 'viewer-user',
      userProperties: <String, Object?>{'plan': 'pro'},
    );
    expect(nativeBridge.snapshotStarted, isTrue);

    nativeBridge.emit(
      'replay.snapshot.ready',
      attributes: <String, Object?>{
        'contentType': 'image/jpeg',
        'filePath': snapshotFile.path,
        'fileSize': 5,
        'format': 'jpg',
        'height': 844,
        'screenName': 'Checkout',
        'snapshotId': 'snapshot-1',
        'sequence': 1,
        'timestampMs': 1000,
        'width': 390,
      },
      timestampMs: 1200,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sessionRecorder.flush();

    expect(transport.uploadedSnapshots, hasLength(1));
    expect(transport.uploadedSnapshots.single.upload.bytes, <int>[
      1,
      2,
      3,
      4,
      5,
    ]);
    expect(
      transport.uploadedSnapshots.single.upload.sessionContext['device'],
      isNotNull,
    );
    expect(
      transport
          .uploadedSnapshots.single.upload.sessionContext['recordingDomain'],
      'app.hubhive.com',
    );
    expect(
      transport.uploadedSnapshots.single.upload.sessionProperties,
      containsPair('environment', 'test'),
    );
    expect(transport.uploadedSnapshots.single.upload.userId, 'viewer-user');
    expect(
      transport.uploadedSnapshots.single.upload.userProperties,
      containsPair('plan', 'pro'),
    );
    expect(await snapshotFile.exists(), isFalse);
    expect(
      sessionRecorder.buildReplayDocument()?.snapshots.single.snapshotRef,
      'snapshot_1_snapshot-1',
    );
    expect(
      sessionRecorder.buildReplayDocument()?.snapshots.single.sessionContext,
      containsPair('recordingDomain', 'app.hubhive.com'),
    );
    expect(
      sessionRecorder.buildReplayDocument()?.snapshots.single.sessionProperties,
      containsPair('environment', 'test'),
    );

    await sessionRecorder.stop();

    final List<RecorderEvent> allEvents = transport.batches
        .expand((SessionBatch batch) => batch.events)
        .toList(growable: false);
    final RecorderEvent snapshotEvent = allEvents.singleWhere(
      (RecorderEvent event) => event.type == 'replay.snapshot',
    );

    expect(snapshotEvent.attributes['snapshotRef'], 'snapshot_1_snapshot-1');
    expect(snapshotEvent.attributes['screenName'], 'Checkout');
    expect(snapshotEvent.attributes['format'], 'jpg');
    expect(
      snapshotEvent.attributes['sessionProperties'],
      containsPair('environment', 'test'),
    );
    expect(
      snapshotEvent.attributes['sessionContext'],
      containsPair('recordingDomain', 'app.hubhive.com'),
    );
    expect(snapshotEvent.attributes['userId'], 'viewer-user');
    expect(nativeBridge.snapshotStarted, isFalse);

    await tempDir.delete(recursive: true);
    await nativeBridge.dispose();
  });

  test('batches native snapshot uploads before recording refs', () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();
    final sessionRecorder = SessionRecorder(
      config: const SessionRecorderConfig.lightweight(
        maxSnapshotUploadBatchSize: 3,
        snapshotUploadFlushInterval: Duration(minutes: 1),
      ),
      nativeBridge: nativeBridge,
      transport: transport,
    );
    final Directory tempDir =
        await Directory.systemTemp.createTemp('session-recorder-test-');

    await sessionRecorder.start();
    for (int index = 0; index < 3; index += 1) {
      final File snapshotFile = File('${tempDir.path}/snapshot_$index.jpg');
      await snapshotFile.writeAsBytes(<int>[index, index + 1, index + 2]);
      await sessionRecorder.trackNativeSnapshot(
        contentType: 'image/jpeg',
        filePath: snapshotFile.path,
        format: 'jpg',
        height: 844,
        screenName: 'Home',
        snapshotId: 'snapshot-$index',
        timestamp: DateTime.utc(2026, 1, 1, 0, 0, index),
        width: 390,
      );
    }
    await sessionRecorder.flush();
    await sessionRecorder.stop();

    expect(transport.snapshotUploadBatchSizes, contains(3));
    expect(transport.uploadedSnapshots, hasLength(3));

    final List<RecorderEvent> snapshotEvents = transport.batches
        .expand((SessionBatch batch) => batch.events)
        .where((RecorderEvent event) => event.type == 'replay.snapshot')
        .toList(growable: false);
    expect(snapshotEvents, hasLength(3));
    expect(
      snapshotEvents
          .map((RecorderEvent event) => event.attributes['snapshotRef']),
      containsAll(<String>[
        'snapshot_1_snapshot-0',
        'snapshot_2_snapshot-1',
        'snapshot_3_snapshot-2',
      ]),
    );

    await tempDir.delete(recursive: true);
    await nativeBridge.dispose();
  });

  test('403 from snapshot upload pauses recording and starts access probing',
      () async {
    final transport = _FakeTransport()
      ..uploadError = const SessionRecorderTransportException(
        'forbidden',
        statusCode: 403,
      )
      ..hasRecordingAccess = false;
    final nativeBridge = _FakeNativeBridge();
    final sessionRecorder = SessionRecorder(
      config: const SessionRecorderConfig.lightweight(
        maxSnapshotUploadBatchSize: 1,
        recordingAccessCheckInterval: Duration(milliseconds: 1),
      ),
      nativeBridge: nativeBridge,
      transport: transport,
    );
    final Directory tempDir =
        await Directory.systemTemp.createTemp('session-recorder-test-');
    final File snapshotFile = File('${tempDir.path}/snapshot.jpg');
    await snapshotFile.writeAsBytes(<int>[1, 2, 3]);

    await sessionRecorder.start();
    await sessionRecorder.trackNativeSnapshot(
      contentType: 'image/jpeg',
      filePath: snapshotFile.path,
      format: 'jpg',
      height: 844,
      screenName: 'Home',
      snapshotId: 'snapshot-403',
      timestamp: DateTime.utc(2026),
      width: 390,
    );
    await sessionRecorder.flush();
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(sessionRecorder.isRecordingAccessDenied, isTrue);
    expect(sessionRecorder.isCapturePaused, isTrue);
    expect(nativeBridge.snapshotStarted, isFalse);
    expect(transport.accessCheckCount, greaterThan(0));
    expect(await snapshotFile.exists(), isFalse);

    await sessionRecorder.stop();
    await tempDir.delete(recursive: true);
    await nativeBridge.dispose();
  });

  test('captures logs and errors into the session stream', () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();
    final sessionRecorder = SessionRecorder(
      nativeBridge: nativeBridge,
      transport: transport,
    );

    await sessionRecorder.start();
    sessionRecorder.trackLog(
      level: 'warning',
      logger: 'checkout',
      message: 'validation failed',
    );
    sessionRecorder.trackError(
      error: StateError('Missing cart id'),
      logger: 'checkout',
    );
    await sessionRecorder.stop();

    final List<String> eventTypes = transport.batches
        .expand((SessionBatch batch) => batch.events)
        .map((RecorderEvent event) => event.type)
        .toList(growable: false);
    expect(eventTypes, containsAll(<String>['log', 'error']));

    await nativeBridge.dispose();
  });

  test('normalizes non-finite numbers before JSON encoding', () {
    final event = RecorderEvent(
      type: 'custom',
      attributes: <String, Object?>{
        'name': 'bad_values',
        'properties': <String, Object?>{
          'nan': double.nan,
          'infinity': double.infinity,
          'valid': 1.5,
        },
      },
    );

    final String encoded = jsonEncode(event.toJson());
    final Map<String, Object?> decoded =
        jsonDecode(encoded) as Map<String, Object?>;
    final attributes = decoded['attributes'] as Map<String, Object?>;
    final properties = attributes['properties'] as Map<String, Object?>;

    expect(properties['nan'], isNull);
    expect(properties['infinity'], isNull);
    expect(properties['valid'], 1.5);
  });
}
