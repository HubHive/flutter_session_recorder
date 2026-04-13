import 'recorder_event.dart';

class SessionBatch {
  const SessionBatch({
    required this.events,
    required this.sentAt,
    required this.sessionContext,
    required this.sessionId,
    required this.sessionProperties,
    required this.startedAt,
    required this.userId,
    required this.userProperties,
  });

  final List<RecorderEvent> events;
  final DateTime sentAt;
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
      'sentAt': sentAt.toUtc().toIso8601String(),
      'sessionContext': normalizeAttributes(sessionContext),
      'userId': userId,
      'userProperties': normalizeAttributes(userProperties),
      'sessionProperties': normalizeAttributes(sessionProperties),
      'events': events
          .map((RecorderEvent event) => event.toJson())
          .toList(growable: false),
    };
  }
}
