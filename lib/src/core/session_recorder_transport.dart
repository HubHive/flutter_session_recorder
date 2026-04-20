import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'recorder_event.dart';
import 'session_batch.dart';
import 'session_snapshot.dart';

abstract class SessionRecorderTransport {
  Future<void> send(SessionBatch batch);

  Future<UploadedSnapshot> uploadSnapshot(SessionSnapshotUpload upload) async {
    return (await uploadSnapshots(<SessionSnapshotUpload>[upload])).single;
  }

  Future<List<UploadedSnapshot>> uploadSnapshots(
    List<SessionSnapshotUpload> uploads,
  );

  Future<bool> checkRecordingAccess();
}

class NoopSessionRecorderTransport implements SessionRecorderTransport {
  const NoopSessionRecorderTransport();

  @override
  Future<void> send(SessionBatch batch) async {}

  @override
  Future<UploadedSnapshot> uploadSnapshot(SessionSnapshotUpload upload) async {
    return (await uploadSnapshots(<SessionSnapshotUpload>[upload])).single;
  }

  @override
  Future<List<UploadedSnapshot>> uploadSnapshots(
    List<SessionSnapshotUpload> uploads,
  ) async {
    return uploads
        .map(
          (SessionSnapshotUpload upload) => UploadedSnapshot(
            snapshotRef: 'noop_${upload.snapshotId}',
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<bool> checkRecordingAccess() async {
    return true;
  }
}

class DebugPrintSessionRecorderTransport implements SessionRecorderTransport {
  const DebugPrintSessionRecorderTransport();

  @override
  Future<void> send(SessionBatch batch) async {
    debugPrint(
      '[flutter_session_recorder transport] ${jsonEncode(batch.toJson())}',
    );
  }

  @override
  Future<UploadedSnapshot> uploadSnapshot(SessionSnapshotUpload upload) async {
    return (await uploadSnapshots(<SessionSnapshotUpload>[upload])).single;
  }

  @override
  Future<List<UploadedSnapshot>> uploadSnapshots(
    List<SessionSnapshotUpload> uploads,
  ) async {
    final List<UploadedSnapshot> uploadedSnapshots = uploads
        .map(
          (SessionSnapshotUpload upload) => UploadedSnapshot(
            snapshotRef: 'debug_${upload.snapshotId}',
          ),
        )
        .toList(growable: false);
    debugPrint(
      '[flutter_session_recorder transport] ${jsonEncode(<String, Object?>{
            'type': 'replay.snapshot.batch_upload',
            'count': uploads.length,
            'snapshots': <Object?>[
              for (int index = 0; index < uploads.length; index += 1)
                <String, Object?>{
                  'snapshotRef': uploadedSnapshots[index].snapshotRef,
                  'sessionId': uploads[index].sessionId,
                  'snapshotId': uploads[index].snapshotId,
                  'screenName': uploads[index].screenName,
                  'format': uploads[index].format,
                  'contentType': uploads[index].contentType,
                  'width': uploads[index].width,
                  'height': uploads[index].height,
                  'byteLength': uploads[index].bytes.length,
                  'metadata': normalizeAttributes(uploads[index].metadata),
                  'sessionContext':
                      normalizeAttributes(uploads[index].sessionContext),
                  'sessionProperties':
                      normalizeAttributes(uploads[index].sessionProperties),
                  'userId': uploads[index].userId,
                  'userProperties':
                      normalizeAttributes(uploads[index].userProperties),
                },
            ],
          })}',
    );
    return uploadedSnapshots;
  }

  @override
  Future<bool> checkRecordingAccess() async {
    debugPrint(
      '[flutter_session_recorder transport] ${jsonEncode(<String, Object?>{
            'type': 'recording_access.check',
            'allowed': true,
          })}',
    );
    return true;
  }
}

