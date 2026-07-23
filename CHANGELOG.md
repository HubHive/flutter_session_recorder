## 2.1.0

- Detects force-quits (true crashes). The recorder persists a small liveness "crash sentinel" across launches (via `shared_preferences`) and tracks foreground/background lifecycle transitions independently of the `pauseOnBackground` capture policy. When a launch finds the previous run died while foregrounded, it emits an `app.force_quit` event on the new session naming the dead session (`crashedSessionId`). A death last seen backgrounded (the OS reclaiming memory) is not counted as a crash, and a graceful `stop()` clears the sentinel. Adds `SessionRecorder.noteForegrounded()` / `noteBackgrounded()` and exports `CrashSentinel`.
- **New dependency:** `shared_preferences: ^2.2.0`, used to persist the crash sentinel across launches.
- Fixes tap/interaction markers being drawn in the wrong location in the replay viewer. Snapshots are captured in physical pixels (`boundarySize * pixelRatio`, clamped by `nativeSnapshotMaxDimension`) while taps are recorded in logical pixels, so the viewer was scaling markers against the wrong coordinate space — pushing them off toward the edges. The Flutter capture now ships `logicalWidth` / `logicalHeight` in each snapshot's metadata so the viewer can place interaction markers correctly.

## 2.0.0

- **Breaking:** `SessionRecorderTransport.checkRecordingAccess()` now takes an optional `{String? recordingDomain}`. Direct callers and the built-in `HttpSessionRecorderTransport`/`NoopSessionRecorderTransport`/`DebugPrintSessionRecorderTransport` are unaffected, but any custom `SessionRecorderTransport` implementation must update its override signature to `checkRecordingAccess({String? recordingDomain})`.
- Fixes the recorder not pausing when the server rejects uploads for a disallowed recording domain. Pause-on-rejection only ever fired on an HTTP 403, but the server returned a silent success for a disallowed recording domain, so the client kept recording while every snapshot was discarded. Paired with the server change that now returns 403 for a disallowed domain, the recorder again pauses recording and uploads, probes `/recording-access-test` on `recordingAccessCheckInterval`, and resumes (clearing the stale snapshot backlog and starting a fresh session) once access is restored.
- The access probe now sends the configured `recordingDomain` via the `X-Recorder-Domain` header so the server can re-gate on the recording-domain allowlist, not just the IP block. Without this a domain-paused client would flap — pausing on upload, then immediately resuming against a domain-blind probe. IP-only deployments send no domain and are unaffected.
- Adds a leveled log facade: `recorder.log.debug(...)` / `.info(...)` / `.warn(...)` / `.error(...)` emit a `log` event at a typed `LogLevel`. Calling `recorder.log(message, level: '…')` with a string level still works but is deprecated.

## 1.2.0

- Reports the host application's version and build number with every session. The native bridges now read `CFBundleShortVersionString` / `CFBundleVersion` on iOS and `PackageInfo.versionName` / version code on Android (API-aware: `longVersionCode` on API 28+), and the recorder lifts them to top-level `sessionContext.appVersion` / `sessionContext.appBuildNumber` — app-level fields rather than nested under `device`. No new package dependency: the values come from the existing native device-context channel. Empty values are omitted so a missing version never appears as a blank attribute. Servers can now filter and group replays by the exact version a session was recorded against.

## 1.1.2

- Fixes snapshot uploads growing without bound on flaky networks. The flush sent the *entire* pending queue (the batch size/bytes limits only decided *when* to flush, not how much to send) and failed batches were re-queued at the front, so a sustained upload failure snowballed — fail, re-queue everything, new snapshots arrive, next request is larger, fail again — until the request body reached multiple GB and the server reset the connection mid-upload (surfacing on Android as `ClientException with SocketException: Connection reset by peer, errno 104`). Each flush now sends at most `maxSnapshotUploadBatchSize` / `maxSnapshotUploadBatchBytes` and leaves the rest queued, so a single request can never exceed the configured batch limit (a lone oversized snapshot is still sent on its own so the queue can drain).
- Adds `maxPendingSnapshotUploadBytes` (default 16MB) — a hard ceiling on the unsent backlog. When exceeded, the oldest pending snapshots are dropped so a network outage cannot accumulate gigabytes of queued uploads.
- Lowers the default snapshot upload batch to 2MB / 5 snapshots (was 4MB / 10) to keep request bodies comfortably under typical proxy body-size limits.

## 1.1.1

- Fixes Flutter-side snapshot capture being completely broken in release and profile builds. The capture path read `RenderObject.debugNeedsPaint`, which is only initialized when asserts are enabled, so every snapshot tick threw `LateInitializationError: Local 'result' has not been initialized` and the frame was dropped — release builds with `useFlutterCapture: true` (the 1.1.0 default) never uploaded any Flutter-rendered snapshots. The needs-paint guard now reads the debug getter inside an assert closure and falls back to a release-safe never-painted check.
- Adds a source-level regression test that forbids reading debug-only framework members outside assert closures anywhere in `lib/`, since `flutter test` always enables asserts and cannot catch this class of bug directly.

## 1.1.0

- Adds a Flutter-driven snapshot capture pipeline (default `useFlutterCapture: true`) that renders via `RenderRepaintBoundary.toImage` on the Flutter raster thread. Eliminates the iOS UIKit main-thread `drawHierarchy` cost (~35ms per snapshot measured on iPhone 17 ProMotion), which had been causing visible jitter during slow scrolls on 120Hz displays. Output format changes from JPEG to PNG.
- Embedded native widgets (`AndroidView`, `UiKitView`, `HtmlElementView`, `PlatformViewLink`) are walked from the Dart widget tree before each snapshot and rendered as labeled placeholder rects ("Map", "Web view", "Video", "Camera", etc. for known plugin viewTypes; raw `viewType` otherwise). Structured rect data is included on the snapshot's `metadata.platformViews`.
- Adds iOS system modal detection via swizzling of `UIViewController.present(_:animated:completion:)` and `dismiss(animated:completion:)`. When a system modal (share sheet, photo picker, alert, Apple Pay, mail composer, etc.) is presented over the Flutter view, the recorder substitutes a labeled full-screen placeholder image and emits `native.system_modal.opened` / `native.system_modal.closed` events with the presented VC's class name and a friendly label.
- Adds an iOS keyboard overlay: when `MediaQuery.viewInsets.bottom > 0`, a labeled "Keyboard" rect is painted over the bottom portion of the captured image so replay viewers can see the occlusion clearly. Captured image dimensions remain stable across keyboard-up/down transitions.
- Adds the missing iOS pan event time throttle on the gesture recognizer attached to the key window. The `scrollEventThrottleMs` config field is now honored on iOS, matching the Android plugin. Slow finger drags on ProMotion devices no longer flood the platform channel with redundant scroll events.
- Hosts can opt back to the legacy native `UIWindow.drawHierarchy` capture with `SessionRecorderConfig(useFlutterCapture: false)` for full pixel fidelity of platform views and system modals, at the cost of the main-thread snapshot block.

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
