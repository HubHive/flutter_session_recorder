# flutter_session_recorder

A Flutter session replay SDK built around a hybrid capture model:

- one global Dart entrypoint through `recorder`
- structured interaction, screen, log, error, and native replay events
- Flutter root keyframes uploaded as separate frame assets
- session/user APIs that do not require passing recorder instances around

## Architecture

For Flutter apps, the primary visual truth source is a hybrid keyframe pipeline:

- Flutter root keyframes are captured from a single recorder-owned boundary
- keyframes are uploaded separately from event batches
- event batches only carry `replay.keyframe` metadata plus the `frameRef`
- structured events still drive the replay timeline between keyframes

Structured events include:

- `screen.view`
- `interaction.tap`
- `interaction.scroll`
- `replay.frame` for native view-tree metadata when enabled
- `log`
- `error`
- `custom`

This lets a viewer render the latest uploaded keyframe and overlay touches, scrolls, logs, errors, and custom events until the next keyframe arrives.

## Quick start

Initialize once:

```dart
await recorder.initialize(
  config: const SessionRecorderConfig.lightweight(
    captureHybridKeyframes: true,
    hybridKeyframeInterval: Duration(seconds: 3),
    captureNativeViewHierarchy: true,
    nativeViewTreeSnapshotInterval: Duration(milliseconds: 700),
  ),
  transport: HttpSessionRecorderTransport(
    endpoint: Uri.parse('https://your-recorder.example.com'),
    apiKey: 'demo-key',
  ),
  sessionProperties: {'environment': 'production'},
);
```

Hook into the app once:

```dart
MaterialApp(
  navigatorObservers: recorder.navigatorObservers(),
  builder: recorder.appBuilder(),
);
```

You can also let the recorder bootstrap the app root directly:

```dart
await recorder.runApp(
  const MyApp(),
  transport: HttpSessionRecorderTransport(
    endpoint: Uri.parse('https://your-recorder.example.com'),
  ),
);
```

`recorder.runApp(...)` calls Flutter's `runApp(...)` in the current zone so it stays compatible with apps that call `WidgetsFlutterBinding.ensureInitialized()` during bootstrap. The recorder captures `debugPrint`, Flutter errors, platform errors, and explicit `recorder.log(...)` calls. Raw `print()` interception should be handled by an app-owned zone before binding initialization if you need it.

## Keyframes

Hybrid keyframes are enabled by default in `SessionRecorderConfig.lightweight()` and are captured on:

- screen view
- tap
- throttled scroll updates during active scrolling
- scroll end
- app resume
- a fallback interval, default `3s`
- a faster adaptive burst during motion, default `150ms` for `2s`

Relevant config:

```dart
const SessionRecorderConfig.lightweight(
  captureHybridKeyframes: true,
  captureAdaptiveHybridKeyframes: true,
  captureKeyframesDuringScroll: true,
  captureKeyframeOnScreenView: true,
  captureKeyframeOnTap: true,
  captureKeyframeOnScrollEnd: true,
  captureKeyframeOnResume: true,
  activeHybridKeyframeInterval: Duration(milliseconds: 150),
  activeHybridKeyframeWindow: Duration(seconds: 2),
  hybridKeyframeInterval: Duration(seconds: 3),
  hybridKeyframeMaxDimension: 720,
  scrollKeyframeThrottle: Duration(milliseconds: 175),
  dedupeIdenticalKeyframes: true,
)
```

Each uploaded keyframe produces a `replay.keyframe` event with:

- `frameRef`
- `reason`
- `screenName`
- `viewport`
- `metadata`

## Identity

Set the active user when you know who it is:

```dart
await recorder.setUser(
  'user-123',
  userProperties: {'email': 'user@example.com'},
);
```

Update user metadata without replacing the user:

```dart
recorder.setUserProperties({'plan': 'pro'});
```

Clear the active user on logout:

```dart
await recorder.clearUser();
```

If the active user changes from one identified user to another, the recorder starts a new session automatically.

## Custom data and diagnostics

Record custom events from any file:

```dart
recorder.recordEvent(
  'checkout_started',
  properties: {'cartValue': 149.99, 'currency': 'USD'},
);
```

Capture logs and errors:

```dart
recorder.log(
  'validation failed',
  level: 'warning',
  logger: 'checkout',
);

recorder.error(
  StateError('Missing cart id'),
  logger: 'checkout',
);
```

## Replay documents

The current session can be assembled into a replay document:

```dart
final ReplayDocument? replay = recorder.replayDocument;
```

`ReplayDocument` includes:

- `frames`
- `keyframes`
- `screenViews`
- `interactions`
- `logs`
- `errors`
- `customEvents`

## Session context

Each session batch carries `sessionContext` with best-effort device metadata, including:

- device type
- device model
- OS name and version

The SDK intentionally does not collect or send IP addresses. Capture client IP on your ingestion server from the incoming request, since that is the reliable place to record the IP seen by your backend.

## Background behavior

By default the recorder pauses when the app backgrounds and resumes when it returns:

```dart
const SessionRecorderConfig.lightweight(
  pauseOnBackground: true,
  backgroundSessionTimeout: Duration(minutes: 2),
)
```

- short background gap: same session resumes
- long background gap: old session closes and a new one starts on resume

## Recording access control

If the server returns `403 Forbidden` from either `/sessions` or `/frames`, the recorder immediately enters access-denied mode:

- native and Flutter keyframe capture are paused
- buffered recording data is dropped
- normal uploads to `/sessions` and `/frames` stop
- the SDK only probes `/recording-access-test`

When `/recording-access-test` returns `200 OK`, capture resumes automatically. A `403` from the access test keeps recording disabled.

The default probe interval is 30 seconds:

```dart
const SessionRecorderConfig.lightweight(
  recordingAccessCheckInterval: Duration(seconds: 30),
)
```

## Transport contract

`SessionRecorderTransport` supports two independent delivery paths:

- `send(SessionBatch batch)` for JSON event batches
- `uploadKeyframe(SessionKeyframeUpload upload)` for binary frame uploads
- `checkRecordingAccess()` for access recovery checks

The default HTTP transport accepts the recorder service root as `endpoint`, posts event batches to `/sessions`, posts keyframes to `/frames`, and probes recording access at `/recording-access-test`.

## License

This package is licensed under the Apache License, Version 2.0.

The software is provided on an "AS IS" basis without warranties or conditions of any kind, and the license includes a limitation of liability for contributors. That said, this package records session data, so apps that use it are responsible for their own user consent, privacy notices, data retention, sensitive-data handling, and legal/compliance review before shipping it to end users.
