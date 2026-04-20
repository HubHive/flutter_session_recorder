class SessionSnapshotUpload {
  const SessionSnapshotUpload({
    required this.bytes,
    required this.contentType,
    required this.format,
    required this.height,
    required this.metadata,
    required this.screenName,
    required this.sessionContext,
    required this.sessionId,
    required this.sessionProperties,
    required this.snapshotId,
    required this.timestamp,
    required this.userProperties,
    required this.width,
    this.filename,
    this.userId,
  });

  final List<int> bytes;
  final String contentType;
  final String? filename;
  final String format;
  final int height;
  final Map<String, Object?> metadata;
  final String? screenName;
  final Map<String, Object?> sessionContext;
  final String sessionId;
  final Map<String, Object?> sessionProperties;
  final String snapshotId;
  final DateTime timestamp;
  final String? userId;
  final Map<String, Object?> userProperties;
  final int width;
}

class UploadedSnapshot {
  const UploadedSnapshot({
    required this.snapshotRef,
  });

  final String snapshotRef;
}
