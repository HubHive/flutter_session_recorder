# flutter_session_recorder

A Flutter session replay SDK built around a single visual mode: native visual snapshots plus structured metadata.

- one global Dart entrypoint through `recorder`
- native snapshots uploaded to `/snapshots`
- structured screen, tap, scroll, lifecycle, log, error, and custom events
- session/user APIs that do not require passing recorder instances around
- no schematic reconstruction, screen-recording permission prompts, video encoding, or replay asset uploads

## Architecture

The visual truth source is native snapshot capture. The SDK uploads compressed snapshots separately from JSON session batches. The event timeline stores `replay.snapshot` references plus metadata, then overlays structured events during playback.

Structured events include:

- `screen.view`
- `interaction.tap`
- `interaction.scroll`
- `native.lifecycle`
- `replay.snapshot`
- `log`
- `error`
- `custom`

The viewer should show the latest snapshot as the primary visual layer until the next snapshot arrives, then overlay taps, scroll markers, logs, errors, custom events, and screen transitions on top.

## Quick start

```dart
await recorder.runApp(
  const MyApp(),
  config: const SessionRecorderConfig.lightweight(
    nativeSnapshotInterval: Duration(milliseconds: 500),
    nativeSnapshotJpegQuality: 0.65,
    nativeSnapshotMaxDimension: 720,
    maxSnapshotUploadBatchSize: 10,
    snapshotUploadFlushInterval: Duration(seconds: 5),
    recordingDomain: 'your-app.example.com',
  ),
  transport: HttpSessionRecorderTransport(
    endpoint: Uri.parse('https://your-recorder.example.com'),
    apiKey: 'demo-key',
  ),
  sessionProperties: {'environment': 'production'},
);
```

Hook navigation once if you use `MaterialApp` routes:

```dart
MaterialApp(
  navigatorObservers: recorder.navigatorObservers(),
  builder: recorder.appBuilder(),
);
```

`recorder.runApp(...)` wraps the app with metadata capture automatically. It records screen views, taps, scrolls, logs, Flutter errors, platform errors, and explicit `recorder.log(...)` calls. Raw `print()` interception should be handled by an app-owned zone before binding initialization if you need it.

## Snapshot Uploads

Native snapshot capture is the only visual mode. On iOS this snapshots the visible key `UIWindow` with `drawHierarchy(in:afterScreenUpdates:)`, falls back to `layer.render(in:)` when needed, uploads compressed JPEG snapshots to `/snapshots`, and then sends lightweight `replay.snapshot` timeline events that reference the uploaded snapshot.

On Android, the plugin prefers the Flutter render surface instead of a generic view-tree draw. It captures visible Flutter `SurfaceView` content with `PixelCopy` on API 26+, captures Flutter `TextureView` content with `TextureView.getBitmap(...)`, and only then falls back to active-window `PixelCopy` or decor-view drawing. This keeps the public API permission-free while avoiding the black snapshot problem caused by drawing GPU-backed Flutter surfaces as ordinary Android views.

This avoids screen-recording permission prompts and avoids continuous media encoding on-device. The tradeoff is that snapshots are periodic still images, not a true OS-level video stream.

Snapshots are batched before upload to reduce server request volume. By default the SDK uploads up to 10 snapshots per `/snapshots` request, or flushes the pending snapshot batch every 5 seconds. A public `recorder.flush()` also flushes pending snapshots before sending the JSON event batch.

For one-snapshot uploads, the server should accept multipart `POST /snapshots` with file field `snapshot` and return a JSON `snapshotRef` or `id`. For batched uploads, the SDK sends:

- multipart files named `snapshot_0`, `snapshot_1`, etc.
- a `snapshots` JSON manifest field that includes each snapshot's metadata and matching `fileField`

The server should return either `{"snapshots":[{"snapshotId":"...","snapshotRef":"..."}]}` or `{"snapshotRefs":{"snapshot-id":"snapshot-ref"}}`. The session batch then contains `replay.snapshot` events with:

- `snapshotRef`
- `snapshotId`
- `format`
- `width`
- `height`
- `screenName`
- `metadata`
- `sessionContext`
- `sessionProperties`
- `userId`
- `userProperties`

The same session and user metadata is also included on the multipart `/snapshots` upload so the server can associate snapshot blobs without waiting for or joining against a later `/sessions` batch.

Android and iOS both emit the same `replay.snapshot.ready` native event shape, so the Dart upload/batching path is shared across platforms. Internal native capture status logs are not printed by default; only capture failures are recorded as structured `error` events.

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

## Custom Data And Diagnostics

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

## Replay Documents

The current session can be assembled into a replay document:

```dart
final ReplayDocument? replay = recorder.replayDocument;
```

`ReplayDocument` includes:

- `snapshots`
- `screenViews`
- `interactions`
- `logs`
- `errors`
- `customEvents`

## Session Context

Each session batch carries `sessionContext` with best-effort device metadata, including:

- device type
- device model
- OS name and version
- recording domain

Set `recordingDomain` in `SessionRecorderConfig.lightweight(...)` so the server can build its `RequestContext.RecordingDomain` from the session metadata. The SDK intentionally does not collect or send IP addresses or User-Agent values. Capture those on your ingestion server from the incoming request, since that is the reliable place to record the client IP and request User-Agent seen by your backend.

## Background Behavior

By default the recorder pauses when the app backgrounds and resumes when it returns:

```dart
const SessionRecorderConfig.lightweight(
  pauseOnBackground: true,
  backgroundSessionTimeout: Duration(minutes: 2),
)
```

If the app resumes before `backgroundSessionTimeout`, the same session continues. If it resumes after the timeout, the old session is stopped and a new session starts.

## Recording Access Control

If the server returns `403 Forbidden` from `/sessions` or `/snapshots`, the recorder immediately enters access-denied mode:

- native capture is paused
- buffered recording data is dropped
- normal uploads to `/sessions` and `/snapshots` stop
- the SDK only probes `/recording-access-test`

When `/recording-access-test` returns `200 OK`, capture resumes automatically. A `403` from the access test keeps recording disabled.

## Transport Contract

`SessionRecorderTransport` supports three delivery paths:

- `send(SessionBatch batch)` for JSON event batches
- `uploadSnapshots(List<SessionSnapshotUpload> uploads)` for batched native visual snapshots
- `uploadSnapshot(SessionSnapshotUpload upload)` as a compatibility wrapper for one native visual snapshot
- `checkRecordingAccess()` for access recovery checks

The default HTTP transport accepts the recorder service root as `endpoint`, posts event batches to `/sessions`, uploads native snapshot batches to `/snapshots`, and probes recording access at `/recording-access-test`.

## License

This package is licensed under the Apache License, Version 2.0.

The software is provided on an "AS IS" basis without warranties or conditions of any kind, and the license includes a limitation of liability for contributors. That said, this package records session data, so apps that use it are responsible for their own user consent, privacy notices, data retention, sensitive-data handling, and legal/compliance review before shipping it to end users.
