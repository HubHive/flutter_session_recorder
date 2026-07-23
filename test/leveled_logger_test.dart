import 'package:flutter_session_recorder/flutter_session_recorder.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeTransport implements SessionRecorderTransport {
  final List<SessionBatch> batches = <SessionBatch>[];

  @override
  Future<void> send(SessionBatch batch) async {
    batches.add(batch);
  }

  @override
  Future<UploadedSnapshot> uploadSnapshot(SessionSnapshotUpload upload) async {
    return const UploadedSnapshot(snapshotRef: 'ref');
  }

  @override
  Future<List<UploadedSnapshot>> uploadSnapshots(
    List<SessionSnapshotUpload> uploads,
  ) async {
    return uploads
        .map((_) => const UploadedSnapshot(snapshotRef: 'ref'))
        .toList(growable: false);
  }

  @override
  Future<bool> checkRecordingAccess({String? recordingDomain}) async => true;
}

Iterable<RecorderEvent> _logEvents(_FakeTransport transport) {
  return transport.batches
      .expand((SessionBatch batch) => batch.events)
      .where((RecorderEvent event) => event.type == 'log');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await recorder.resetForTest();
  });

  test('recorder.log.error enqueues a log event with wire level "error"',
      () async {
    final transport = _FakeTransport();
    await recorder.initialize(transport: transport);

    recorder.log.error(
      'boom',
      logger: 'checkout',
      properties: <String, Object?>{'code': 42},
    );

    await recorder.stop();

    final RecorderEvent event = _logEvents(transport).single;
    expect(event.attributes['level'], 'error');
    expect(event.attributes['message'], 'boom');
    expect(event.attributes['logger'], 'checkout');
    expect(event.attributes['properties'], containsPair('code', 42));
  });

  test('debug/info/warn each enqueue their own wire level', () async {
    final transport = _FakeTransport();
    await recorder.initialize(transport: transport);

    recorder.log.debug('d');
    recorder.log.info('i');
    recorder.log.warn('w');

    await recorder.stop();

    final Map<String, String> byMessage = <String, String>{
      for (final RecorderEvent event in _logEvents(transport))
        event.attributes['message']! as String:
            event.attributes['level']! as String,
    };
    expect(byMessage['d'], 'debug');
    expect(byMessage['i'], 'info');
    expect(byMessage['w'], 'warn');
  });

  test('deprecated recorder.log(...) preserves a valid string level', () async {
    final transport = _FakeTransport();
    await recorder.initialize(transport: transport);

    // ignore: deprecated_member_use_from_same_package
    recorder.log('legacy', level: 'error');

    await recorder.stop();

    final RecorderEvent event = _logEvents(transport).single;
    expect(event.attributes['level'], 'error');
    expect(event.attributes['message'], 'legacy');
  });

  test('deprecated recorder.log(...) coerces an invalid level to info',
      () async {
    final transport = _FakeTransport();
    await recorder.initialize(transport: transport);

    // ignore: deprecated_member_use_from_same_package
    recorder.log('legacy', level: 'warning');

    await recorder.stop();

    final RecorderEvent event = _logEvents(transport).single;
    expect(event.attributes['level'], 'info');
  });

  test('leveled logs emitted before start are queued and flushed on start',
      () async {
    final transport = _FakeTransport();

    // Recorder is not recording yet — this must be queued, not dropped.
    recorder.log.warn('early', logger: 'boot');

    await recorder.initialize(transport: transport);
    await recorder.stop();

    final RecorderEvent event = _logEvents(transport).single;
    expect(event.attributes['level'], 'warn');
    expect(event.attributes['message'], 'early');
    expect(event.attributes['logger'], 'boot');
  });

  test('recorder.log.exception emits a single error log with a stable message',
      () async {
    final transport = _FakeTransport();
    await recorder.initialize(transport: transport);

    recorder.log.exception(
      StateError('parent 123 not found'),
      stackTrace: StackTrace.fromString('#0 foo\n#1 bar'),
      logger: 'PostAPIService.createPost',
      properties: <String, Object?>{'entity_type': 'hive'},
    );

    await recorder.stop();

    final RecorderEvent event = _logEvents(transport).single;
    expect(event.attributes['level'], 'error');
    // Message is the exception runtimeType — stable across occurrences, so the
    // volatile "parent 123 not found" text never reaches the fingerprint.
    expect(event.attributes['message'], 'StateError');
    expect(event.attributes['logger'], 'PostAPIService.createPost');

    final Map<String, Object?> properties =
        Map<String, Object?>.from(event.attributes['properties']! as Map);
    expect(properties['entity_type'], 'hive');
    expect(properties['error'], contains('parent 123 not found'));
    expect(properties['stackTrace'], contains('#0 foo'));
  });

  test('recorder.log.exception prefers a caller-supplied summary', () async {
    final transport = _FakeTransport();
    await recorder.initialize(transport: transport);

    recorder.log.exception(
      Exception('boom'),
      summary: 'createPost failed',
      logger: 'checkout',
    );

    await recorder.stop();

    final RecorderEvent event = _logEvents(transport).single;
    expect(event.attributes['message'], 'createPost failed');
    final Map<String, Object?> properties =
        Map<String, Object?>.from(event.attributes['properties']! as Map);
    expect(properties['error'], contains('boom'));
    // No stack trace passed — the key is omitted, not null.
    expect(properties.containsKey('stackTrace'), isFalse);
  });

  test('recorder.error still emits a separate error event, not a log',
      () async {
    final transport = _FakeTransport();
    await recorder.initialize(transport: transport);

    recorder.error(StateError('boom'), logger: 'checkout');

    await recorder.stop();

    final RecorderEvent errorEvent = transport.batches
        .expand((SessionBatch batch) => batch.events)
        .singleWhere(
          (RecorderEvent e) =>
              e.type == 'error' && e.attributes['logger'] == 'checkout',
        );
    expect(errorEvent.attributes['error'], contains('boom'));
    // recorder.error never produces a `log` event.
    expect(_logEvents(transport), isEmpty);
  });
}
