import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'session_batch.dart';
import 'session_keyframe.dart';

abstract class SessionRecorderTransport {
  Future<void> send(SessionBatch batch);

  Future<UploadedKeyframe> uploadKeyframe(SessionKeyframeUpload upload);

  Future<bool> checkRecordingAccess();
}

class NoopSessionRecorderTransport implements SessionRecorderTransport {
  const NoopSessionRecorderTransport();

  @override
  Future<void> send(SessionBatch batch) async {}

  @override
  Future<UploadedKeyframe> uploadKeyframe(SessionKeyframeUpload upload) async {
    return UploadedKeyframe(
      frameRef:
          'noop_${upload.sessionId}_${upload.timestamp.microsecondsSinceEpoch}',
    );
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
  Future<UploadedKeyframe> uploadKeyframe(SessionKeyframeUpload upload) async {
    final String frameRef =
        'debug_${upload.sessionId}_${upload.timestamp.microsecondsSinceEpoch}';
    debugPrint(
      '[flutter_session_recorder transport] ${jsonEncode(<String, Object?>{
            'type': 'replay.keyframe.upload',
            'frameRef': frameRef,
            'sessionId': upload.sessionId,
            'reason': upload.reason,
            'screenName': upload.screenName,
            'format': upload.format,
            'byteLength': upload.bytes.length,
            'metadata': upload.metadata,
            'viewport': upload.viewport,
          })}',
    );
    return UploadedKeyframe(frameRef: frameRef);
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
    @Deprecated(
      'Pass the recorder service root as endpoint instead. '
      'Keyframes are uploaded to /frames by default.',
    )
    Uri? frameEndpoint,
    this.apiKey,
    Map<String, String> headers = const <String, String>{},
    http.Client? client,
  })  : baseEndpoint = endpoint,
        endpoint = _defaultUploadEndpoint(endpoint, 'sessions'),
        _headers = Map<String, String>.unmodifiable(headers),
        _frameEndpoint =
            frameEndpoint ?? _defaultUploadEndpoint(endpoint, 'frames'),
        _recordingAccessEndpoint =
            _defaultUploadEndpoint(endpoint, 'recording-access-test'),
        _client = client ?? http.Client();

  final String? apiKey;
  final Uri baseEndpoint;
  final Uri endpoint;
  final Uri _frameEndpoint;
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
  Future<UploadedKeyframe> uploadKeyframe(SessionKeyframeUpload upload) async {
    final http.MultipartRequest request = http.MultipartRequest(
      'POST',
      _frameEndpoint,
    );

    request.headers.addAll(_baseHeaders());
    request.fields.addAll(<String, String>{
      'sessionId': upload.sessionId,
      'reason': upload.reason,
      'timestamp': upload.timestamp.toUtc().toIso8601String(),
      'screenName': upload.screenName ?? '',
      'format': upload.format,
      'viewport': jsonEncode(upload.viewport),
      'metadata': jsonEncode(upload.metadata),
    });
    request.files.add(
      http.MultipartFile.fromBytes(
        'frame',
        upload.bytes,
        filename: 'frame.${upload.format}',
      ),
    );

    final http.StreamedResponse response = await _client.send(request);
    final String responseBody = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SessionRecorderTransportException(
        'Failed to upload keyframe (${response.statusCode}): $responseBody',
        statusCode: response.statusCode,
      );
    }

    String? frameRef;
    if (responseBody.isNotEmpty) {
      final Object? decoded = jsonDecode(responseBody);
      if (decoded is Map<Object?, Object?>) {
        frameRef = decoded['frameRef']?.toString() ?? decoded['id']?.toString();
      }
    }

    frameRef ??= response.headers['x-frame-ref'];
    frameRef ??=
        '${upload.sessionId}_${upload.timestamp.microsecondsSinceEpoch}';

    return UploadedKeyframe(frameRef: frameRef);
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
