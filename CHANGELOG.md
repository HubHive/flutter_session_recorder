## 0.1.1

- Pauses recording immediately when the server returns `403 Forbidden`.
- Adds periodic `/recording-access-test` probing while recording is disabled.
- Automatically resumes capture and uploads after the access probe returns `200 OK`.

## 0.1.0

- Initial public release.
- Adds a global Flutter session recorder API.
- Captures hybrid Flutter keyframes, structured taps, scrolls, screen views, logs, errors, and custom events.
- Supports Android and iOS native capture bridges.
- Sends session event batches to `/sessions` and frame uploads to `/frames`.
