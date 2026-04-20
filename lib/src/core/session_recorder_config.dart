class SessionRecorderConfig {
  const SessionRecorderConfig({
    this.captureNavigation = true,
    this.captureScrolls = true,
    this.captureTaps = true,
    this.captureLogs = true,
    this.captureConsoleLogs = true,
    this.captureFlutterErrors = true,
    this.capturePlatformErrors = true,
    this.captureNativeLifecycle = true,
    this.pauseOnBackground = true,
    this.recordingAccessCheckInterval = const Duration(seconds: 30),
    this.flushInterval = const Duration(seconds: 8),
    this.backgroundSessionTimeout = const Duration(minutes: 2),
    this.maxLogLength = 4000,
    this.maxBatchSize = 30,
    this.minimumScrollDelta = 24,
    this.maxSnapshotUploadBatchBytes = 4 * 1024 * 1024,
    this.maxSnapshotUploadBatchSize = 10,
    this.nativeSnapshotInterval = const Duration(milliseconds: 500),
    this.nativeSnapshotJpegQuality = 0.65,
    this.nativeSnapshotMaxDimension = 720,
    this.recordingDomain,
    this.snapshotUploadFlushInterval = const Duration(seconds: 5),
    this.scrollEventThrottle = const Duration(milliseconds: 250),
  });

  const SessionRecorderConfig.lightweight({
    bool captureNavigation = true,
    bool captureScrolls = true,
    bool captureTaps = true,
    bool captureLogs = true,
    bool captureConsoleLogs = true,
    bool captureFlutterErrors = true,
    bool capturePlatformErrors = true,
    bool captureNativeLifecycle = true,
    bool pauseOnBackground = true,
    Duration recordingAccessCheckInterval = const Duration(seconds: 30),
    Duration flushInterval = const Duration(seconds: 8),
    Duration? backgroundSessionTimeout = const Duration(minutes: 2),
    int maxLogLength = 4000,
    int maxBatchSize = 30,
    double minimumScrollDelta = 24,
    int maxSnapshotUploadBatchBytes = 4 * 1024 * 1024,
    int maxSnapshotUploadBatchSize = 10,
    Duration nativeSnapshotInterval = const Duration(milliseconds: 500),
    double nativeSnapshotJpegQuality = 0.65,
    int nativeSnapshotMaxDimension = 720,
    String? recordingDomain,
    Duration snapshotUploadFlushInterval = const Duration(seconds: 5),
    Duration scrollEventThrottle = const Duration(milliseconds: 250),
  }) : this(
          captureNavigation: captureNavigation,
          captureScrolls: captureScrolls,
          captureTaps: captureTaps,
          captureLogs: captureLogs,
          captureConsoleLogs: captureConsoleLogs,
          captureFlutterErrors: captureFlutterErrors,
          capturePlatformErrors: capturePlatformErrors,
          captureNativeLifecycle: captureNativeLifecycle,
          pauseOnBackground: pauseOnBackground,
          recordingAccessCheckInterval: recordingAccessCheckInterval,
          flushInterval: flushInterval,
          backgroundSessionTimeout: backgroundSessionTimeout,
          maxLogLength: maxLogLength,
          maxBatchSize: maxBatchSize,
          minimumScrollDelta: minimumScrollDelta,
          maxSnapshotUploadBatchBytes: maxSnapshotUploadBatchBytes,
          maxSnapshotUploadBatchSize: maxSnapshotUploadBatchSize,
          nativeSnapshotInterval: nativeSnapshotInterval,
          nativeSnapshotJpegQuality: nativeSnapshotJpegQuality,
          nativeSnapshotMaxDimension: nativeSnapshotMaxDimension,
          recordingDomain: recordingDomain,
          snapshotUploadFlushInterval: snapshotUploadFlushInterval,
          scrollEventThrottle: scrollEventThrottle,
        );

  final bool captureNavigation;
  final bool captureScrolls;
  final bool captureTaps;
  final bool captureLogs;
  final bool captureConsoleLogs;
  final bool captureFlutterErrors;
  final bool capturePlatformErrors;
  final bool captureNativeLifecycle;
  final bool pauseOnBackground;
  final Duration recordingAccessCheckInterval;
  final Duration flushInterval;
  final Duration? backgroundSessionTimeout;
  final int maxLogLength;
  final int maxBatchSize;
  final double minimumScrollDelta;
  final int maxSnapshotUploadBatchBytes;
  final int maxSnapshotUploadBatchSize;
  final Duration nativeSnapshotInterval;
  final double nativeSnapshotJpegQuality;
  final int nativeSnapshotMaxDimension;
  final String? recordingDomain;
  final Duration snapshotUploadFlushInterval;
  final Duration scrollEventThrottle;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'captureNavigation': captureNavigation,
      'captureScrolls': captureScrolls,
      'captureTaps': captureTaps,
      'captureLogs': captureLogs,
      'captureConsoleLogs': captureConsoleLogs,
      'captureFlutterErrors': captureFlutterErrors,
      'capturePlatformErrors': capturePlatformErrors,
      'captureNativeLifecycle': captureNativeLifecycle,
      'pauseOnBackground': pauseOnBackground,
      'recordingAccessCheckIntervalMs':
          recordingAccessCheckInterval.inMilliseconds,
      'flushIntervalMs': flushInterval.inMilliseconds,
      'backgroundSessionTimeoutMs': backgroundSessionTimeout?.inMilliseconds,
      'maxLogLength': maxLogLength,
      'maxBatchSize': maxBatchSize,
      'minimumScrollDelta': minimumScrollDelta,
      'maxSnapshotUploadBatchBytes': maxSnapshotUploadBatchBytes,
      'maxSnapshotUploadBatchSize': maxSnapshotUploadBatchSize,
      'nativeSnapshotIntervalMs': nativeSnapshotInterval.inMilliseconds,
      'nativeSnapshotJpegQuality': nativeSnapshotJpegQuality,
      'nativeSnapshotMaxDimension': nativeSnapshotMaxDimension,
      'recordingDomain': recordingDomain,
      'snapshotUploadFlushIntervalMs':
          snapshotUploadFlushInterval.inMilliseconds,
      'scrollEventThrottleMs': scrollEventThrottle.inMilliseconds,
    };
  }
}
