import 'dart:async';

import 'package:flutter/services.dart';

import 'session_recorder_config.dart';

abstract class SessionRecorderNativeBridge {
  Stream<Map<String, Object?>> get eventStream;

  Future<Map<String, Object?>> getDeviceContext();

  Future<void> setScreenName(String? screenName);

  Future<void> startCapture(SessionRecorderConfig config);

  Future<void> startSnapshotCapture(SessionRecorderConfig config);

  Future<void> pauseCapture();

  Future<void> resumeCapture(SessionRecorderConfig config);

  Future<void> stopSnapshotCapture();

  Future<void> stopCapture();
}

class MethodChannelSessionRecorderNativeBridge
    implements SessionRecorderNativeBridge {
  MethodChannelSessionRecorderNativeBridge({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methodChannel = methodChannel ??
            const MethodChannel('flutter_session_recorder/methods'),
        _eventChannel = eventChannel ??
            const EventChannel('flutter_session_recorder/events');

  final EventChannel _eventChannel;
  final MethodChannel _methodChannel;

  Stream<Map<String, Object?>>? _eventStream;

  @override
  Future<Map<String, Object?>> getDeviceContext() async {
    final Map<Object?, Object?>? raw =
        await _methodChannel.invokeMapMethod<Object?, Object?>(
      'getDeviceContext',
    );
    final Map<Object?, Object?> source = raw ?? <Object?, Object?>{};
    return source.map<String, Object?>(
      (Object? key, Object? value) =>
          MapEntry<String, Object?>(key.toString(), value),
    );
  }

  @override
  Future<void> setScreenName(String? screenName) async {
    await _methodChannel.invokeMethod<void>(
      'setScreenName',
      <String, Object?>{'screenName': screenName},
    );
  }

  @override
  Stream<Map<String, Object?>> get eventStream {
    return _eventStream ??=
        _eventChannel.receiveBroadcastStream().map<Map<String, Object?>>((raw) {
      final Map<Object?, Object?> source =
          (raw as Map<Object?, Object?>?) ?? <Object?, Object?>{};
      return source.map<String, Object?>(
        (Object? key, Object? value) =>
            MapEntry<String, Object?>(key.toString(), value),
      );
    });
  }

  @override
  Future<void> startCapture(SessionRecorderConfig config) async {
    await _methodChannel.invokeMethod<void>('startCapture', config.toJson());
  }

  @override
  Future<void> startSnapshotCapture(SessionRecorderConfig config) async {
    await _methodChannel.invokeMethod<void>(
      'startSnapshotCapture',
      config.toJson(),
    );
  }

  @override
  Future<void> pauseCapture() async {
    await _methodChannel.invokeMethod<void>('pauseCapture');
  }

  @override
  Future<void> resumeCapture(SessionRecorderConfig config) async {
    await _methodChannel.invokeMethod<void>('resumeCapture', config.toJson());
  }

  @override
  Future<void> stopSnapshotCapture() async {
    await _methodChannel.invokeMethod<void>('stopSnapshotCapture');
  }

  @override
  Future<void> stopCapture() async {
    await _methodChannel.invokeMethod<void>('stopCapture');
  }
}
