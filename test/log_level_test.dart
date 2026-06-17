import 'package:flutter_session_recorder/flutter_session_recorder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LogLevel', () {
    test('each value serializes to its lowercase wire string', () {
      expect(LogLevel.debug.wireValue, 'debug');
      expect(LogLevel.info.wireValue, 'info');
      expect(LogLevel.warn.wireValue, 'warn');
      expect(LogLevel.error.wireValue, 'error');
    });

    test('parses known wire strings back to their value', () {
      expect(LogLevel.fromWire('debug'), LogLevel.debug);
      expect(LogLevel.fromWire('info'), LogLevel.info);
      expect(LogLevel.fromWire('warn'), LogLevel.warn);
      expect(LogLevel.fromWire('error'), LogLevel.error);
    });

    test('coerces unknown or null strings to info', () {
      expect(LogLevel.fromWire('warning'), LogLevel.info);
      expect(LogLevel.fromWire('verbose'), LogLevel.info);
      expect(LogLevel.fromWire(''), LogLevel.info);
      expect(LogLevel.fromWire(null), LogLevel.info);
    });
  });
}
