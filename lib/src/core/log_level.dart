/// Typed severity for `log` events.
///
/// [LogLevel] exists only in Dart. It serializes to a lowercase wire string at
/// the transport boundary; the wire format itself is unchanged.
///
/// Note: "error" here is a log *level*, not the separate `error` event type
/// emitted by `recorder.error(...)`. There is no fatal/critical level.
enum LogLevel {
  debug,
  info,
  warn,
  error;

  /// The lowercase wire string used when serializing a `log` event.
  String get wireValue => name;

  /// Parses a wire string into a [LogLevel].
  ///
  /// Unknown values, typos, and `null` coerce to [LogLevel.info]; this never
  /// throws and never drops the log.
  static LogLevel fromWire(String? value) {
    for (final LogLevel level in LogLevel.values) {
      if (level.wireValue == value) {
        return level;
      }
    }
    return LogLevel.info;
  }
}
