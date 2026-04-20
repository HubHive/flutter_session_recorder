import 'dart:convert';

class RecorderEvent {
  RecorderEvent({
    required this.type,
    Map<String, Object?> attributes = const <String, Object?>{},
    DateTime? timestamp,
    String? id,
  })  : attributes = Map<String, Object?>.unmodifiable(attributes),
        timestamp = timestamp ?? DateTime.now().toUtc(),
        id = id ?? _defaultId();

  final Map<String, Object?> attributes;
  final String id;
  final DateTime timestamp;
  final String type;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'type': type,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'attributes': normalizeAttributes(attributes),
    };
  }

  static String _defaultId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    return 'evt_$now';
  }
}

Map<String, Object?> normalizeAttributes(Map<String, Object?> values) {
  return values.map<String, Object?>(
    (String key, Object? value) =>
        MapEntry<String, Object?>(key, _normalizeValue(value)),
  );
}

Object? _normalizeValue(Object? value) {
  if (value == null || value is bool || value is String) {
    return value;
  }

  if (value is num) {
    return value.isFinite ? value : null;
  }

  if (value is DateTime) {
    return value.toUtc().toIso8601String();
  }

  if (value is Duration) {
    return value.inMilliseconds;
  }

  if (value is Uri) {
    return value.toString();
  }

  if (value is Enum) {
    return value.name;
  }

  if (value is Iterable<Object?>) {
    return value.map<Object?>(_normalizeValue).toList(growable: false);
  }

  if (value is Map<Object?, Object?>) {
    return value.map<String, Object?>(
      (Object? key, Object? nestedValue) => MapEntry<String, Object?>(
        key.toString(),
        _normalizeValue(nestedValue),
      ),
    );
  }

  if (value is List<int>) {
    return base64Encode(value);
  }

  return value.toString();
}
