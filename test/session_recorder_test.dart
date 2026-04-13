import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' as widgets;
import 'package:flutter_session_recorder/flutter_session_recorder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeTransport implements SessionRecorderTransport {
  final List<SessionBatch> batches = <SessionBatch>[];
  final List<_UploadedKeyframeRecord> uploadedKeyframes =
      <_UploadedKeyframeRecord>[];

  @override
  Future<void> send(SessionBatch batch) async {
    batches.add(batch);
  }

  @override
  Future<UploadedKeyframe> uploadKeyframe(SessionKeyframeUpload upload) async {
    final String frameRef =
        'frame_${uploadedKeyframes.length + 1}_${upload.reason}';
    uploadedKeyframes.add(
      _UploadedKeyframeRecord(
        frameRef: frameRef,
        upload: upload,
      ),
    );
    return UploadedKeyframe(frameRef: frameRef);
  }
}

class _UploadedKeyframeRecord {
  const _UploadedKeyframeRecord({
    required this.frameRef,
    required this.upload,
  });

  final String frameRef;
  final SessionKeyframeUpload upload;
}

class _FakeNativeBridge implements SessionRecorderNativeBridge {
  final StreamController<Map<String, Object?>> _controller =
      StreamController<Map<String, Object?>>.broadcast();

  bool started = false;
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
  Future<void> stopCapture() async {
    started = false;
  }

