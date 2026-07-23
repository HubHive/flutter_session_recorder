import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A persisted liveness record for force-quit (true crash) detection.
///
/// The recorder writes one of these to disk while a Session is live and
/// updates [foreground] as the app moves between the foreground and
/// background. A clean shutdown ([SessionRecorder.stop]) deletes it. If a
/// record survives to the NEXT launch, the previous run died without a
/// clean shutdown; if it was last seen in the [foreground], that death is
/// treated as a crash (force-quit) — a background death is the OS reclaiming
/// memory and is deliberately not counted (see CONTEXT.md "Force-quit").
class CrashSentinelState {
  const CrashSentinelState({
    required this.sessionId,
    required this.foreground,
    this.at,
  });

  /// The live Session's id — the Session a surviving record incriminates.
  final String sessionId;

  /// Whether the app was in the foreground at the last update. Only a
  /// foreground death counts as a crash.
  final bool foreground;

  /// When this record was last written (best-effort crash timestamp).
  final DateTime? at;

  Map<String, Object?> toJson() => <String, Object?>{
        'sessionId': sessionId,
        'foreground': foreground,
        'at': at?.toIso8601String(),
      };

  /// Parses a stored record, returning null if it is malformed or missing a
  /// usable session id — a bad record must never fabricate a crash.
  static CrashSentinelState? fromJson(Map<String, Object?> json) {
    final Object? sessionId = json['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) {
      return null;
    }
    final Object? rawAt = json['at'];
    return CrashSentinelState(
      sessionId: sessionId,
      foreground: json['foreground'] == true,
      at: rawAt is String ? DateTime.tryParse(rawAt) : null,
    );
  }
}

/// The persistence seam for the crash sentinel. Abstracted so the recorder
/// can be unit-tested with an in-memory fake and so the production
/// implementation can swallow platform errors without the recorder caring.
abstract class CrashSentinel {
  /// Returns the record left by the most recent run, or null if the last
  /// run shut down cleanly (or none has run yet).
  Future<CrashSentinelState?> read();

  /// Persists the current liveness state, replacing any prior record.
  Future<void> write(CrashSentinelState state);

  /// Removes the record — called on a clean shutdown so the next launch
  /// sees no crash.
  Future<void> clear();
}

/// [CrashSentinel] backed by shared_preferences. Every operation is
/// best-effort: a platform failure resolves to a no-op (or null read) so
/// crash detection can never break recording itself.
class SharedPreferencesCrashSentinel implements CrashSentinel {
  const SharedPreferencesCrashSentinel();

  static const String _key = 'com.hubhive.session_recorder.crash_sentinel';

  @override
  Future<CrashSentinelState?> read() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) {
        return null;
      }
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        return null;
      }
      return CrashSentinelState.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(CrashSentinelState state) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(state.toJson()));
    } catch (_) {
      // Best-effort: a failed write just means a missed crash report.
    }
  }

  @override
  Future<void> clear() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {
      // Best-effort: a failed clear can only ever cause a false positive,
      // which the foreground check and next clean run will correct.
    }
  }
}
