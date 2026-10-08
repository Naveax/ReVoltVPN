import 'dart:async';

/// Coordinates an in-flight native VPN start with user-initiated teardown.
/// A cancelled start must never be accepted as an established connection.
class VpnStartGuard {
  bool _cancelled = false;
  Future<void>? _starting;
  Future<void>? _lateCleanup;
  bool _lateCleanupFailed = false;
  bool _authenticatedTunnel = false;
  bool get cancelled => _cancelled;
  // A native callback or ping is not authenticated proof of a session.
  bool get mayReportConnected =>
      _authenticatedTunnel && !_cancelled && !cannotRestart;

  void authorizeConnected() {
    if (_cancelled || cannotRestart) {
      throw StateError('Native VPN cannot be marked secure');
    }
    _authenticatedTunnel = true;
  }

  void invalidateConnected() => _authenticatedTunnel = false;

  // Native teardown failure is not recoverable by another unverified start.
  void blockUnsafeRestart() {
    _authenticatedTunnel = false;
    _lateCleanupFailed = true;
  }

  bool get isStarting => _starting != null;
  bool get cannotRestart =>
      _starting != null || _lateCleanup != null || _lateCleanupFailed;

  void reset() {
    if (cannotRestart) {
      throw StateError('Previous VPN start or cleanup has not settled');
    }
    _cancelled = false;
    _authenticatedTunnel = false;
  }

  void cancel() {
    _cancelled = true;
    _authenticatedTunnel = false;
  }

  /// Reserve the native start slot before invoking any platform code. The
  /// platform callback may synchronously reenter start/cancel/disconnect.
  Future<bool> start(Future<void> Function() begin) async {
    if (_cancelled || cannotRestart) return false;
    final completion = Completer<void>();
    final operation = completion.future;
    _starting = operation;
    try {
      // Future.sync captures both synchronous platform exceptions and future
      // failures while the reservation stays visible to reentrant callers.
      Future<void>.sync(begin).then(completion.complete,
          onError: (Object error, StackTrace trace) {
        completion.completeError(error, trace);
      });
      await operation;
      return !_cancelled && !_lateCleanupFailed;
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

  /// A rejected native start may have already published a partial OS VPN.
  /// Clean it before another admission. The cleanup itself holds the restart
  /// barrier, and an error permanently denies restart in this process.
  Future<bool> cleanupFailedStart(Future<void> Function() stop) async {
    if (_lateCleanup != null || _lateCleanupFailed) return false;
    // Reserve cleanup ownership BEFORE a platform stop call. Native status
    // callbacks can synchronously reenter cleanup or attempt another start.
    final completion = Completer<void>();
    final cleanup = completion.future;
    _lateCleanup = cleanup;
    try {
      Future<void>.sync(stop).then(completion.complete,
          onError: (Object error, StackTrace trace) {
        completion.completeError(error, trace);
      });
      await cleanup;
      return true;
    } catch (_) {
      blockUnsafeRestart();
      return false;
    } finally {
      if (identical(_lateCleanup, cleanup)) _lateCleanup = null;
    }
  }

  /// If the original native operation completes after our wait timed out;
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
