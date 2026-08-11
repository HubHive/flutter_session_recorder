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
    this.maxSnapshotUploadBatchBytes = 2 * 1024 * 1024,
    this.maxSnapshotUploadBatchSize = 5,
    // Hard ceiling on the unsent snapshot backlog. During a network outage
    // failed batches are re-queued and new snapshots keep arriving; without a
    // ceiling the pending queue (and therefore the next request body) can grow
    // without bound. When exceeded, the oldest pending snapshots are dropped.
    this.maxPendingSnapshotUploadBytes = 16 * 1024 * 1024,
    // Hard ceiling on unsent EVENTS. Same reasoning as the snapshot backlog
    // above, which had a ceiling while the event buffer did not: during an
    // outage failed batches are re-queued (`_buffer.insertAll(0, ...)`) while
    // new events keep arriving, so the buffer grew without bound.
    // `maxBatchSize` only triggers a flush; it never capped the list. Oldest
    // events are dropped first.
    this.maxBufferedEvents = 500,
    // Hard ceiling on the retained session history. This list is only read by
    // `buildReplayDocument()`, but it was appended to for every event and never
    // trimmed during a live session, so a long-running app retained every event
    // (each holding its message and stack-trace strings) for the whole process.
    this.maxSessionHistoryEvents = 1000,
    // Circuit breaker. After this many CONSECUTIVE transport failures the
    // recorder stops uploading and stops capturing until the backoff expires.
    // Without it, an unreachable endpoint is retried forever, and because each
    // failure is itself reported as an error (which the error hook turns back
    // into an event) the retry path generates the very work it is retrying.
    this.maxConsecutiveTransportFailures = 5,
    // Backoff applied when the breaker opens, doubling per streak up to
    // [maxTransportFailureBackoff]. A probe upload is allowed after it expires.
    this.transportFailureBackoff = const Duration(seconds: 30),
    this.maxTransportFailureBackoff = const Duration(minutes: 15),
    // 1Hz capture keeps a useful replay timeline while halving how often the
    // iOS UIWindow snapshot pipeline blocks the main thread. Hosts that want
    // higher fidelity can pass a shorter interval explicitly.
    this.nativeSnapshotInterval = const Duration(milliseconds: 1000),
    this.nativeSnapshotJpegQuality = 0.65,
    this.nativeSnapshotMaxDimension = 720,
    this.recordingDomain,
    this.snapshotUploadFlushInterval = const Duration(seconds: 5),
    this.scrollEventThrottle = const Duration(milliseconds: 250),
    // When true (default), snapshots are captured Dart-side via
    // RenderRepaintBoundary.toImage on the Flutter raster thread, avoiding
    // the iOS main-thread GPU-readback cost of UIWindow.drawHierarchy.
    // Trade-off: embedded native widgets (PlatformViews like maps/webviews)
    // are captured as labeled placeholder rects, and OS-level modals
    // presented over the Flutter view (photo picker, share sheet, etc.) are
    // captured as labeled placeholder images. Set to false to fall back to
    // the legacy native UIWindow drawHierarchy capture, which preserves
    // full visual fidelity at the cost of main-thread jitter on ProMotion
    // displays during scrolling.
    this.useFlutterCapture = true,
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
    int maxSnapshotUploadBatchBytes = 2 * 1024 * 1024,
    int maxSnapshotUploadBatchSize = 5,
    int maxPendingSnapshotUploadBytes = 16 * 1024 * 1024,
    int maxBufferedEvents = 500,
    int maxSessionHistoryEvents = 1000,
    int maxConsecutiveTransportFailures = 5,
    Duration transportFailureBackoff = const Duration(seconds: 30),
    Duration maxTransportFailureBackoff = const Duration(minutes: 15),
    Duration nativeSnapshotInterval = const Duration(milliseconds: 1000),
    double nativeSnapshotJpegQuality = 0.65,
    int nativeSnapshotMaxDimension = 720,
    String? recordingDomain,
    Duration snapshotUploadFlushInterval = const Duration(seconds: 5),
    Duration scrollEventThrottle = const Duration(milliseconds: 250),
    bool useFlutterCapture = true,
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
          maxPendingSnapshotUploadBytes: maxPendingSnapshotUploadBytes,
          maxBufferedEvents: maxBufferedEvents,
          maxSessionHistoryEvents: maxSessionHistoryEvents,
          maxConsecutiveTransportFailures: maxConsecutiveTransportFailures,
          transportFailureBackoff: transportFailureBackoff,
          maxTransportFailureBackoff: maxTransportFailureBackoff,
          nativeSnapshotInterval: nativeSnapshotInterval,
          nativeSnapshotJpegQuality: nativeSnapshotJpegQuality,
          nativeSnapshotMaxDimension: nativeSnapshotMaxDimension,
          recordingDomain: recordingDomain,
          snapshotUploadFlushInterval: snapshotUploadFlushInterval,
          scrollEventThrottle: scrollEventThrottle,
          useFlutterCapture: useFlutterCapture,
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
  final int maxPendingSnapshotUploadBytes;
  final int maxBufferedEvents;
  final int maxSessionHistoryEvents;
  final int maxConsecutiveTransportFailures;
  final Duration transportFailureBackoff;
  final Duration maxTransportFailureBackoff;
  final Duration nativeSnapshotInterval;
  final double nativeSnapshotJpegQuality;
  final int nativeSnapshotMaxDimension;
  final String? recordingDomain;
  final Duration snapshotUploadFlushInterval;
  final Duration scrollEventThrottle;
  final bool useFlutterCapture;

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
      'maxPendingSnapshotUploadBytes': maxPendingSnapshotUploadBytes,
      'nativeSnapshotIntervalMs': nativeSnapshotInterval.inMilliseconds,
      'nativeSnapshotJpegQuality': nativeSnapshotJpegQuality,
      'nativeSnapshotMaxDimension': nativeSnapshotMaxDimension,
      'recordingDomain': recordingDomain,
      'snapshotUploadFlushIntervalMs':
          snapshotUploadFlushInterval.inMilliseconds,
      'scrollEventThrottleMs': scrollEventThrottle.inMilliseconds,
      'useFlutterCapture': useFlutterCapture,
      'maxBufferedEvents': maxBufferedEvents,
      'maxSessionHistoryEvents': maxSessionHistoryEvents,
      'maxConsecutiveTransportFailures': maxConsecutiveTransportFailures,
      'transportFailureBackoffMs': transportFailureBackoff.inMilliseconds,
      'maxTransportFailureBackoffMs': maxTransportFailureBackoff.inMilliseconds,
    };
  }
}