  Future<void> dispose() => _controller.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await recorder.resetForTest();
  });

  test('records lifecycle and custom events into a batch', () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();
    final sessionRecorder = SessionRecorder(
      config: const SessionRecorderConfig.lightweight(),
      nativeBridge: nativeBridge,
      transport: transport,
    );

    await sessionRecorder.start(
      userId: 'user-1',
      sessionProperties: <String, Object?>{'plan': 'pro'},
    );

    sessionRecorder.trackCustomEvent(
      'checkout_started',
      properties: <String, Object?>{'cartValue': 42},
    );

    await sessionRecorder.stop();

    expect(transport.batches, hasLength(1));
    final events = transport.batches.single.events;
    expect(events.map((RecorderEvent event) => event.type), <String>[
      'session.started',
      'custom',
      'session.stopped',
    ]);
    expect(
      transport.batches.single.sessionContext['device'],
      containsPair('model', 'iPhone XR'),
    );
    expect(
      transport.batches.single.sessionContext.containsKey('network'),
      isFalse,
    );

    await nativeBridge.dispose();
  });

  test('setUser flushes updated user payloads to transport', () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();
    final sessionRecorder = SessionRecorder(
      config: const SessionRecorderConfig.lightweight(),
      nativeBridge: nativeBridge,
      transport: transport,
    );

    await sessionRecorder.start();
    await sessionRecorder.setUser(
      'user-42',
      userProperties: <String, Object?>{'plan': 'pro'},
    );

    expect(transport.batches, isNotEmpty);
    expect(transport.batches.last.userId, 'user-42');
    expect(
      transport.batches.last.userProperties,
      containsPair('plan', 'pro'),
    );
    expect(
      transport.batches.last.events.any(
        (RecorderEvent event) =>
            event.type == 'user.identified' &&
            event.attributes['userId'] == 'user-42',
      ),
      isTrue,
    );

    await sessionRecorder.stop();
    await nativeBridge.dispose();
  });

  test('lightweight config enables adaptive hybrid keyframe defaults', () {
    const config = SessionRecorderConfig.lightweight();

    expect(config.captureHybridKeyframes, isTrue);
    expect(config.captureAdaptiveHybridKeyframes, isTrue);
    expect(config.captureKeyframesDuringScroll, isTrue);
    expect(
      config.activeHybridKeyframeInterval,
      const Duration(milliseconds: 150),
    );
    expect(
      config.activeHybridKeyframeWindow,
      const Duration(seconds: 2),
    );
    expect(
      config.scrollKeyframeThrottle,
      const Duration(milliseconds: 175),
    );
  });

  test('trackScreenView syncs the Flutter route name to the native bridge',
      () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();
    final sessionRecorder = SessionRecorder(
      config: const SessionRecorderConfig.lightweight(),
      nativeBridge: nativeBridge,
      transport: transport,
    );

    await sessionRecorder.start();
    sessionRecorder.trackScreenView('Checkout');
    await Future<void>.delayed(Duration.zero);

    expect(nativeBridge.lastScreenName, 'Checkout');

    await sessionRecorder.stop();
    await nativeBridge.dispose();
  });

  test('HTTP transport derives session and frame endpoints from root endpoint',
      () async {
    final List<Uri> requestedUrls = <Uri>[];
    final MockClient client = MockClient((http.Request request) async {
      requestedUrls.add(request.url);
      if (request.url.path == '/frames') {
        return http.Response('{"frameRef":"frame-from-server"}', 200);
      }
      return http.Response('{}', 200);
    });
    final transport = HttpSessionRecorderTransport(
      endpoint: Uri.parse('http://recorder.test:8081'),
      client: client,
    );
    final DateTime timestamp = DateTime.utc(2026, 4, 13, 12);

    await transport.send(
      SessionBatch(
        events: <RecorderEvent>[],
        sentAt: timestamp,
        sessionContext: <String, Object?>{},
        sessionId: 'session-1',
        sessionProperties: <String, Object?>{},
        startedAt: timestamp,
        userId: null,
        userProperties: <String, Object?>{},
      ),
    );
    final UploadedKeyframe uploadedKeyframe = await transport.uploadKeyframe(
      SessionKeyframeUpload(
        bytes: <int>[1, 2, 3],
        format: 'png',
        metadata: <String, Object?>{},
        reason: 'tap',
        screenName: 'Checkout',
        sessionId: 'session-1',
        timestamp: timestamp,
        viewport: <String, Object?>{'width': 390, 'height': 844},
      ),
    );

    expect(
      requestedUrls,
      <Uri>[
        Uri.parse('http://recorder.test:8081/sessions'),
        Uri.parse('http://recorder.test:8081/frames'),
      ],
    );
    expect(uploadedKeyframe.frameRef, 'frame-from-server');
  });

  test('captures native replay frames and interactions through the bridge',
      () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();

    await recorder.initialize(
      nativeBridge: nativeBridge,
      transport: transport,
      config: const SessionRecorderConfig.lightweight(),
    );

    nativeBridge.emit(
      'replay.frame',
      attributes: <String, Object?>{
        'screenName': 'HomeScreen',
        'tree': <String, Object?>{
          'id': 'root',
          'type': 'FlutterView',
          'children': <Object?>[],
        },
      },
    );
    nativeBridge.emit(
      'interaction.tap',
      attributes: <String, Object?>{
        'screenName': 'HomeScreen',
        'dx': 40.0,
        'dy': 90.0,
      },
    );
    nativeBridge.emit(
      'interaction.scroll',
      attributes: <String, Object?>{
        'screenName': 'HomeScreen',
        'pixels': 320.0,
        'axis': 'vertical',
      },
    );

    await Future<void>.delayed(Duration.zero);
    await recorder.stop();

    final List<String> eventTypes = transport.batches
        .expand((SessionBatch batch) => batch.events)
        .map((RecorderEvent event) => event.type)
        .toList(growable: false);

    expect(eventTypes, contains('replay.frame'));
    expect(eventTypes, contains('interaction.tap'));
    expect(eventTypes, contains('interaction.scroll'));
    expect(nativeBridge.started, isFalse);

    await nativeBridge.dispose();
  });

  test('pauseCapture suppresses recording until resumeCapture', () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();
    final sessionRecorder = SessionRecorder(
      config: const SessionRecorderConfig.lightweight(),
      nativeBridge: nativeBridge,
      transport: transport,
    );

    await sessionRecorder.start();
    await sessionRecorder.pauseCapture();

    sessionRecorder.trackCustomEvent('while_paused');
    nativeBridge.emit(
      'replay.frame',
      attributes: <String, Object?>{
        'screenName': 'PausedScreen',
        'tree': <String, Object?>{'id': 'paused'},
      },
    );
    await Future<void>.delayed(Duration.zero);

    await sessionRecorder.resumeCapture();
    sessionRecorder.trackCustomEvent('after_resume');
    nativeBridge.emit(
      'replay.frame',
      attributes: <String, Object?>{
        'screenName': 'ResumedScreen',
        'tree': <String, Object?>{'id': 'resumed'},
      },
    );
    await Future<void>.delayed(Duration.zero);
    await sessionRecorder.stop();

    final List<String> eventTypes = transport.batches
        .expand((SessionBatch batch) => batch.events)
        .map((RecorderEvent event) => event.type)
        .toList(growable: false);
    final List<String?> customNames = transport.batches
        .expand((SessionBatch batch) => batch.events)
        .where((RecorderEvent event) => event.type == 'custom')
        .map((RecorderEvent event) => event.attributes['name'] as String?)
        .toList(growable: false);

    expect(nativeBridge.started, isFalse);
    expect(eventTypes, contains('session.paused'));
    expect(eventTypes, contains('session.resumed'));
    expect(customNames, isNot(contains('while_paused')));
    expect(customNames, contains('after_resume'));

    await nativeBridge.dispose();
  });

  test('pause and resume notify capture state listeners', () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();
    final sessionRecorder = SessionRecorder(
      config: const SessionRecorderConfig.lightweight(),
      nativeBridge: nativeBridge,
      transport: transport,
    );
    final List<bool> states = <bool>[];

    sessionRecorder.addCaptureStateListener(states.add);

    await sessionRecorder.start();
    await sessionRecorder.pauseCapture();
    await sessionRecorder.resumeCapture();
    await sessionRecorder.stop();

    expect(states, <bool>[true, false]);

    await nativeBridge.dispose();
  });

  test('captures logs and errors into the session stream', () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();

    await recorder.initialize(
      nativeBridge: nativeBridge,
      transport: transport,
      config: const SessionRecorderConfig.lightweight(
        captureConsoleLogs: true,
      ),
    );

    recorder.log(
      'manual log entry',
      logger: 'test',
    );
    debugPrint('debug print entry');
    recorder.error(
      StateError('boom'),
      logger: 'test',
    );

    await recorder.stop();

    final List<RecorderEvent> events = transport.batches
        .expand((SessionBatch batch) => batch.events)
        .toList(growable: false);

    expect(events.any((RecorderEvent event) => event.type == 'log'), isTrue);
    expect(events.any((RecorderEvent event) => event.type == 'error'), isTrue);
    expect(
      events.any(
        (RecorderEvent event) =>
            event.type == 'log' && event.attributes['logger'] == 'debugPrint',
      ),
      isTrue,
    );

    await nativeBridge.dispose();
  });

  test('global recorder supports recording from any file after one setup',
      () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();

    await recorder.initialize(
      nativeBridge: nativeBridge,
      transport: transport,
      config: const SessionRecorderConfig.lightweight(),
    );

    recorder.recordEvent(
      'global_event',
      properties: <String, Object?>{'source': 'any_file'},
    );

    await recorder.stop();

    final List<String> eventTypes = transport.batches
        .expand((SessionBatch batch) => batch.events)
        .map((RecorderEvent event) => event.type)
        .toList(growable: false);

    expect(eventTypes, contains('custom'));

    await nativeBridge.dispose();
  });

  test(
      'changing the current user starts a new session without restarting the app',
      () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();

    await recorder.initialize(
      nativeBridge: nativeBridge,
      transport: transport,
      config: const SessionRecorderConfig.lightweight(),
    );

    recorder.recordEvent('before_login');
    await recorder.setUser(
      'user-1',
      userProperties: <String, Object?>{'plan': 'starter'},
    );
    recorder.recordEvent('after_login');
    await recorder.setUser(
      'user-2',
      userProperties: <String, Object?>{'plan': 'pro'},
    );
    recorder.recordEvent('after_switch');
    await recorder.stop();

    final List<String> sessionIds = transport.batches
        .map((SessionBatch batch) => batch.sessionId)
        .toSet()
        .toList(growable: false);

    expect(sessionIds.length, 2);
    expect(transport.batches.first.userId, 'user-1');
    expect(transport.batches.last.userId, 'user-2');

    await nativeBridge.dispose();
  });

  test('resuming after the background timeout starts a new session', () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();
    DateTime currentTime = DateTime.utc(2026, 4, 8, 12, 0, 0);
    final sessionRecorder = SessionRecorder(
      config: const SessionRecorderConfig.lightweight(
        backgroundSessionTimeout: Duration(minutes: 2),
      ),
      nativeBridge: nativeBridge,
      now: () => currentTime,
      transport: transport,
    );

    await sessionRecorder.start(userId: 'user-1');
    await sessionRecorder.pauseCapture();
    currentTime = currentTime.add(const Duration(minutes: 3));
    await sessionRecorder.resumeCapture();
    await sessionRecorder.stop();

    final List<String> sessionIds = transport.batches
        .map((SessionBatch batch) => batch.sessionId)
        .toSet()
        .toList(growable: false);
    final List<String> eventTypes = transport.batches
        .expand((SessionBatch batch) => batch.events)
        .map((RecorderEvent event) => event.type)
        .toList(growable: false);

    expect(sessionIds.length, 2);
    expect(eventTypes, contains('session.paused'));
    expect(eventTypes, contains('session.stopped'));
    expect(
        eventTypes.where((String type) => type == 'session.started').length, 2);

    await nativeBridge.dispose();
  });

  test('global recorder pauses and resumes capture from app lifecycle',
      () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();

    await recorder.initialize(
      nativeBridge: nativeBridge,
      transport: transport,
      config: const SessionRecorderConfig.lightweight(),
    );

    recorder.didChangeAppLifecycleState(widgets.AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);
    expect(nativeBridge.started, isFalse);

    recorder.didChangeAppLifecycleState(widgets.AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(nativeBridge.started, isTrue);

    await recorder.stop();
    await nativeBridge.dispose();
  });

  test('builds a replay document for viewer-side reconstruction', () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();
    final sessionRecorder = SessionRecorder(
      config: const SessionRecorderConfig.lightweight(),
      nativeBridge: nativeBridge,
      transport: transport,
    );

    await sessionRecorder.start(userId: 'viewer-user');
    nativeBridge.emit(
      'screen.view',
      attributes: <String, Object?>{
        'screenName': 'Checkout',
        'properties': <String, Object?>{'source': 'native'},
      },
      timestampMs: 1,
    );
    nativeBridge.emit(
      'replay.frame',
      attributes: <String, Object?>{
        'metadata': <String, Object?>{
          'platform': 'ios',
          'captureStrategy': 'native_view_hierarchy',
        },
        'screenName': 'Checkout',
        'viewport': <String, Object?>{
          'width': 390,
          'height': 844,
          'scale': 3,
        },
        'tree': <String, Object?>{
          'id': 'root',
          'type': 'UIView',
          'render': <String, Object?>{
            'background': <String, Object?>{
              'type': 'solid',
              'color': '#FFFFFFFF',
            },
          },
          'children': <Object?>[
            <String, Object?>{
              'id': 'title',
              'type': 'UILabel',
              'text': 'Checkout',
              'textStyle': <String, Object?>{
                'fontSize': 24,
                'fontWeight': '700',
                'color': '#FF111111',
              },
            },
          ],
        },
      },
      timestampMs: 2,
    );
    sessionRecorder.trackCustomEvent('checkout_started');
    await Future<void>.delayed(Duration.zero);

    final ReplayDocument? document = sessionRecorder.buildReplayDocument();
    expect(document, isNotNull);
    expect(document!.frames, hasLength(1));
    expect(document.screenViews.single.name, 'Checkout');
    expect(document.customEvents.single.name, 'checkout_started');
    expect(document.frames.single.metadata['platform'], 'ios');
    expect(document.frames.single.viewport['width'], 390);
    expect(
      (document.frames.single.tree['children'] as List<Object?>).isNotEmpty,
      isTrue,
    );

    await sessionRecorder.stop();
    await nativeBridge.dispose();
  });

  test('uploads keyframes separately and stores only frame refs in batches',
      () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();
    final sessionRecorder = SessionRecorder(
      config: const SessionRecorderConfig.lightweight(),
      nativeBridge: nativeBridge,
      transport: transport,
    );

    await sessionRecorder.start(userId: 'viewer-user');
    await sessionRecorder.trackKeyframe(
      bytes: <int>[1, 2, 3, 4],
      reason: 'screen_view',
      screenName: 'Checkout',
      viewport: <String, Object?>{
        'width': 390,
        'height': 844,
        'devicePixelRatio': 3.0,
      },
      metadata: <String, Object?>{
        'contentHints': <String, Object?>{
          'texts': <String>['Checkout', 'Pay now'],
          'images': <Object?>[],
        },
        'visualSource': 'flutter_root_capture',
      },
    );

    final ReplayDocument? replayDocument =
        sessionRecorder.buildReplayDocument();
    expect(replayDocument, isNotNull);
    expect(replayDocument!.keyframes, hasLength(1));
    expect(replayDocument.keyframes.single.reason, 'screen_view');
    expect(replayDocument.keyframes.single.frameRef, 'frame_1_screen_view');
    expect(
      replayDocument.sessionContext['device'],
      containsPair('model', 'iPhone XR'),
    );

    await sessionRecorder.stop();

    expect(transport.uploadedKeyframes, hasLength(1));
    expect(
      transport.uploadedKeyframes.single.upload.bytes,
      orderedEquals(<int>[1, 2, 3, 4]),
    );

    final List<RecorderEvent> allEvents = transport.batches
        .expand((SessionBatch batch) => batch.events)
        .toList(growable: false);
    final RecorderEvent keyframeEvent = allEvents.singleWhere(
      (RecorderEvent event) => event.type == 'replay.keyframe',
    );

    expect(keyframeEvent.attributes['frameRef'], 'frame_1_screen_view');
    expect(keyframeEvent.attributes.containsKey('image'), isFalse);
    expect(keyframeEvent.attributes['screenName'], 'Checkout');
    expect(nativeBridge.started, isFalse);

    await nativeBridge.dispose();
  });

  test('stop succeeds while capture is paused', () async {
    final transport = _FakeTransport();
    final nativeBridge = _FakeNativeBridge();
    final sessionRecorder = SessionRecorder(
      config: const SessionRecorderConfig.lightweight(),
      nativeBridge: nativeBridge,
      transport: transport,
    );

    await sessionRecorder.start();
    await sessionRecorder.pauseCapture();
    await sessionRecorder.stop();

    final List<String> eventTypes = transport.batches
        .expand((SessionBatch batch) => batch.events)
        .map((RecorderEvent event) => event.type)
        .toList(growable: false);

    expect(eventTypes, contains('session.paused'));
    expect(eventTypes, contains('session.stopped'));
    expect(nativeBridge.started, isFalse);

    await nativeBridge.dispose();
  });
}
