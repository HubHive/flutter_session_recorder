class SessionKeyframeUpload {
  const SessionKeyframeUpload({
    required this.bytes,
    required this.format,
    required this.metadata,
    required this.reason,
    required this.screenName,
    required this.sessionId,
    required this.timestamp,
    required this.viewport,
  });

  final List<int> bytes;
  final String format;
  final Map<String, Object?> metadata;
  final String reason;
  final String? screenName;
  final String sessionId;
  final DateTime timestamp;
  final Map<String, Object?> viewport;
}

class UploadedKeyframe {
  const UploadedKeyframe({
    required this.frameRef,
  });

  final String frameRef;
}
