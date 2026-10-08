import 'dart:async';

/// Coordinates an in-flight native VPN start with user-initiated teardown.
/// A cancelled start must never be accepted as an established connection.
class VpnStartGuard {
  bool _cancelled = false;
  Future<void>? _starting;
  Future<void>? _lateCleanup;
  bool _lateCleanupFailed = false;
  bool get cancelled => _cancelled;
  bool get isStarting => _starting != null;
  bool get cannotRestart =>
      _starting != null || _lateCleanup != null || _lateCleanupFailed;

  void reset() {
    if (cannotRestart) {
      throw StateError('Previous VPN start or cleanup has not settled');
    }
    _cancelled = false;
  }

  void cancel() => _cancelled = true;

  /// Registers the native Future synchronously, without an await gap.
  Future<bool> start(Future<void> Function() begin) async {
    if (_cancelled || _starting != null) return false;
    final operation = begin();
    _starting = operation;
    try {
      await operation;
      return !_cancelled;
    } finally {
      if (identical(_starting, operation)) _starting = null;
    }
  }

  /// The caller must stop the native engine AFTER start settles.
  /// A timeout means the tunnel's local shutdown cannot be confirmed.
  Future<bool> waitForStart(Duration timeout) async {
    final operation = _starting;
    if (operation == null) return true;
    try {
      await operation.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    } catch (_) {
      // Start failed; still perform the native stop as defense in depth.
      return true;
    }
  }

  /// If the original native operation completes after our wait timed out,
  /// schedule one further native stop. Never claim that it succeeded early.
  void stopAfterLateStart(Future<void> Function() stop) {
    final operation = _starting;
    if (operation == null) return;
    // Keep this barrier until late cleanup finishes, even if start already
    // settled. Otherwise a fresh connect can race a delayed stopVless().
    final cleanup = operation.then<void>((_) => stop(),
        onError: (Object _, StackTrace __) => stop());
    _lateCleanup = cleanup;
    unawaited(cleanup.then<void>((_) {
      if (identical(_lateCleanup, cleanup)) _lateCleanup = null;
    }, onError: (Object _, StackTrace __) {
      _lateCleanupFailed = true; // Deny reconnect until process recovery.
      if (identical(_lateCleanup, cleanup)) _lateCleanup = null;
    }));
  }
}