class HttpSessionRecorderTransport implements SessionRecorderTransport {
  HttpSessionRecorderTransport({
    required Uri endpoint,
    this.apiKey,
    Map<String, String> headers = const <String, String>{},
    http.Client? client,
  })  : baseEndpoint = endpoint,
        endpoint = _defaultUploadEndpoint(endpoint, 'sessions'),
        _headers = Map<String, String>.unmodifiable(headers),
        _snapshotEndpoint = _defaultUploadEndpoint(endpoint, 'snapshots'),
        _recordingAccessEndpoint =
            _defaultUploadEndpoint(endpoint, 'recording-access-test'),
        _client = client ?? http.Client();

  final String? apiKey;
  final Uri baseEndpoint;
  final Uri endpoint;
  final Uri _snapshotEndpoint;
  final Uri _recordingAccessEndpoint;
  final Map<String, String> _headers;
  final http.Client _client;

  @override
  Future<void> send(SessionBatch batch) async {
    final Map<String, String> headers = <String, String>{
      'content-type': 'application/json',
      ..._headers,
    };

    if (apiKey != null && apiKey!.isNotEmpty) {
      headers['authorization'] = 'Bearer $apiKey';
    }

    final response = await _client.post(
      endpoint,
      headers: headers,
      body: jsonEncode(batch.toJson()),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SessionRecorderTransportException(
        'Failed to upload session batch (${response.statusCode}): ${response.body}',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<UploadedSnapshot> uploadSnapshot(SessionSnapshotUpload upload) async {
    return (await uploadSnapshots(<SessionSnapshotUpload>[upload])).single;
  }

  @override
  Future<List<UploadedSnapshot>> uploadSnapshots(
    List<SessionSnapshotUpload> uploads,
  ) async {
    if (uploads.isEmpty) {
      return <UploadedSnapshot>[];
    }

    final http.MultipartRequest request = http.MultipartRequest(
      'POST',
      _snapshotEndpoint,
    );

    request.headers.addAll(_baseHeaders());

    if (uploads.length == 1) {
      final SessionSnapshotUpload upload = uploads.single;
      request.fields.addAll(<String, String>{
        'sessionId': upload.sessionId,
        'snapshotId': upload.snapshotId,
        'timestamp': upload.timestamp.toUtc().toIso8601String(),
        'screenName': upload.screenName ?? '',
        'format': upload.format,
        'contentType': upload.contentType,
        'width': upload.width.toString(),
        'height': upload.height.toString(),
        'metadata': jsonEncode(normalizeAttributes(upload.metadata)),
        'sessionContext':
            jsonEncode(normalizeAttributes(upload.sessionContext)),
        'sessionProperties':
            jsonEncode(normalizeAttributes(upload.sessionProperties)),
        'userId': upload.userId ?? '',
        'userProperties':
            jsonEncode(normalizeAttributes(upload.userProperties)),
      });
      request.files.add(
        http.MultipartFile.fromBytes(
          'snapshot',
          upload.bytes,
          filename: upload.filename ?? 'snapshot.${upload.format}',
        ),
      );
    } else {
      final List<Map<String, Object?>> manifest = <Map<String, Object?>>[];
      for (int index = 0; index < uploads.length; index += 1) {
        final SessionSnapshotUpload upload = uploads[index];
        final String fileField = 'snapshot_$index';
        manifest.add(<String, Object?>{
          'contentType': upload.contentType,
          'fileField': fileField,
          'filename': upload.filename ?? 'snapshot.${upload.format}',
          'format': upload.format,
          'height': upload.height,
          'metadata': normalizeAttributes(upload.metadata),
          'screenName': upload.screenName,
          'sessionContext': normalizeAttributes(upload.sessionContext),
          'sessionId': upload.sessionId,
          'sessionProperties': normalizeAttributes(upload.sessionProperties),
          'snapshotId': upload.snapshotId,
          'timestamp': upload.timestamp.toUtc().toIso8601String(),
          'userId': upload.userId,
          'userProperties': normalizeAttributes(upload.userProperties),
          'width': upload.width,
        });
        request.files.add(
          http.MultipartFile.fromBytes(
            fileField,
            upload.bytes,
            filename: upload.filename ?? 'snapshot.${upload.format}',
          ),
        );
      }

      request.fields['snapshots'] = jsonEncode(manifest);
    }

    final http.StreamedResponse response = await _client.send(request);
    final String responseBody = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SessionRecorderTransportException(
        'Failed to upload snapshot batch (${response.statusCode}): $responseBody',
        statusCode: response.statusCode,
      );
    }

    final Map<String, String> snapshotRefsById = <String, String>{};
    String? singleSnapshotRef;
    if (responseBody.isNotEmpty) {
      final Object? decoded = jsonDecode(responseBody);
      if (decoded is Map<Object?, Object?>) {
        singleSnapshotRef =
            decoded['snapshotRef']?.toString() ?? decoded['id']?.toString();
        final Object? snapshots = decoded['snapshots'];
        if (snapshots is List<Object?>) {
          for (final Object? snapshot in snapshots) {
            if (snapshot is Map<Object?, Object?>) {
              final String? snapshotId = snapshot['snapshotId']?.toString();
              final String? snapshotRef = snapshot['snapshotRef']?.toString() ??
                  snapshot['id']?.toString();
              if (snapshotId != null &&
                  snapshotId.isNotEmpty &&
                  snapshotRef != null &&
                  snapshotRef.isNotEmpty) {
                snapshotRefsById[snapshotId] = snapshotRef;
              }
            }
          }
        }
        final Object? snapshotRefs = decoded['snapshotRefs'];
        if (snapshotRefs is Map<Object?, Object?>) {
          snapshotRefs.forEach((Object? key, Object? value) {
            final String? snapshotId = key?.toString();
            final String? snapshotRef = value?.toString();
            if (snapshotId != null &&
                snapshotId.isNotEmpty &&
                snapshotRef != null &&
                snapshotRef.isNotEmpty) {
              snapshotRefsById[snapshotId] = snapshotRef;
            }
          });
        }
      }
    }

    singleSnapshotRef ??= response.headers['x-snapshot-ref'];

    return <UploadedSnapshot>[
      for (int index = 0; index < uploads.length; index += 1)
        UploadedSnapshot(
          snapshotRef: snapshotRefsById[uploads[index].snapshotId] ??
              (uploads.length == 1 ? singleSnapshotRef : null) ??
              uploads[index].snapshotId,
        ),
    ];
  }

  @override
  Future<bool> checkRecordingAccess() async {
    final http.Response response = await _client.get(
      _recordingAccessEndpoint,
      headers: _baseHeaders(),
    );

    if (response.statusCode == 200) {
      return true;
    }
    if (response.statusCode == 403) {
      return false;
    }

    throw SessionRecorderTransportException(
      'Failed to check recording access (${response.statusCode}): ${response.body}',
      statusCode: response.statusCode,
    );
  }

  Map<String, String> _baseHeaders() {
    final Map<String, String> headers = <String, String>{..._headers};
    if (apiKey != null && apiKey!.isNotEmpty) {
      headers['authorization'] = 'Bearer $apiKey';
    }
    return headers;
  }

  static Uri _defaultUploadEndpoint(Uri baseEndpoint, String path) {
    return Uri(
      scheme: baseEndpoint.scheme,
      userInfo: baseEndpoint.userInfo,
      host: baseEndpoint.host,
      port: baseEndpoint.hasPort ? baseEndpoint.port : null,
      path: '/$path',
    );
  }
}

class SessionRecorderTransportException implements Exception {
  const SessionRecorderTransportException(
    this.message, {
    this.statusCode,
  });

  final String message;
  final int? statusCode;

  bool get isForbidden => statusCode == 403;

  @override
  String toString() => 'SessionRecorderTransportException($message)';
}
