import 'package:flutter/widgets.dart';
import 'package:flutter_session_recorder/flutter_session_recorder.dart';
import 'package:flutter_test/flutter_test.dart';

// Grabs the capture callback the scope attaches so the test can invoke a
// single capture directly, without spinning up the timer-driven upload
// pipeline.
class _CaptureSpyRecorder extends SessionRecorder {
  _CaptureSpyRecorder() : super(config: const SessionRecorderConfig());

  FlutterCaptureCallback? captured;

  @override
  void attachFlutterCaptureCallback(FlutterCaptureCallback callback) {
    captured = callback;
    super.attachFlutterCaptureCallback(callback);
  }
}

void main() {
  testWidgets(
    'flutter capture reports logical dimensions alongside the physical image',
    (WidgetTester tester) async {
      final _CaptureSpyRecorder recorder = _CaptureSpyRecorder();

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SessionRecorderScope(
            recorder: recorder,
            child: const SizedBox.expand(
              child: ColoredBox(color: Color(0xFF00AA55)),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(recorder.captured, isNotNull);

      FlutterCaptureResult? result;
      await tester.runAsync(() async {
        result = await recorder.captured!();
      });

      expect(result, isNotNull, reason: 'capture should produce an image');
      final Map<String, Object?> metadata = result!.metadata;

      // Logical size is the RepaintBoundary's layout size (the test surface).
      final int logicalWidth =
          (tester.view.physicalSize.width / tester.view.devicePixelRatio)
              .round();
      final int logicalHeight =
          (tester.view.physicalSize.height / tester.view.devicePixelRatio)
              .round();
      expect(metadata['logicalWidth'], logicalWidth);
      expect(metadata['logicalHeight'], logicalHeight);

      // The encoded image is in physical pixels, clamped by
      // nativeSnapshotMaxDimension. It differs from the logical dimensions
      // whenever the capture pixelRatio != 1 — the exact mismatch that used to
      // push interaction markers out of place in the replay viewer.
      expect(result!.width, greaterThan(0));
      expect(result!.width, isNot(equals(metadata['logicalWidth'])));
    },
  );
}
