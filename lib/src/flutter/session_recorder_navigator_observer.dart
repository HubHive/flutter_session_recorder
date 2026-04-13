import 'package:flutter/widgets.dart';

import '../core/session_recorder.dart';

class SessionRecorderNavigatorObserver extends NavigatorObserver {
  SessionRecorderNavigatorObserver({required SessionRecorder recorder})
      : _recorder = recorder;

  final SessionRecorder _recorder;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _trackRoute(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _trackRoute(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _trackRoute(newRoute);
  }

  void _trackRoute(Route<dynamic>? route) {
    if (!_recorder.config.captureNavigation || route == null) {
      return;
    }

    final String screenName =
        route.settings.name ?? route.runtimeType.toString();
    _recorder.trackScreenView(
      screenName,
      properties: <String, Object?>{'routeType': route.runtimeType.toString()},
    );
  }
}
