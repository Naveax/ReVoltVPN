/// Validated active-session accounting projected by the Rust /session/status
/// API. A response without these fields is not a fresh accounting sample.
/// It must not refresh the offline watchdog or extend the displayed session.
final class SessionStatusSnapshot {
  final int remainingSeconds;
  final int usedBytes;
  final int hardCapBytes;
  final bool capExhausted;

  const SessionStatusSnapshot({
    required this.remainingSeconds,
    required this.usedBytes,
    required this.hardCapBytes,
    required this.capExhausted,
  });

  bool get mustStop =>
      remainingSeconds == 0 || capExhausted || usedBytes >= hardCapBytes;

  static SessionStatusSnapshot? parseActive(Object? body) {
    if (body is! Map<String, dynamic> || body['active'] != true) {
      return null;
    }
    final remaining = body['expires_in_seconds'];
    final used = body['used_bytes'];
    final cap = body['hard_cap_bytes'];
    final exhausted = body['cap_exhausted'];
    // Rust sends unsigned integral second/byte counters, a nonzero hard cap
    // and an explicit boolean. Never coerce strings, floats or nulls.
    if (remaining is! int ||
        remaining < 0 ||
        used is! int ||
        used < 0 ||
        cap is! int ||
        cap <= 0 ||
        exhausted is! bool) {
      return null;
    }
    return SessionStatusSnapshot(
      remainingSeconds: remaining,
      usedBytes: used,
      hardCapBytes: cap,
      capExhausted: exhausted,
    );
  }
}
