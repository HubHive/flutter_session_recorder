import 'log_level.dart';

/// Callback that enqueues a single `log` event at a resolved [LogLevel].
typedef LogSink = void Function({
  required String message,
  required LogLevel level,
  String? logger,
  Map<String, Object?> properties,
});

/// Callable log facade exposed as `recorder.log`.
///
/// Calling the instance directly (`recorder.log("msg", level: "error")`) is
/// deprecated and routes its string `level` through [LogLevel.fromWire],
/// coercing unknown values to [LogLevel.info]. Prefer the leveled methods
/// [debug], [info], [warn], and [error], each of which hard-wires its level.
class LeveledLogger {
  const LeveledLogger(this._sink);

  final LogSink _sink;

  /// Deprecated string-level entry point, preserved for the legacy
  /// `recorder.log("msg", level: "...")` call site.
  @Deprecated(
    'Use recorder.log.debug/info/warn/error instead. '
    'The string `level` argument will be removed in a future release.',
  )
  void call(
    String message, {
    String level = 'info',
    String? logger,
    Map<String, Object?> properties = const <String, Object?>{},
  }) {
    _sink(
      message: message,
      level: LogLevel.fromWire(level),
      logger: logger,
      properties: properties,
    );
  }

  void debug(
    String message, {
    String? logger,
    Map<String, Object?> properties = const <String, Object?>{},
  }) {
    _sink(
      message: message,
      level: LogLevel.debug,
      logger: logger,
      properties: properties,
    );
  }

  void info(
    String message, {
    String? logger,
    Map<String, Object?> properties = const <String, Object?>{},
  }) {
    _sink(
      message: message,
      level: LogLevel.info,
      logger: logger,
      properties: properties,
    );
  }

  void warn(
    String message, {
    String? logger,
    Map<String, Object?> properties = const <String, Object?>{},
  }) {
    _sink(
      message: message,
      level: LogLevel.warn,
      logger: logger,
      properties: properties,
    );
  }

  void error(
    String message, {
    String? logger,
    Map<String, Object?> properties = const <String, Object?>{},
  }) {
    _sink(
      message: message,
      level: LogLevel.error,
      logger: logger,
      properties: properties,
    );
  }

  /// Logs a caught exception as exactly one error-level `log` event.
  ///
  /// The event's `message` is a *stable* string — the caller-supplied
  /// [summary] when given, otherwise `error.runtimeType` — so downstream error
  /// triage can fingerprint on it. The volatile parts (the exception text and
  /// the stack trace) are folded into [properties] under the `error` and
  /// `stackTrace` keys instead of the message, so they never poison the
  /// fingerprint.
  ///
  /// Prefer this over emitting two `error(...)` calls (one for the exception,
  /// one for `stackTrace.toString()`): the second call's message is a whole
  /// stack trace, which is unique per occurrence and defeats deduplication.
  ///
  /// Caller-supplied [properties] are merged first; the `error` and
  /// `stackTrace` keys always win. Keep [properties] small and
  /// JSON-serializable.
  void exception(
    Object error, {
    StackTrace? stackTrace,
    String? summary,
    String? logger,
    Map<String, Object?> properties = const <String, Object?>{},
  }) {
    _sink(
      message: summary ?? error.runtimeType.toString(),
      level: LogLevel.error,
      logger: logger,
      properties: <String, Object?>{
        ...properties,
        'error': error.toString(),
        if (stackTrace != null) 'stackTrace': stackTrace.toString(),
      },
    );
  }
}
