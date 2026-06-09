## 1.0.2
- Updated podspec

## 1.0.1

- Fixes scroll jitter on ProMotion (120Hz) iPhones caused by per-snapshot main-thread work.
- Moves iOS JPEG encoding off the main thread. `UIWindow.drawHierarchy(...)` still runs on the main thread (required by UIKit), but the subsequent `jpegData(compressionQuality:)` encode now dispatches to a background queue, cutting per-spike main-thread cost by roughly 30-50% (measured ~44% on iPhone XR).
- Changes default `nativeSnapshotInterval` from 500ms to 1000ms in both `SessionRecorderConfig()` and `SessionRecorderConfig.lightweight(...)`. Halves how often the main-thread snapshot spike happens; replay timelines still capture every screen view, tap, and scroll. Hosts that want higher fidelity can still pass a shorter interval explicitly.

## 1.0.0

- Makes native snapshots the only visual replay mode.
- Adds iOS no-permission `UIWindow` snapshot capture using `drawHierarchy(in:afterScreenUpdates:)` with `layer.render(in:)` fallback.
- Adds Android no-permission Flutter surface snapshots using `PixelCopy` for `SurfaceView`, `TextureView.getBitmap(...)` for `TextureView`, and window/decor-view fallbacks.
- Uploads JPEG snapshots to `/snapshots` and emits `replay.snapshot` timeline references.
- Batches native snapshot uploads by count, byte size, or flush interval to reduce request volume.
- Adds `maxSnapshotUploadBatchSize`, `maxSnapshotUploadBatchBytes`, and `snapshotUploadFlushInterval` config options.
- Extends the transport contract with `uploadSnapshots(List<SessionSnapshotUpload> uploads)` while keeping `uploadSnapshot(...)` as a single-snapshot compatibility wrapper.
- Stops sending schematic frames, screenshot keyframes, replay assets, and legacy visual upload routes.
- Keeps structured metadata events for screen views, taps, scrolls, lifecycle, logs, errors, custom events, session context, session properties, and user data.
- Keeps recording access control behavior: `403 Forbidden` pauses recording and `/recording-access-test` can resume it.
- Removes noisy internal native capture debug logging while preserving structured native capture error events.

## 0.1.1

- Pauses recording immediately when the server returns `403 Forbidden`.
- Adds periodic `/recording-access-test` probing while recording is disabled.
- Automatically resumes capture and uploads after the access probe returns `200 OK`.

## 0.1.0

- Initial public release.
- Adds a global Flutter session recorder API.
- Captures structured taps, scrolls, screen views, logs, errors, and custom events.
- Supports Android and iOS native capture bridges.
- Sends session event batches to `/sessions`.
