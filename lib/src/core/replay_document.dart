import 'recorder_event.dart';

class ReplayDocument {
  const ReplayDocument({
    required this.customEvents,
    required this.errors,
    required this.frames,
    required this.interactions,
    required this.keyframes,
    required this.logs,
    required this.screenViews,
    required this.sessionContext,
    required this.sessionId,
    required this.sessionProperties,
    required this.startedAt,
    required this.userId,
    required this.userProperties,
  });

  final List<ReplayCustomEvent> customEvents;
  final List<ReplayError> errors;
  final List<ReplayFrame> frames;
  final List<ReplayInteraction> interactions;
  final List<ReplayKeyframe> keyframes;
  final List<ReplayLog> logs;
  final List<ReplayScreenView> screenViews;
  final Map<String, Object?> sessionContext;
  final String sessionId;
  final Map<String, Object?> sessionProperties;
  final DateTime startedAt;
  final String? userId;
  final Map<String, Object?> userProperties;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'sessionId': sessionId,
      'startedAt': startedAt.toUtc().toIso8601String(),
      'sessionContext': normalizeAttributes(sessionContext),
      'userId': userId,
      'userProperties': normalizeAttributes(userProperties),
      'sessionProperties': normalizeAttributes(sessionProperties),
      'frames': frames.map((ReplayFrame value) => value.toJson()).toList(),
      'keyframes':
          keyframes.map((ReplayKeyframe value) => value.toJson()).toList(),
      'screenViews':
          screenViews.map((ReplayScreenView value) => value.toJson()).toList(),
      'interactions': interactions
          .map((ReplayInteraction value) => value.toJson())
          .toList(),
      'logs': logs.map((ReplayLog value) => value.toJson()).toList(),
      'errors': errors.map((ReplayError value) => value.toJson()).toList(),
      'customEvents': customEvents
          .map((ReplayCustomEvent value) => value.toJson())
          .toList(),
    };
  }
}

class ReplayAssembler {
  ReplayAssembler();

  final List<RecorderEvent> _events = <RecorderEvent>[];

  void addAll(Iterable<RecorderEvent> events) {
    _events.addAll(events);
  }

  ReplayDocument build({
    required String sessionId,
    required DateTime startedAt,
    required Map<String, Object?> sessionContext,
    required Map<String, Object?> sessionProperties,
    required String? userId,
    required Map<String, Object?> userProperties,
  }) {
    final List<ReplayFrame> frames = <ReplayFrame>[];
    final List<ReplayScreenView> screenViews = <ReplayScreenView>[];
    final List<ReplayInteraction> interactions = <ReplayInteraction>[];
    final List<ReplayKeyframe> keyframes = <ReplayKeyframe>[];
    final List<ReplayLog> logs = <ReplayLog>[];
    final List<ReplayError> errors = <ReplayError>[];
    final List<ReplayCustomEvent> customEvents = <ReplayCustomEvent>[];

    for (final RecorderEvent event in _events) {
      switch (event.type) {
        case 'replay.frame':
          frames.add(ReplayFrame.fromRecorderEvent(event));
        case 'replay.keyframe':
          keyframes.add(ReplayKeyframe.fromRecorderEvent(event));
        case 'screen.view':
          screenViews.add(ReplayScreenView.fromRecorderEvent(event));
        case 'interaction.tap':
        case 'interaction.scroll':
          interactions.add(ReplayInteraction.fromRecorderEvent(event));
        case 'log':
          logs.add(ReplayLog.fromRecorderEvent(event));
        case 'error':
          errors.add(ReplayError.fromRecorderEvent(event));
        case 'custom':
          customEvents.add(ReplayCustomEvent.fromRecorderEvent(event));
      }
    }

    return ReplayDocument(
      customEvents: customEvents,
      errors: errors,
      frames: frames,
      interactions: interactions,
      keyframes: keyframes,
      logs: logs,
      screenViews: screenViews,
      sessionContext: sessionContext,
      sessionId: sessionId,
      sessionProperties: sessionProperties,
      startedAt: startedAt,
      userId: userId,
      userProperties: userProperties,
    );
  }
}

class ReplayFrame {
  const ReplayFrame({
    required this.metadata,
    required this.screenName,
    required this.timestamp,
    required this.tree,
    required this.viewport,
  });

  final Map<String, Object?> metadata;
  final String? screenName;
  final DateTime timestamp;
  final Map<String, Object?> tree;
  final Map<String, Object?> viewport;

  factory ReplayFrame.fromRecorderEvent(RecorderEvent event) {
    return ReplayFrame(
      metadata: Map<String, Object?>.from(
        (event.attributes['metadata'] as Map<Object?, Object?>?) ??
            <Object?, Object?>{},
      ),
      screenName: event.attributes['screenName'] as String?,
      timestamp: event.timestamp,
      tree: Map<String, Object?>.from(
        (event.attributes['tree'] as Map<Object?, Object?>?) ??
            <Object?, Object?>{},
      ),
      viewport: Map<String, Object?>.from(
        (event.attributes['viewport'] as Map<Object?, Object?>?) ??
            <Object?, Object?>{},
      ),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'screenName': screenName,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'metadata': normalizeAttributes(metadata),
      'tree': normalizeAttributes(tree),
      'viewport': normalizeAttributes(viewport),
    };
  }
}

