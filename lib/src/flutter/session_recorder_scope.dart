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

class _SessionRecorderScopeState extends State<SessionRecorderScope>
    with WidgetsBindingObserver {
  bool _didTrackInitialScreen = false;
  String? _lastScreenName;
  DateTime? _lastScrollEventAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _trackScreenView(reason: 'resume');
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (!widget.recorder.isRecording ||
        widget.recorder.isCapturePaused ||
        !widget.recorder.config.captureScrolls) {
      return false;
    }

    if (notification is! ScrollUpdateNotification &&
        notification is! ScrollEndNotification) {
      return false;
    }

    final DateTime now = DateTime.now().toUtc();
    if (notification is ScrollUpdateNotification) {
      final DateTime? lastScrollEventAt = _lastScrollEventAt;
      if (lastScrollEventAt != null &&
          now.difference(lastScrollEventAt) <
              widget.recorder.config.scrollEventThrottle) {
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
    if (!widget.recorder.isRecording ||
        widget.recorder.isCapturePaused ||
        !widget.recorder.config.captureTaps) {
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

    if (!widget.recorder.isRecording ||
        !widget.recorder.config.captureNavigation) {
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
        child: widget.child,
      ),
    );
  }
}
