import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../core/session_recorder.dart';

typedef SessionRecorderKeyframeCapture
    = Future<SessionRecorderCapturedKeyframe?> Function(
  RenderRepaintBoundary boundary,
  BuildContext boundaryContext,
  double devicePixelRatio,
  double captureScale,
);

class SessionRecorderCapturedKeyframe {
  const SessionRecorderCapturedKeyframe({
    required this.bytes,
    required this.imageHeight,
    required this.imageWidth,
  });

  final Uint8List bytes;
  final int imageHeight;
  final int imageWidth;
}

class SessionRecorderScope extends StatefulWidget {
  const SessionRecorderScope({
    required this.child,
    required this.recorder,
    super.key,
    this.captureInitialScreenView = true,
    this.keyframeCapture,
    this.screenName,
  });

  final bool captureInitialScreenView;
  final Widget child;
  final SessionRecorderKeyframeCapture? keyframeCapture;
  final SessionRecorder recorder;
  final String? screenName;

  @override
  State<SessionRecorderScope> createState() => _SessionRecorderScopeState();
}

class _SessionRecorderScopeState extends State<SessionRecorderScope>
    with WidgetsBindingObserver {
  final GlobalKey _boundaryKey = GlobalKey();

  bool _didTrackInitialScreen = false;
  bool _isCapturingKeyframe = false;
  String? _lastKeyframeReason;
  String? _lastScreenName;
  DateTime? _activeCaptureUntil;
  DateTime? _lastScrollKeyframeAt;
  ScrollMetrics? _lastScrollMetrics;
  Timer? _activeCaptureTimer;
  Timer? _intervalTimer;
  Uint8List? _lastUploadedKeyframeBytes;
  bool _resumeKeyframePending = false;
  _PendingKeyframe? _pendingKeyframe;

  @override
  void initState() {
    super.initState();
    widget.recorder.addCaptureStateListener(_handleCaptureStateChanged);
    widget.recorder.addScreenViewListener(_handleScreenViewRecorded);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _trackScreenView(reason: 'initial');
      _restartIntervalTimer();
    });
  }

  @override
  void didUpdateWidget(covariant SessionRecorderScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recorder != widget.recorder) {
      oldWidget.recorder.removeCaptureStateListener(_handleCaptureStateChanged);
      oldWidget.recorder.removeScreenViewListener(_handleScreenViewRecorded);
      widget.recorder.addCaptureStateListener(_handleCaptureStateChanged);
      widget.recorder.addScreenViewListener(_handleScreenViewRecorded);
    }
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
    widget.recorder.removeCaptureStateListener(_handleCaptureStateChanged);
    widget.recorder.removeScreenViewListener(_handleScreenViewRecorded);
    WidgetsBinding.instance.removeObserver(this);
    _activeCaptureTimer?.cancel();
    _intervalTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _restartIntervalTimer();
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _activeCaptureTimer?.cancel();
        _intervalTimer?.cancel();
        _activeCaptureUntil = null;
        _isCapturingKeyframe = false;
        _lastScrollKeyframeAt = null;
        _pendingKeyframe = null;
        _resumeKeyframePending = false;
        break;
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _handleCaptureStateChanged(bool isPaused) {
    if (!mounted) {
      return;
    }

    if (isPaused) {
      _activeCaptureTimer?.cancel();
      _intervalTimer?.cancel();
      _activeCaptureUntil = null;
      _isCapturingKeyframe = false;
      _lastScrollKeyframeAt = null;
      _pendingKeyframe = null;
      _resumeKeyframePending = false;
      return;
    }

    _restartIntervalTimer();
    if (widget.recorder.config.captureHybridKeyframes &&
        widget.recorder.config.captureKeyframeOnResume) {
      _resumeKeyframePending = true;
      _startActiveCaptureWindow(reason: 'resume');
      _scheduleKeyframeCapture(reason: 'resume');
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    _lastScrollMetrics = notification.metrics;
    if (widget.recorder.config.captureHybridKeyframes &&
        widget.recorder.config.captureAdaptiveHybridKeyframes) {
      _startActiveCaptureWindow(reason: 'scroll');
    }

    if (notification is ScrollUpdateNotification &&
        widget.recorder.config.captureHybridKeyframes &&
        widget.recorder.config.captureKeyframesDuringScroll) {
      final DateTime now = DateTime.now().toUtc();
      final DateTime? lastScrollKeyframeAt = _lastScrollKeyframeAt;
      if (lastScrollKeyframeAt == null ||
          now.difference(lastScrollKeyframeAt) >=
              widget.recorder.config.scrollKeyframeThrottle) {
        _lastScrollKeyframeAt = now;
        _scheduleKeyframeCapture(
          reason: 'scroll_update',
          triggerAttributes: <String, Object?>{
            'axis': notification.metrics.axis.name,
            'pixels': notification.metrics.pixels,
            'viewportDimension': notification.metrics.viewportDimension,
          },
        );
      }
    }

    if (notification is ScrollEndNotification &&
        widget.recorder.config.captureHybridKeyframes &&
        widget.recorder.config.captureKeyframeOnScrollEnd) {
      _scheduleKeyframeCapture(reason: 'scroll_end');
    }
    return false;
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (!widget.recorder.config.captureHybridKeyframes ||
        !widget.recorder.config.captureKeyframeOnTap) {
      return;
    }

    _scheduleKeyframeCapture(
      reason: 'tap',
      triggerAttributes: <String, Object?>{
        'dx': event.position.dx,
        'dy': event.position.dy,
      },
    );
    _startActiveCaptureWindow(reason: 'tap');
  }

  void _trackScreenView({required String reason}) {
    if (!_didTrackInitialScreen) {
      _didTrackInitialScreen = true;
      if (!widget.captureInitialScreenView) {
        return;
      }
    }

    if (!widget.recorder.isRecording) {
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

  void _handleScreenViewRecorded(
    String screenName,
    Map<String, Object?> properties,
  ) {
    _lastScreenName = screenName;
    if (!widget.recorder.config.captureHybridKeyframes ||
        !widget.recorder.config.captureKeyframeOnScreenView) {
      return;
    }

    _scheduleKeyframeCapture(
      reason: 'screen_view',
      triggerAttributes: <String, Object?>{
        'properties': properties,
        'screenName': screenName,
      },
    );
    _startActiveCaptureWindow(reason: 'screen_view');
  }

  void _restartIntervalTimer() {
    _intervalTimer?.cancel();
    if (!widget.recorder.config.captureHybridKeyframes ||
        widget.recorder.isCapturePaused ||
        !widget.recorder.isRecording) {
      return;
    }

    final Duration interval = _currentKeyframeInterval();
    _intervalTimer = Timer.periodic(
      interval,
      (_) => _scheduleKeyframeCapture(reason: 'interval'),
    );
  }

  Duration _currentKeyframeInterval() {
    if (widget.recorder.config.captureAdaptiveHybridKeyframes &&
        _isInActiveCaptureWindow) {
      return widget.recorder.config.activeHybridKeyframeInterval;
    }
    return widget.recorder.config.hybridKeyframeInterval;
  }

  bool get _isInActiveCaptureWindow {
    final DateTime? activeCaptureUntil = _activeCaptureUntil;
    if (activeCaptureUntil == null) {
      return false;
    }
    return DateTime.now().toUtc().isBefore(activeCaptureUntil);
  }

  void _startActiveCaptureWindow({
    required String reason,
  }) {
    if (!widget.recorder.config.captureAdaptiveHybridKeyframes ||
        !widget.recorder.config.captureHybridKeyframes ||
        !widget.recorder.isRecording ||
        widget.recorder.isCapturePaused) {
      return;
    }

    _activeCaptureUntil = DateTime.now()
        .toUtc()
        .add(widget.recorder.config.activeHybridKeyframeWindow);
    _activeCaptureTimer?.cancel();
    _activeCaptureTimer = Timer(
      widget.recorder.config.activeHybridKeyframeWindow,
      () {
        _activeCaptureUntil = null;
        _restartIntervalTimer();
      },
    );
    _restartIntervalTimer();

    if (reason == 'screen_view' || reason == 'resume') {
      return;
    }
  }

  void _scheduleKeyframeCapture({
    required String reason,
    Map<String, Object?> triggerAttributes = const <String, Object?>{},
  }) {
    if (!mounted ||
        !widget.recorder.isRecording ||
        widget.recorder.isCapturePaused ||
        !widget.recorder.config.captureHybridKeyframes) {
      return;
    }

    final _PendingKeyframe request = _PendingKeyframe(
      reason:
          reason == 'interval' && _resumeKeyframePending ? 'resume' : reason,
      triggerAttributes: triggerAttributes,
    );

    if (_isCapturingKeyframe) {
      _pendingKeyframe = request;
      return;
    }

    _isCapturingKeyframe = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _captureKeyframe(request);
      _isCapturingKeyframe = false;

      final _PendingKeyframe? pendingKeyframe = _pendingKeyframe;
      _pendingKeyframe = null;
      if (pendingKeyframe != null) {
        _scheduleKeyframeCapture(
          reason: pendingKeyframe.reason,
          triggerAttributes: pendingKeyframe.triggerAttributes,
        );
      }
    });
  }

  Future<void> _captureKeyframe(_PendingKeyframe request) async {
    if (!mounted ||
        !widget.recorder.isRecording ||
        widget.recorder.isCapturePaused ||
        !widget.recorder.config.captureHybridKeyframes) {
      return;
    }

    final BuildContext? boundaryContext = _boundaryKey.currentContext;
    if (boundaryContext == null) {
      _retryKeyframeCapture(request);
      return;
    }

    final RenderObject? renderObject = boundaryContext.findRenderObject();
    if (renderObject is! RenderRepaintBoundary ||
        renderObject.debugNeedsPaint) {
      _retryKeyframeCapture(request);
      return;
    }

    final ui.FlutterView view = View.of(boundaryContext);
    final Size logicalSize = renderObject.size;
    if (logicalSize.isEmpty) {
      _retryKeyframeCapture(request);
      return;
    }

    final String resolvedScreenName = _resolvedScreenName();
    final double devicePixelRatio = view.devicePixelRatio;
    final EdgeInsets viewPadding =
        MediaQuery.maybeOf(boundaryContext)?.viewPadding ??
            EdgeInsets.fromViewPadding(view.viewPadding, devicePixelRatio);
    final Map<String, Object?> contentHints =
        _collectFlutterContentHints(boundaryContext);
    final double longestSide = logicalSize.longestSide;
    final double maxDimension =
        widget.recorder.config.hybridKeyframeMaxDimension.toDouble();
    final double captureScale = longestSide <= 0
        ? 1
        : (maxDimension / (longestSide * devicePixelRatio))
            .clamp(0.15, 1.0)
            .toDouble();

    final SessionRecorderCapturedKeyframe? capturedKeyframe =
        await (widget.keyframeCapture?.call(
              renderObject,
              boundaryContext,
              devicePixelRatio,
              captureScale,
            ) ??
            _captureBoundaryKeyframe(
              renderObject,
              devicePixelRatio: devicePixelRatio,
              captureScale: captureScale,
            ));

    if (capturedKeyframe == null) {
      _retryKeyframeCapture(request);
      return;
    }

    final Uint8List bytes = capturedKeyframe.bytes;
    if (widget.recorder.config.dedupeIdenticalKeyframes &&
        _lastUploadedKeyframeBytes != null &&
        listEquals(_lastUploadedKeyframeBytes, bytes)) {
      return;
    }

    _lastUploadedKeyframeBytes = Uint8List.fromList(bytes);
    _lastKeyframeReason = request.reason;
    if (request.reason == 'resume') {
      _resumeKeyframePending = false;
    }

    await widget.recorder.trackKeyframe(
      bytes: bytes,
      reason: request.reason,
      screenName: resolvedScreenName,
      viewport: _buildViewport(
        logicalSize,
        devicePixelRatio,
        capturedKeyframe.imageWidth,
        capturedKeyframe.imageHeight,
        viewPadding,
      ),
      metadata: <String, Object?>{
        'contentHints': contentHints,
        'format': 'png',
        'lastKnownScroll': _scrollMetricsToMap(_lastScrollMetrics),
        'trigger': request.triggerAttributes,
        'triggerReason': request.reason,
        'visualSource': 'flutter_root_capture',
      },
    );
  }

  void _retryKeyframeCapture(_PendingKeyframe request) {
    if (!mounted ||
        !widget.recorder.isRecording ||
        widget.recorder.isCapturePaused ||
        !widget.recorder.config.captureHybridKeyframes) {
      return;
    }

    _pendingKeyframe = request;
    WidgetsBinding.instance.scheduleFrame();
  }

  Map<String, Object?> _buildViewport(
    Size logicalSize,
    double devicePixelRatio,
    int imageWidth,
    int imageHeight,
    EdgeInsets viewPadding,
  ) {
    return <String, Object?>{
      'devicePixelRatio': devicePixelRatio,
      'height': logicalSize.height,
      'imageHeight': imageHeight,
      'imageWidth': imageWidth,
      'lastKnownScroll': _scrollMetricsToMap(_lastScrollMetrics),
      'safeAreaInsets': <String, Object?>{
        'bottom': viewPadding.bottom,
        'left': viewPadding.left,
        'right': viewPadding.right,
        'top': viewPadding.top,
      },
      'width': logicalSize.width,
    };
  }

  Future<SessionRecorderCapturedKeyframe?> _captureBoundaryKeyframe(
    RenderRepaintBoundary boundary, {
    required double devicePixelRatio,
    required double captureScale,
  }) async {
    final ui.Image image = await boundary.toImage(
      pixelRatio: devicePixelRatio * captureScale,
    );
    try {
      final ByteData? byteData = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (byteData == null) {
        return null;
      }

      return SessionRecorderCapturedKeyframe(
        bytes: byteData.buffer.asUint8List(),
        imageHeight: image.height,
        imageWidth: image.width,
      );
    } finally {
      image.dispose();
    }
  }

  Map<String, Object?> _collectFlutterContentHints(
      BuildContext boundaryContext) {
    final List<String> texts = <String>[];
    final List<Map<String, Object?>> images = <Map<String, Object?>>[];
    final List<String> widgetTypes = <String>[];

    void visit(Element element) {
      final Widget widget = element.widget;
      if (widgetTypes.length < 100) {
        widgetTypes.add(widget.runtimeType.toString());
      }

      if (widget is Text) {
        final String? text = widget.data ??
            widget.textSpan?.toPlainText(includeSemanticsLabels: true);
        if (text != null && text.trim().isNotEmpty && texts.length < 50) {
          texts.add(text.trim());
        }
      } else if (widget is RichText) {
        final String text =
            widget.text.toPlainText(includeSemanticsLabels: true).trim();
        if (text.isNotEmpty && texts.length < 50) {
          texts.add(text);
        }
      } else if (widget is Image && images.length < 20) {
        final Map<String, Object?>? imageReference = _imageProviderToMetadata(
          widget.image,
        );
        if (imageReference != null) {
          images.add(imageReference);
        }
      } else if (widget is DecoratedBox && images.length < 20) {
        final Decoration decoration = widget.decoration;
        if (decoration is BoxDecoration && decoration.image != null) {
          final Map<String, Object?>? imageReference = _imageProviderToMetadata(
            decoration.image!.image,
          );
          if (imageReference != null) {
            images.add(imageReference);
          }
        }
      }

      element.visitChildElements(visit);
    }

    (boundaryContext as Element).visitChildElements(visit);

    return <String, Object?>{
      'images': images,
      'lastKeyframeReason': _lastKeyframeReason,
      'texts': texts,
      'widgetTypes': widgetTypes,
    };
  }

  Map<String, Object?>? _imageProviderToMetadata(
      ImageProvider<Object> provider) {
    if (provider is AssetImage) {
      return <String, Object?>{
        'provider': 'AssetImage',
        'source': provider.assetName,
        'package': provider.package,
      };
    }
    if (provider is ExactAssetImage) {
      return <String, Object?>{
        'provider': 'ExactAssetImage',
        'source': provider.assetName,
        'package': provider.package,
        'scale': provider.scale,
      };
    }
    if (provider is NetworkImage) {
      return <String, Object?>{
        'provider': 'NetworkImage',
        'headers': provider.headers?.keys.toList(growable: false),
        'source': provider.url,
        'scale': provider.scale,
      };
    }
    if (provider is ResizeImage) {
      return <String, Object?>{
        'provider': 'ResizeImage',
        'resizeHeight': provider.height,
        'resizeWidth': provider.width,
        'source': _imageProviderToMetadata(provider.imageProvider),
      };
    }
    return <String, Object?>{
      'provider': provider.runtimeType.toString(),
      'source': provider.toString(),
    };
  }

  Map<String, Object?>? _scrollMetricsToMap(ScrollMetrics? metrics) {
    if (metrics == null) {
      return null;
    }

    return <String, Object?>{
      'axis': metrics.axis.name,
      'maxScrollExtent': metrics.maxScrollExtent,
      'minScrollExtent': metrics.minScrollExtent,
      'pixels': metrics.pixels,
      'viewportDimension': metrics.viewportDimension,
    };
  }

  String _resolvedScreenName() {
    return widget.screenName ??
        ModalRoute.of(context)?.settings.name ??
        widget.child.runtimeType.toString();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerUp: _handlePointerUp,
        child: RepaintBoundary(
          key: _boundaryKey,
          child: widget.child,
        ),
      ),
    );
  }
}

class _PendingKeyframe {
  const _PendingKeyframe({
    required this.reason,
    required this.triggerAttributes,
  });

  final String reason;
  final Map<String, Object?> triggerAttributes;
}
