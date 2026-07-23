import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../core/session_recorder.dart';

class SessionRecorderScope extends StatefulWidget {
  const SessionRecorderScope({
    required this.child,
    required this.recorder,
    super.key,
    this.captureInitialScreenView = true,
    this.screenName,
  });

  final bool captureInitialScreenView;
  final Widget child;
  final SessionRecorder recorder;
  final String? screenName;

  @override
  State<SessionRecorderScope> createState() => _SessionRecorderScopeState();
}

class _SessionRecorderScopeState extends State<SessionRecorderScope> with WidgetsBindingObserver {
  final GlobalKey _captureBoundaryKey = GlobalKey(debugLabel: 'SessionRecorderCaptureBoundary');
  late final FlutterCaptureCallback _captureCallback;
  bool _didTrackInitialScreen = false;
  String? _lastScreenName;
  DateTime? _lastScrollEventAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _captureCallback = _captureFlutterSnapshot;
    widget.recorder.attachFlutterCaptureCallback(_captureCallback);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _trackScreenView(reason: 'initial');
    });
  }

  @override
  void didUpdateWidget(covariant SessionRecorderScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.screenName != widget.screenName) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _trackScreenView(reason: 'updated');
      });
    }
  }

  @override
  void dispose() {
    widget.recorder.detachFlutterCaptureCallback(_captureCallback);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<FlutterCaptureResult?> _captureFlutterSnapshot() async {
    final BuildContext? boundaryContext = _captureBoundaryKey.currentContext;
    if (boundaryContext == null) {
      return null;
    }
    final RenderObject? renderObject = boundaryContext.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) {
      return null;
    }
    // Tree isn't fully laid out / painted yet. Skipping is safer than
    // forcing a paint — we'll catch up on the next tick. debugNeedsPaint is
    // only initialized when asserts are enabled (reading it in a release
    // build throws a LateInitializationError), so it must be read inside an
    // assert closure; the layer null check covers the never-painted case in
    // release, where toImage's `layer!` would otherwise throw.
    bool needsPaint = false;
    assert(() {
      needsPaint = renderObject.debugNeedsPaint;
      return true;
    }());
    // Reading `layer` outside a RenderObject subclass is the only
    // release-safe way to detect the never-painted state.
    // ignore: invalid_use_of_protected_member
    if (needsPaint || renderObject.layer == null) {
      return null;
    }

    // Choose a pixelRatio that targets nativeSnapshotMaxDimension on the
    // longest side, mirroring the native plugin's capture sizing.
    final double devicePixelRatio = View.of(boundaryContext).devicePixelRatio;
    final Size boundarySize = renderObject.size;
    final double longestSide = math.max(boundarySize.width, boundarySize.height);
    double pixelRatio = devicePixelRatio;
    if (longestSide > 0) {
      final int maxDimension = widget.recorder.config.nativeSnapshotMaxDimension;
      pixelRatio = math.min(devicePixelRatio, maxDimension / longestSide);
    }

    // The captured image is sized in physical pixels (boundarySize *
    // pixelRatio), but interaction events (taps) are recorded in logical
    // pixels. The replay viewer needs the logical dimensions to place
    // interaction markers in the same coordinate space; ship them alongside
    // the physical image dimensions.
    final int logicalWidth = boundarySize.width.round();
    final int logicalHeight = boundarySize.height.round();

    // If an iOS system modal is currently presented over the Flutter view,
    // toImage would only capture the (likely dimmed) Flutter content
    // underneath — misleading in replay. Substitute a labeled placeholder
    // so the viewer sees what was actually on screen.
    final String? modalLabel = widget.recorder.activeModalLabel;
    if (modalLabel != null) {
      final int imageWidth = (boundarySize.width * pixelRatio).round();
      final int imageHeight = (boundarySize.height * pixelRatio).round();
      return _generateModalPlaceholder(
        modalLabel,
        imageWidth,
        imageHeight,
        logicalWidth,
        logicalHeight,
      );
    }

    // The keyboard, when open, lives outside the Flutter view (iOS-managed
    // chrome) but shrinks Flutter via viewInsets.bottom. The captured
    // boundary won't include it. Read the inset once now so we can append
    // a "Keyboard" placeholder strip below the captured Flutter content.
    final double keyboardInsetLogical =
        View.of(boundaryContext).viewInsets.bottom / devicePixelRatio;
    final double keyboardInsetPixels = keyboardInsetLogical * pixelRatio;

    // Walk the widget tree synchronously BEFORE the async toImage call so we
    // capture rects against the same frame state the image will render. If
    // we walked after the await we'd risk the tree mutating between the
    // image render and our annotation overlay.
    final List<_PlatformViewInfo> platformViews = _findPlatformViews(
      boundaryContext,
      renderObject,
      pixelRatio,
    );

    ui.Image? rawImage;
    ui.Image? compositedImage;
    ui.Image? finalImage;
    try {
      rawImage = await renderObject.toImage(pixelRatio: pixelRatio);

      ui.Image imageToEncode;
      if (platformViews.isEmpty) {
        imageToEncode = rawImage;
      } else {
        compositedImage = await _compositePlatformViewLabels(
          rawImage,
          platformViews,
        );
        imageToEncode = compositedImage;
      }

      // Overlay a "Keyboard" placeholder at the bottom of the captured
      // image when the iOS keyboard is up. The RepaintBoundary stays at
      // full-screen size; the Scaffold inside shrinks its body to fit
      // above the keyboard, leaving Flutter's background painted in the
      // bottom strip where iOS visually shows the keyboard. We overlay a
      // labeled rect over that strip so the replay viewer sees a clear
      // "Keyboard" marker without changing the captured image's
      // dimensions.
      if (keyboardInsetPixels >= 1.0) {
        finalImage = await _overlayKeyboardLabel(
          imageToEncode,
          keyboardInsetPixels.round(),
        );
        imageToEncode = finalImage;
      }

      final ByteData? byteData =
          await imageToEncode.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        return null;
      }
      return FlutterCaptureResult(
        bytes: byteData.buffer.asUint8List(),
        width: imageToEncode.width,
        height: imageToEncode.height,
        metadata: <String, Object?>{
          'logicalWidth': logicalWidth,
          'logicalHeight': logicalHeight,
          if (platformViews.isNotEmpty)
            'platformViews': <Map<String, Object?>>[
              for (final _PlatformViewInfo info in platformViews)
                <String, Object?>{
                  'viewType': info.viewType,
                  'label': info.label,
                  'x': info.rect.left.round(),
                  'y': info.rect.top.round(),
                  'width': info.rect.width.round(),
                  'height': info.rect.height.round(),
                },
            ],
          if (keyboardInsetPixels >= 1.0)
            'keyboardHeightPx': keyboardInsetPixels.round(),
        },
      );
    } finally {
      rawImage?.dispose();
      compositedImage?.dispose();
      finalImage?.dispose();
    }
  }

  /// Builds a labeled "[modalLabel]" full-screen placeholder image at the
  /// configured capture dimensions. Used when an iOS modal (share sheet,
  /// photo picker, alert, etc.) is presented over the Flutter view, where
  /// `toImage` would only capture the dimmed Flutter content underneath.
  Future<FlutterCaptureResult?> _generateModalPlaceholder(
    String label,
    int width,
    int height,
    int logicalWidth,
    int logicalHeight,
  ) async {
    if (width <= 0 || height <= 0) {
      return null;
    }
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final Rect bounds =
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    canvas.drawRect(
      bounds,
      Paint()
        ..color = const Color(0xFFCCCCCC)
        ..style = PaintingStyle.fill,
    );
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Color(0xFF1A1A1A),
          fontSize: 28,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 2,
      ellipsis: '…',
      textAlign: TextAlign.center,
    )..layout(maxWidth: bounds.width - 32);
    painter.paint(
      canvas,
      Offset(
        bounds.left + (bounds.width - painter.width) / 2,
        bounds.top + (bounds.height - painter.height) / 2,
      ),
    );
    painter.dispose();

    final ui.Picture picture = recorder.endRecording();
    ui.Image? placeholder;
    try {
      placeholder = await picture.toImage(width, height);
      final ByteData? byteData =
          await placeholder.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        return null;
      }
      return FlutterCaptureResult(
        bytes: byteData.buffer.asUint8List(),
        width: placeholder.width,
        height: placeholder.height,
        metadata: <String, Object?>{
          'placeholder': 'system_modal',
          'modalLabel': label,
          'logicalWidth': logicalWidth,
          'logicalHeight': logicalHeight,
        },
      );
    } finally {
      picture.dispose();
      placeholder?.dispose();
    }
  }

  /// Returns a new image identical to [background] except for a labeled
  /// "Keyboard" rect overlaid on the bottom [stripHeight] pixels — the
  /// region where the iOS keyboard visually sits. The image's dimensions
  /// are unchanged, so the replay timeline stays consistent across
  /// keyboard-up/down transitions and viewers don't see a jarring
  /// resize-to-fit jump.
  Future<ui.Image> _overlayKeyboardLabel(
    ui.Image background,
    int stripHeight,
  ) async {
    final int width = background.width;
    final int height = background.height;
    final int clampedStripHeight = math.min(stripHeight, height);
    if (clampedStripHeight <= 0) {
      // Nothing meaningful to overlay; return a clone of the source.
      return background;
    }

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.drawImage(background, Offset.zero, Paint());

    final Rect stripRect = Rect.fromLTWH(
      0,
      (height - clampedStripHeight).toDouble(),
      width.toDouble(),
      clampedStripHeight.toDouble(),
    );
    canvas.drawRect(
      stripRect,
      Paint()
        ..color = const Color(0xFFD8D8D8)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRect(
      stripRect,
      Paint()
        ..color = const Color(0xFF8F8F8F)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    final TextPainter painter = TextPainter(
      text: const TextSpan(
        text: 'Keyboard',
        style: TextStyle(
          color: Color(0xFF2A2A2A),
          fontSize: 22,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
      textAlign: TextAlign.center,
    )..layout(maxWidth: stripRect.width - 32);
    painter.paint(
      canvas,
      Offset(
        stripRect.left + (stripRect.width - painter.width) / 2,
        stripRect.top + (stripRect.height - painter.height) / 2,
      ),
    );
    painter.dispose();

    final ui.Picture picture = recorder.endRecording();
    try {
      return await picture.toImage(width, height);
    } finally {
      picture.dispose();
    }
  }

  Future<ui.Image> _compositePlatformViewLabels(
    ui.Image background,
    List<_PlatformViewInfo> platformViews,
  ) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.drawImage(background, Offset.zero, Paint());

    final Rect imageBounds = Rect.fromLTWH(
      0,
      0,
      background.width.toDouble(),
      background.height.toDouble(),
    );

    final Paint fillPaint = Paint()
      ..color = const Color(0xFFE6E6E6)
      ..style = PaintingStyle.fill;
    final Paint borderPaint = Paint()
      ..color = const Color(0xFF8F8F8F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    for (final _PlatformViewInfo pv in platformViews) {
      final Rect clipped = pv.rect.intersect(imageBounds);
      if (clipped.isEmpty) {
        continue;
      }
      canvas.drawRect(clipped, fillPaint);
      canvas.drawRect(clipped, borderPaint);

      final TextPainter painter = TextPainter(
        text: TextSpan(
          text: pv.label,
          style: const TextStyle(
            color: Color(0xFF333333),
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 2,
        ellipsis: '…',
        textAlign: TextAlign.center,
      )..layout(maxWidth: math.max(0, clipped.width - 16));

      final double labelDx = clipped.left + (clipped.width - painter.width) / 2;
      final double labelDy =
          clipped.top + (clipped.height - painter.height) / 2;
      painter.paint(canvas, Offset(labelDx, labelDy));
      painter.dispose();
    }

    final ui.Picture picture = recorder.endRecording();
    try {
      return await picture.toImage(background.width, background.height);
    } finally {
      picture.dispose();
    }
  }

  /// Walks the widget subtree rooted at [boundaryContext] looking for
  /// embedded native widgets (PlatformViews). Returns their rects in the
  /// boundary's coordinate space, already scaled by [pixelRatio] to match
  /// the dimensions of the image produced by toImage(pixelRatio: ...).
  List<_PlatformViewInfo> _findPlatformViews(
    BuildContext boundaryContext,
    RenderObject boundaryRenderObject,
    double pixelRatio,
  ) {
    final List<_PlatformViewInfo> results = <_PlatformViewInfo>[];

    void visit(Element element) {
      final Widget element$widget = element.widget;
      final String? viewType = _platformViewType(element$widget);
      if (viewType != null) {
        final RenderObject? ro = element.renderObject;
        if (ro is RenderBox && ro.hasSize && ro.attached) {
          // localToGlobal with ancestor=boundary gives us the rect in the
          // boundary's coordinate space, which is exactly what toImage's
          // output coordinates use.
          final Offset originInBoundary = ro.localToGlobal(
            Offset.zero,
            ancestor: boundaryRenderObject,
          );
          results.add(_PlatformViewInfo(
            viewType: viewType,
            label: _labelForViewType(viewType),
            rect: Rect.fromLTWH(
              originInBoundary.dx * pixelRatio,
              originInBoundary.dy * pixelRatio,
              ro.size.width * pixelRatio,
              ro.size.height * pixelRatio,
            ),
          ));
          // Don't recurse into the platform view's own subtree — there's
          // nothing meaningful inside a UiKitView/AndroidView for our
          // purposes, and the subtree may contain placeholder widgets that
          // would generate spurious labels.
          return;
        }
      }
      element.visitChildren(visit);
    }

    boundaryContext.visitChildElements(visit);
    return results;
  }

  static String? _platformViewType(Widget widget) {
    if (widget is AndroidView) {
      return widget.viewType;
    }
    if (widget is UiKitView) {
      return widget.viewType;
    }
    if (widget is HtmlElementView) {
      return widget.viewType;
    }
    if (widget is PlatformViewLink) {
      return widget.viewType;
    }
    return null;
  }

  static String _labelForViewType(String viewType) {
    return _knownPlatformViewLabels[viewType] ?? viewType;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _trackScreenView(reason: 'resume');
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (!widget.recorder.isRecording || widget.recorder.isCapturePaused || !widget.recorder.config.captureScrolls) {
      return false;
    }

    if (notification is! ScrollUpdateNotification && notification is! ScrollEndNotification) {
      return false;
    }

    final DateTime now = DateTime.now().toUtc();
    if (notification is ScrollUpdateNotification) {
      final DateTime? lastScrollEventAt = _lastScrollEventAt;
      if (lastScrollEventAt != null && now.difference(lastScrollEventAt) < widget.recorder.config.scrollEventThrottle) {
        return false;
      }
    }
    _lastScrollEventAt = now;

    final ScrollMetrics metrics = notification.metrics;
    widget.recorder.trackScroll(
      axis: metrics.axis.name,
      maxScrollExtent: metrics.maxScrollExtent,
      pixels: metrics.pixels,
      screenName: _resolvedScreenName(),
      viewportDimension: metrics.viewportDimension,
      properties: <String, Object?>{
        'source': 'flutter_scope',
        'phase': notification is ScrollEndNotification ? 'end' : 'update',
      },
    );
    return false;
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (!widget.recorder.isRecording || widget.recorder.isCapturePaused || !widget.recorder.config.captureTaps) {
      return;
    }

    widget.recorder.trackTap(
      dx: event.position.dx,
      dy: event.position.dy,
      screenName: _resolvedScreenName(),
      properties: const <String, Object?>{
        'source': 'flutter_scope',
      },
    );
  }

  void _trackScreenView({required String reason}) {
    if (!_didTrackInitialScreen) {
      _didTrackInitialScreen = true;
      if (!widget.captureInitialScreenView) {
        return;
      }
    }

    if (!widget.recorder.isRecording || !widget.recorder.config.captureNavigation) {
      return;
    }

    final String screenName = _resolvedScreenName();
    if (_lastScreenName == screenName && reason != 'updated') {
      return;
    }

    _lastScreenName = screenName;
    widget.recorder.trackScreenView(
      screenName,
      properties: <String, Object?>{
        'source': 'flutter_scope',
        'reason': reason,
      },
    );
  }

  String _resolvedScreenName() {
    final String? explicitName = widget.screenName?.trim();
    if (explicitName != null && explicitName.isNotEmpty) {
      return explicitName;
    }

    final ModalRoute<Object?>? route = ModalRoute.of(context);
    final String? routeName = route?.settings.name?.trim();
    if (routeName != null && routeName.isNotEmpty) {
      return routeName;
    }

    return 'unknown';
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerUp: _handlePointerUp,
        // RepaintBoundary gives us a stable RenderObject root that toImage()
        // can render off the main thread. Wrapping at the SessionRecorderScope
        // level captures the entire app subtree the scope wraps, which is
        // typically the full Flutter view in a MaterialApp.builder.
        child: RepaintBoundary(
          key: _captureBoundaryKey,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Friendly labels for well-known plugin viewType identifiers. Unknown
/// viewType strings fall back to the raw identifier so hosts can still see
/// "plugins.com.acme/custom-foo" rather than an empty placeholder.
const Map<String, String> _knownPlatformViewLabels = <String, String>{
  'plugins.flutter.io/google_maps': 'Map',
  'plugins.flutter.io/google_maps_ios': 'Map',
  'plugins.flutter.io/google_maps_android': 'Map',
  'plugins.flutter.io/webview': 'Web view',
  'plugins.flutter.io/webview_ios': 'Web view',
  'plugins.flutter.io/webview_android': 'Web view',
  'plugins.flutter.io/video_player': 'Video',
  'plugins.flutter.io/video_player_ios': 'Video',
  'plugins.flutter.io/video_player_android': 'Video',
  'plugins.flutter.io/camera': 'Camera',
  'plugins.flutter.io/camera_avfoundation': 'Camera',
  'plugins.flutter.io/camera_android': 'Camera',
};

class _PlatformViewInfo {
  const _PlatformViewInfo({
    required this.viewType,
    required this.label,
    required this.rect,
  });

  final String viewType;
  final String label;
  // Rect in the image's coordinate space (boundary-local * pixelRatio).
  final Rect rect;
}
