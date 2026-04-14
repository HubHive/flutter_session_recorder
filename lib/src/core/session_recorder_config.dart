class SessionRecorderConfig {
  const SessionRecorderConfig({
    this.captureNavigation = true,
    @Deprecated('Use captureHybridKeyframes instead.')
    this.captureScreenshots = false,
    this.captureScrolls = true,
    this.captureTaps = true,
    this.captureLogs = true,
    this.captureConsoleLogs = true,
    this.captureFlutterErrors = true,
    this.capturePlatformErrors = true,
    this.captureNativeViewHierarchy = true,
    this.captureNativeLifecycle = true,
    this.maskAllText = false,
    this.maskTextInputs = true,
    this.captureHybridKeyframes = true,
    this.captureAdaptiveHybridKeyframes = true,
    this.captureKeyframesDuringScroll = true,
    this.captureKeyframeOnResume = true,
    this.captureKeyframeOnScreenView = true,
    this.captureKeyframeOnScrollEnd = true,
    this.captureKeyframeOnTap = true,
    this.captureSnapshotOnScreenView = true,
    this.captureSnapshotOnScrollEnd = false,
    this.captureSnapshotOnTap = false,
    this.dedupeIdenticalKeyframes = true,
    this.activeHybridKeyframeInterval = const Duration(milliseconds: 150),
    this.activeHybridKeyframeWindow = const Duration(seconds: 2),
    this.hybridKeyframeInterval = const Duration(seconds: 3),
    this.hybridKeyframeMaxDimension = 720,
    this.pauseOnBackground = true,
    this.recordingAccessCheckInterval = const Duration(seconds: 30),
    this.flushInterval = const Duration(seconds: 8),
    this.backgroundSessionTimeout = const Duration(minutes: 2),
    this.maxLogLength = 4000,
    this.maxBatchSize = 30,
    this.maxSnapshotDimension = 720,
    this.minimumScrollDelta = 24,
    this.nativeViewTreeSnapshotInterval = const Duration(milliseconds: 700),
    this.screenshotInterval,
    this.scrollEventThrottle = const Duration(milliseconds: 250),
    this.scrollKeyframeThrottle = const Duration(milliseconds: 175),
    this.snapshotDebounce = const Duration(milliseconds: 800),
  });

  const SessionRecorderConfig.lightweight({
    bool captureNavigation = true,
    @Deprecated('Use captureHybridKeyframes instead.')
    bool captureScreenshots = false,
    bool captureScrolls = true,
    bool captureTaps = true,
    bool captureLogs = true,
    bool captureConsoleLogs = true,
    bool captureFlutterErrors = true,
    bool capturePlatformErrors = true,
    bool captureNativeViewHierarchy = true,
    bool captureNativeLifecycle = true,
    bool maskAllText = false,
    bool maskTextInputs = true,
    bool captureHybridKeyframes = true,
    bool captureAdaptiveHybridKeyframes = true,
    bool captureKeyframesDuringScroll = true,
    bool captureKeyframeOnResume = true,
    bool captureKeyframeOnScreenView = true,
    bool captureKeyframeOnScrollEnd = true,
    bool captureKeyframeOnTap = true,
    bool captureSnapshotOnScreenView = true,
    bool captureSnapshotOnScrollEnd = false,
    bool captureSnapshotOnTap = false,
    bool dedupeIdenticalKeyframes = true,
    Duration activeHybridKeyframeInterval = const Duration(milliseconds: 150),
    Duration activeHybridKeyframeWindow = const Duration(seconds: 2),
    Duration hybridKeyframeInterval = const Duration(seconds: 3),
    int hybridKeyframeMaxDimension = 720,
    bool pauseOnBackground = true,
    Duration recordingAccessCheckInterval = const Duration(seconds: 30),
    Duration flushInterval = const Duration(seconds: 8),
    Duration? backgroundSessionTimeout = const Duration(minutes: 2),
    int maxLogLength = 4000,
    int maxBatchSize = 30,
    int maxSnapshotDimension = 720,
    double minimumScrollDelta = 24,
    Duration nativeViewTreeSnapshotInterval = const Duration(milliseconds: 700),
    Duration? screenshotInterval,
    Duration scrollEventThrottle = const Duration(milliseconds: 250),
    Duration scrollKeyframeThrottle = const Duration(milliseconds: 175),
    Duration snapshotDebounce = const Duration(milliseconds: 800),
  }) : this(
          captureNavigation: captureNavigation,
          // ignore: deprecated_member_use_from_same_package
          captureScreenshots: captureScreenshots,
          captureScrolls: captureScrolls,
          captureTaps: captureTaps,
          captureLogs: captureLogs,
          captureConsoleLogs: captureConsoleLogs,
          captureFlutterErrors: captureFlutterErrors,
          capturePlatformErrors: capturePlatformErrors,
          captureNativeViewHierarchy: captureNativeViewHierarchy,
          captureNativeLifecycle: captureNativeLifecycle,
          maskAllText: maskAllText,
          maskTextInputs: maskTextInputs,
          captureHybridKeyframes: captureHybridKeyframes,
          captureAdaptiveHybridKeyframes: captureAdaptiveHybridKeyframes,
          captureKeyframesDuringScroll: captureKeyframesDuringScroll,
          captureKeyframeOnResume: captureKeyframeOnResume,
          captureKeyframeOnScreenView: captureKeyframeOnScreenView,
          captureKeyframeOnScrollEnd: captureKeyframeOnScrollEnd,
          captureKeyframeOnTap: captureKeyframeOnTap,
          captureSnapshotOnScreenView: captureSnapshotOnScreenView,
          captureSnapshotOnScrollEnd: captureSnapshotOnScrollEnd,
          captureSnapshotOnTap: captureSnapshotOnTap,
          dedupeIdenticalKeyframes: dedupeIdenticalKeyframes,
          activeHybridKeyframeInterval: activeHybridKeyframeInterval,
          activeHybridKeyframeWindow: activeHybridKeyframeWindow,
          hybridKeyframeInterval: hybridKeyframeInterval,
          hybridKeyframeMaxDimension: hybridKeyframeMaxDimension,
          pauseOnBackground: pauseOnBackground,
          recordingAccessCheckInterval: recordingAccessCheckInterval,
          flushInterval: flushInterval,
          backgroundSessionTimeout: backgroundSessionTimeout,
          maxLogLength: maxLogLength,
          maxBatchSize: maxBatchSize,
          maxSnapshotDimension: maxSnapshotDimension,
          minimumScrollDelta: minimumScrollDelta,
          nativeViewTreeSnapshotInterval: nativeViewTreeSnapshotInterval,
          screenshotInterval: screenshotInterval,
          scrollEventThrottle: scrollEventThrottle,
          scrollKeyframeThrottle: scrollKeyframeThrottle,
          snapshotDebounce: snapshotDebounce,
        );

  final bool captureNavigation;
  final bool captureScreenshots;
  final bool captureScrolls;
  final bool captureTaps;
  final bool captureLogs;
  final bool captureConsoleLogs;
  final bool captureFlutterErrors;
  final bool capturePlatformErrors;
  final bool captureNativeViewHierarchy;
  final bool captureNativeLifecycle;
  final bool maskAllText;
  final bool maskTextInputs;
  final bool captureHybridKeyframes;
  final bool captureAdaptiveHybridKeyframes;
  final bool captureKeyframesDuringScroll;
  final bool captureKeyframeOnResume;
  final bool captureKeyframeOnScreenView;
  final bool captureKeyframeOnScrollEnd;
  final bool captureKeyframeOnTap;
  final bool captureSnapshotOnScreenView;
  final bool captureSnapshotOnScrollEnd;
  final bool captureSnapshotOnTap;
  final bool dedupeIdenticalKeyframes;
  final Duration activeHybridKeyframeInterval;
  final Duration activeHybridKeyframeWindow;
  final Duration hybridKeyframeInterval;
  final int hybridKeyframeMaxDimension;
  final bool pauseOnBackground;
  final Duration recordingAccessCheckInterval;
  final Duration flushInterval;
  final Duration? backgroundSessionTimeout;
  final int maxLogLength;
  final int maxBatchSize;
  final int maxSnapshotDimension;
  final double minimumScrollDelta;
  final Duration nativeViewTreeSnapshotInterval;
  final Duration? screenshotInterval;
  final Duration scrollEventThrottle;
  final Duration scrollKeyframeThrottle;
  final Duration snapshotDebounce;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'captureNavigation': captureNavigation,
      'captureScreenshots': captureScreenshots,
      'captureScrolls': captureScrolls,
      'captureTaps': captureTaps,
      'captureLogs': captureLogs,
      'captureConsoleLogs': captureConsoleLogs,
      'captureFlutterErrors': captureFlutterErrors,
      'capturePlatformErrors': capturePlatformErrors,
      'captureNativeViewHierarchy': captureNativeViewHierarchy,
      'captureNativeLifecycle': captureNativeLifecycle,
      'maskAllText': maskAllText,
      'maskTextInputs': maskTextInputs,
      'captureHybridKeyframes': captureHybridKeyframes,
      'captureAdaptiveHybridKeyframes': captureAdaptiveHybridKeyframes,
      'captureKeyframesDuringScroll': captureKeyframesDuringScroll,
      'captureKeyframeOnResume': captureKeyframeOnResume,
      'captureKeyframeOnScreenView': captureKeyframeOnScreenView,
      'captureKeyframeOnScrollEnd': captureKeyframeOnScrollEnd,
      'captureKeyframeOnTap': captureKeyframeOnTap,
      'captureSnapshotOnScreenView': captureSnapshotOnScreenView,
      'captureSnapshotOnScrollEnd': captureSnapshotOnScrollEnd,
      'captureSnapshotOnTap': captureSnapshotOnTap,
      'dedupeIdenticalKeyframes': dedupeIdenticalKeyframes,
      'activeHybridKeyframeIntervalMs':
          activeHybridKeyframeInterval.inMilliseconds,
      'activeHybridKeyframeWindowMs': activeHybridKeyframeWindow.inMilliseconds,
      'hybridKeyframeIntervalMs': hybridKeyframeInterval.inMilliseconds,
      'hybridKeyframeMaxDimension': hybridKeyframeMaxDimension,
      'pauseOnBackground': pauseOnBackground,
      'recordingAccessCheckIntervalMs':
          recordingAccessCheckInterval.inMilliseconds,
      'flushIntervalMs': flushInterval.inMilliseconds,
      'backgroundSessionTimeoutMs': backgroundSessionTimeout?.inMilliseconds,
      'maxLogLength': maxLogLength,
      'maxBatchSize': maxBatchSize,
      'maxSnapshotDimension': maxSnapshotDimension,
      'minimumScrollDelta': minimumScrollDelta,
      'nativeViewTreeSnapshotIntervalMs':
          nativeViewTreeSnapshotInterval.inMilliseconds,
      'screenshotIntervalMs': screenshotInterval?.inMilliseconds,
      'scrollEventThrottleMs': scrollEventThrottle.inMilliseconds,
      'scrollKeyframeThrottleMs': scrollKeyframeThrottle.inMilliseconds,
      'snapshotDebounceMs': snapshotDebounce.inMilliseconds,
    };
  }
}
