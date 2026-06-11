import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Debug-only framework members (debugNeedsPaint, debugNeedsLayout, ...) are
/// only initialized inside assert closures, so reading one in a release or
/// profile build throws `LateInitializationError: Local 'result' has not
/// been initialized.` `flutter test` always enables asserts, which means no
/// widget test can catch such a read — this source-level scan is the only
/// seam that fails before the fix and passes after it.
///
/// Regression test for the snapshot-capture path reading
/// `renderObject.debugNeedsPaint` directly, which silently broke all
/// Flutter-side snapshot capture in release builds.
void main() {
  test('debug-only members are only read inside assert closures', () {
    final RegExp debugMemberRead = RegExp(r'\.debug[A-Z]\w*');
    final List<String> violations = <String>[];

    final Iterable<File> dartFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'));

    for (final File file in dartFiles) {
      final List<String> lines = file.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        if (!debugMemberRead.hasMatch(lines[i])) {
          continue;
        }
        // Accept the read only if it sits inside an `assert(() { ... }())`
        // closure: an `assert(() {` opener appears above it before any
        // `}());` closer.
        bool insideAssertClosure = false;
        for (int j = i - 1; j >= 0; j--) {
          if (lines[j].contains('}());')) {
            break;
          }
          if (lines[j].contains('assert(() {')) {
            insideAssertClosure = true;
            break;
          }
        }
        if (!insideAssertClosure) {
          violations.add('${file.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Debug-only framework members throw LateInitializationError in '
          'release builds. Read them inside an assert(() { ... }()) closure '
          'with a release-safe fallback instead:\n${violations.join('\n')}',
    );
  });
}
