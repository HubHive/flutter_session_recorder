import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_session_recorder/flutter_session_recorder.dart';
import 'package:flutter_test/flutter_test.dart';

/// A transport that is permanently unreachable, the way a missing DNS record
/// behaves: every call throws, forever.
class _DeadTransport implements SessionRecorderTransport {
  int sendAttempts = 0;
  int snapshotAttempts = 0;
  bool fail = true;

  @override
  Future<void> send(SessionBatch batch) async {
    sendAttempts += 1;
    if (fail) {
      throw Exception('Failed host lookup: sessions.example.com');
    }
  }

  @override
  Future<UploadedSnapshot> uploadSnapshot(SessionSnapshotUpload upload) async {
    return (await uploadSnapshots(<SessionSnapshotUpload>[upload])).single;
  }

  @override
  Future<List<UploadedSnapshot>> uploadSnapshots(
    List<SessionSnapshotUpload> uploads,
  ) async {
    snapshotAttempts += 1;
    if (fail) {
      throw Exception('Failed host lookup: sessions.example.com');
    }
    return uploads
        .map((SessionSnapshotUpload u) =>
            UploadedSnapshot(snapshotRef: u.snapshotId))
        .toList(growable: false);
  }

  @override
  Future<bool> checkRecordingAccess({String? recordingDomain}) async => true;
}

/// Hermetic native bridge so these tests never touch a platform channel.
class _FakeNativeBridge implements SessionRecorderNativeBridge {
  final StreamController<Map<String, Object?>> _controller =
      StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get eventStream => _controller.stream;

  @override
  Future<Map<String, Object?>> getDeviceContext() async =>
      <String, Object?>{'osName': 'iOS'};

  @override
  Future<void> setScreenName(String? screenName) async {}

  @override
  Future<void> pauseCapture() async {}

  @override
  Future<void> resumeCapture(SessionRecorderConfig config) async {}

  @override
  Future<void> startCapture(SessionRecorderConfig config) async {}

  @override
  Future<void> startSnapshotCapture(SessionRecorderConfig config) async {}

  @override
  Future<void> stopSnapshotCapture() async {}

  @override
  Future<void> stopCapture() async {}

  Future<void> dispose() => _controller.close();
}

