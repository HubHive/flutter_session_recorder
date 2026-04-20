import 'recorder_event.dart';

int _intAttribute(Map<String, Object?> attributes, String key) {
  final Object? value = attributes[key];
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

class ReplayDocument {
  const ReplayDocument({
    required this.customEvents,
    required this.errors,
    required this.interactions,
    required this.logs,
    required this.screenViews,
    required this.sessionContext,
    required this.sessionId,
    required this.sessionProperties,
    required this.startedAt,
    required this.userId,
    required this.userProperties,
    required this.snapshots,
  });

  final List<ReplayCustomEvent> customEvents;
  final List<ReplayError> errors;
  final List<ReplayInteraction> interactions;
  final List<ReplayLog> logs;
  final List<ReplayScreenView> screenViews;
  final Map<String, Object?> sessionContext;
  final String sessionId;
  final Map<String, Object?> sessionProperties;
  final DateTime startedAt;
  final String? userId;
  final Map<String, Object?> userProperties;
  final List<ReplaySnapshot> snapshots;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'sessionId': sessionId,
      'startedAt': startedAt.toUtc().toIso8601String(),
      'sessionContext': normalizeAttributes(sessionContext),
      'userId': userId,
      'userProperties': normalizeAttributes(userProperties),
      'sessionProperties': normalizeAttributes(sessionProperties),
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
      'snapshots':
          snapshots.map((ReplaySnapshot value) => value.toJson()).toList(),
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
    final List<ReplayScreenView> screenViews = <ReplayScreenView>[];
    final List<ReplayInteraction> interactions = <ReplayInteraction>[];
    final List<ReplayLog> logs = <ReplayLog>[];
    final List<ReplayError> errors = <ReplayError>[];
    final List<ReplayCustomEvent> customEvents = <ReplayCustomEvent>[];
    final List<ReplaySnapshot> snapshots = <ReplaySnapshot>[];

    for (final RecorderEvent event in _events) {
      switch (event.type) {
        case 'replay.snapshot':
          snapshots.add(ReplaySnapshot.fromRecorderEvent(event));
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
      interactions: interactions,
      logs: logs,
      screenViews: screenViews,
      sessionContext: sessionContext,
      sessionId: sessionId,
      sessionProperties: sessionProperties,
      startedAt: startedAt,
      userId: userId,
      userProperties: userProperties,
      snapshots: snapshots,
    );
  }
}

class ReplaySnapshot {
  const ReplaySnapshot({
    required this.format,
    required this.height,
    required this.metadata,
    required this.screenName,
    required this.sessionContext,
    required this.sessionProperties,
    required this.snapshotRef,
    required this.timestamp,
    required this.userId,
    required this.userProperties,
    required this.width,
  });

  final String format;
  final int height;
  final Map<String, Object?> metadata;
  final String? screenName;
  final Map<String, Object?> sessionContext;
  final Map<String, Object?> sessionProperties;
  final String snapshotRef;
  final DateTime timestamp;
  final String? userId;
  final Map<String, Object?> userProperties;
  final int width;

  factory ReplaySnapshot.fromRecorderEvent(RecorderEvent event) {
    return ReplaySnapshot(
      format: (event.attributes['format'] as String?) ?? 'jpg',
      height: _intAttribute(event.attributes, 'height'),
      metadata: Map<String, Object?>.from(
        (event.attributes['metadata'] as Map<Object?, Object?>?) ??
            <Object?, Object?>{},
      ),
      screenName: event.attributes['screenName'] as String?,
      sessionContext: Map<String, Object?>.from(
        (event.attributes['sessionContext'] as Map<Object?, Object?>?) ??
            <Object?, Object?>{},
      ),
      sessionProperties: Map<String, Object?>.from(
        (event.attributes['sessionProperties'] as Map<Object?, Object?>?) ??
            <Object?, Object?>{},
      ),
      snapshotRef: (event.attributes['snapshotRef'] as String?) ?? '',
      timestamp: event.timestamp,
      userId: event.attributes['userId'] as String?,
      userProperties: Map<String, Object?>.from(
        (event.attributes['userProperties'] as Map<Object?, Object?>?) ??
            <Object?, Object?>{},
      ),
      width: _intAttribute(event.attributes, 'width'),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'format': format,
      'height': height,
      'metadata': normalizeAttributes(metadata),
      'screenName': screenName,
      'sessionContext': normalizeAttributes(sessionContext),
      'sessionProperties': normalizeAttributes(sessionProperties),
      'snapshotRef': snapshotRef,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'userId': userId,
      'userProperties': normalizeAttributes(userProperties),
      'width': width,
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
