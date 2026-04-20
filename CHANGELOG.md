## 0.1.1

- Pauses recording immediately when the server returns `403 Forbidden`.
- Adds periodic `/recording-access-test` probing while recording is disabled.
- Automatically resumes capture and uploads after the access probe returns `200 OK`.
- Makes native snapshots the only visual replay mode.
- Adds iOS no-permission `UIWindow` snapshot capture that uploads JPEG snapshots to `/snapshots` and emits `replay.snapshot` references.
- Batches native snapshot uploads by count, byte size, or flush interval to reduce request volume.
- Removes automatic schematic frame, screenshot keyframe, and replay asset uploads.
- Removes legacy visual upload routes from the default transport contract.
- Keeps structured metadata events for screen views, taps, scrolls, lifecycle, logs, errors, and custom events.

## 0.1.0

- Initial public release.
- Adds a global Flutter session recorder API.
- Captures structured taps, scrolls, screen views, logs, errors, and custom events.
- Supports Android and iOS native capture bridges.
- Sends session event batches to `/sessions`.