/// These tests pin the invariant that made the HubHive mobile app leak ~34MB/min
/// and reach 492MB RSS in 10 idle minutes: the endpoint it uploaded to had no
/// DNS record.
///
/// The point is NOT "that endpoint is fixed now". It is that an unreachable —
/// or slow, or intermittently failing — endpoint must cost a bounded amount of
/// memory and work. Provisioning the host would have hidden this; these tests
/// are what stop it recurring on the next outage.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<_FakeNativeBridge> bridges = <_FakeNativeBridge>[];
  tearDown(() async {
    for (final _FakeNativeBridge bridge in bridges) {
      await bridge.dispose();
    }
    bridges.clear();
  });

  SessionRecorder build(_DeadTransport transport, {SessionRecorderConfig? cfg}) {
    final _FakeNativeBridge bridge = _FakeNativeBridge();
    bridges.add(bridge);
    return SessionRecorder(
      config: cfg ??
          const SessionRecorderConfig.lightweight(
            maxBufferedEvents: 50,
            maxSessionHistoryEvents: 40,
            maxConsecutiveTransportFailures: 3,
          ),
      transport: transport,
      nativeBridge: bridge,
    );
  }

  group('unreachable endpoint stays bounded', () {
    test('the event buffer never exceeds its ceiling', () async {
      final transport = _DeadTransport();
      final recorder = build(transport);
      await recorder.start();

      // Far more events than any cap, all undeliverable.
      for (int i = 0; i < 5000; i++) {
        recorder.trackCustomEvent('event_$i');
      }
      await Future<void>.delayed(Duration.zero);

      expect(recorder.bufferedEventCountForTesting, lessThanOrEqualTo(50),
          reason: 'a dead transport must not grow the unsent buffer without bound');
      await recorder.stop();
    });

    test('the retained session history never exceeds its ceiling', () async {
      final transport = _DeadTransport();
      final recorder = build(transport);
      await recorder.start();

      for (int i = 0; i < 5000; i++) {
        recorder.trackCustomEvent('event_$i');
      }
      await Future<void>.delayed(Duration.zero);

      // This list is only read by buildReplayDocument(); before the fix it was
      // appended to for every event and never trimmed during a live session.
      expect(recorder.sessionHistoryCountForTesting, lessThanOrEqualTo(40),
          reason: 'session history must be capped, not retained for the process');
      await recorder.stop();
    });

    test('repeated failures open the breaker and stop retrying', () async {
      final transport = _DeadTransport();
      final recorder = build(transport);
      await recorder.start();

      for (int i = 0; i < 400; i++) {
        recorder.trackCustomEvent('event_$i');
        await Future<void>.delayed(Duration.zero);
      }

      expect(recorder.isTransportSuspendedForTesting, isTrue,
          reason: 'a streak of failures must suspend uploads');

      final int attemptsWhenOpened = transport.sendAttempts;
      for (int i = 0; i < 400; i++) {
        recorder.trackCustomEvent('more_$i');
        await Future<void>.delayed(Duration.zero);
      }

      expect(transport.sendAttempts, attemptsWhenOpened,
          reason: 'no further upload attempts while the breaker is open');
      await recorder.stop();
    });

    test('opening the breaker drops the queued backlog', () async {
      final transport = _DeadTransport();
      final recorder = build(transport);
      await recorder.start();

      for (int i = 0; i < 400; i++) {
        recorder.trackCustomEvent('event_$i');
        await Future<void>.delayed(Duration.zero);
      }

      expect(recorder.isTransportSuspendedForTesting, isTrue);
      // Snapshots are dropped outright and capture stops — they are the
      // expensive payload and are worthless once undeliverable.
      expect(recorder.pendingSnapshotCountForTesting, 0,
          reason: 'the snapshot backlog must be released when the breaker opens');
      // Events keep being buffered while suspended, deliberately: they are cheap
      // and useful if the endpoint recovers. The requirement is that they stay
      // BOUNDED, which is what actually failed before.
      expect(recorder.bufferedEventCountForTesting, lessThanOrEqualTo(50),
          reason: 'buffering while suspended must stay within the ceiling');
      await recorder.stop();
    });

    test('a recovered endpoint resumes uploading', () async {
      final transport = _DeadTransport();
      final recorder = build(
        transport,
        cfg: const SessionRecorderConfig.lightweight(
          maxConsecutiveTransportFailures: 2,
          // Expire immediately so the probe is allowed without a fake clock.
          transportFailureBackoff: Duration.zero,
        ),
      );
      await recorder.start();

      for (int i = 0; i < 200; i++) {
        recorder.trackCustomEvent('event_$i');
        await Future<void>.delayed(Duration.zero);
      }

      transport.fail = false;
      recorder.trackCustomEvent('after_recovery');
      await recorder.flush();

      expect(recorder.isTransportSuspendedForTesting, isFalse,
          reason: 'a successful delivery must close the breaker');
      await recorder.stop();
    });

    test('a failing transport does not report an error per failure', () async {
      final transport = _DeadTransport();
      final recorder = build(transport);

      // The host wires FlutterError.onError to record events. Before the fix,
      // every transport failure was reported here, became an event, and that
      // event triggered the flush that was failing — the leak's engine.
      int reported = 0;
      final FlutterExceptionHandler? previous = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        if (details.library == 'flutter_session_recorder') {
          reported += 1;
          return;
        }
        previous?.call(details);
      };
      addTearDown(() => FlutterError.onError = previous);

      await recorder.start();
      for (int i = 0; i < 400; i++) {
        recorder.trackCustomEvent('event_$i');
        await Future<void>.delayed(Duration.zero);
      }

      expect(reported, lessThanOrEqualTo(2),
          reason: 'only the first failure of a streak should be reported; '
              'reporting each one is what fed the loop');
      await recorder.stop();
    });

    test('flush does not surface an unhandled async error', () async {
      // flush() is invoked through unawaited(...). Rethrowing made a transport
      // failure an unhandled async error, which the host's platform-error hook
      // turned into yet another recorded event.
      final transport = _DeadTransport();
      final recorder = build(transport);
      await recorder.start();

      recorder.trackCustomEvent('event');
      await expectLater(recorder.flush(), completes);

      await recorder.stop();
    });
  });
}