class ReplayKeyframe {
  const ReplayKeyframe({
    required this.frameRef,
    required this.metadata,
    required this.reason,
    required this.screenName,
    required this.timestamp,
    required this.viewport,
  });

  final String frameRef;
  final Map<String, Object?> metadata;
  final String reason;
  final String? screenName;
  final DateTime timestamp;
  final Map<String, Object?> viewport;

  factory ReplayKeyframe.fromRecorderEvent(RecorderEvent event) {
    return ReplayKeyframe(
      frameRef: (event.attributes['frameRef'] as String?) ?? '',
      metadata: Map<String, Object?>.from(
        (event.attributes['metadata'] as Map<Object?, Object?>?) ??
            <Object?, Object?>{},
      ),
      reason: (event.attributes['reason'] as String?) ?? 'unknown',
      screenName: event.attributes['screenName'] as String?,
      timestamp: event.timestamp,
      viewport: Map<String, Object?>.from(
        (event.attributes['viewport'] as Map<Object?, Object?>?) ??
            <Object?, Object?>{},
      ),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'frameRef': frameRef,
      'metadata': normalizeAttributes(metadata),
      'reason': reason,
      'screenName': screenName,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'viewport': normalizeAttributes(viewport),
    };
  }
}

class ReplayScreenView {
  const ReplayScreenView({
    required this.name,
    required this.properties,
    required this.timestamp,
  });

  final String name;
  final Map<String, Object?> properties;
  final DateTime timestamp;

  factory ReplayScreenView.fromRecorderEvent(RecorderEvent event) {
    return ReplayScreenView(
      name: (event.attributes['screenName'] as String?) ?? 'unknown',
      properties: Map<String, Object?>.from(
        (event.attributes['properties'] as Map<Object?, Object?>?) ??
            <Object?, Object?>{},
      ),
      timestamp: event.timestamp,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'name': name,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'properties': normalizeAttributes(properties),
    };
  }
}

class ReplayInteraction {
  const ReplayInteraction({
    required this.attributes,
    required this.timestamp,
    required this.type,
  });

  final Map<String, Object?> attributes;
  final DateTime timestamp;
  final String type;

  factory ReplayInteraction.fromRecorderEvent(RecorderEvent event) {
    return ReplayInteraction(
      attributes: event.attributes,
      timestamp: event.timestamp,
      type: event.type,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'type': type,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'attributes': normalizeAttributes(attributes),
    };
  }
}

class ReplayLog {
  const ReplayLog({
    required this.level,
    required this.logger,
    required this.message,
    required this.properties,
    required this.timestamp,
  });

  final String level;
  final String? logger;
  final String message;
  final Map<String, Object?> properties;
  final DateTime timestamp;

  factory ReplayLog.fromRecorderEvent(RecorderEvent event) {
    return ReplayLog(
      level: (event.attributes['level'] as String?) ?? 'info',
      logger: event.attributes['logger'] as String?,
      message: (event.attributes['message'] as String?) ?? '',
      properties: Map<String, Object?>.from(
        (event.attributes['properties'] as Map<Object?, Object?>?) ??
            <Object?, Object?>{},
      ),
      timestamp: event.timestamp,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'level': level,
      'logger': logger,
      'message': message,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'properties': normalizeAttributes(properties),
    };
  }
}

class ReplayError {
  const ReplayError({
    required this.error,
    required this.logger,
    required this.message,
    required this.properties,
    required this.stackTrace,
    required this.timestamp,
  });

  final String error;
  final String? logger;
  final String? message;
  final Map<String, Object?> properties;
  final String? stackTrace;
  final DateTime timestamp;

  factory ReplayError.fromRecorderEvent(RecorderEvent event) {
    return ReplayError(
      error: (event.attributes['error'] as String?) ?? '',
      logger: event.attributes['logger'] as String?,
      message: event.attributes['message'] as String?,
      properties: Map<String, Object?>.from(
        (event.attributes['properties'] as Map<Object?, Object?>?) ??
            <Object?, Object?>{},
      ),
      stackTrace: event.attributes['stackTrace'] as String?,
      timestamp: event.timestamp,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'error': error,
      'logger': logger,
      'message': message,
      'stackTrace': stackTrace,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'properties': normalizeAttributes(properties),
    };
  }
}

class ReplayCustomEvent {
  const ReplayCustomEvent({
    required this.name,
    required this.properties,
    required this.timestamp,
  });

  final String name;
  final Map<String, Object?> properties;
  final DateTime timestamp;

  factory ReplayCustomEvent.fromRecorderEvent(RecorderEvent event) {
    return ReplayCustomEvent(
      name: (event.attributes['name'] as String?) ?? 'custom',
      properties: Map<String, Object?>.from(
        (event.attributes['properties'] as Map<Object?, Object?>?) ??
            <Object?, Object?>{},
      ),
      timestamp: event.timestamp,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'name': name,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'properties': normalizeAttributes(properties),
    };
  }
}
