from pathlib import Path

root = Path(__file__).resolve().parents[1]
vpn = (root / "lib/logic/vpn_connection.dart").read_text(encoding="utf-8")
guard = (root / "lib/logic/vpn_start_guard.dart").read_text(encoding="utf-8")
tests = (root / "test/vpn_start_guard_test.dart").read_text(encoding="utf-8")
health_gate = (root / "lib/logic/vpn_health_poll_gate.dart").read_text(encoding="utf-8")
health_tests = (root / "test/vpn_health_poll_gate_test.dart").read_text(encoding="utf-8")
workflow = (root / ".github/workflows/flutter-strict.yml").read_text(encoding="utf-8")

required = [
    (vpn, "if (_connectInFlight ||"),
    (vpn, "_status == VpnStatus.disconnecting"),
    (vpn, "_startGuard.cannotRestart"),
    (vpn, "if (_cancelled || _status == VpnStatus.disconnecting) return;"),
    (vpn, "if (_cancelled) return false;"),
    (vpn, "_startGuard.start(() => _vless.startVless("),
    (vpn, "_startGuard.cancel();"),
    (vpn, "_startGuard.waitForStart("),
    (vpn, "_startGuard.stopAfterLateStart("),
    (guard, "Future<bool> start(Future<void> Function() begin)"),
    (guard, "Future<bool> waitForStart(Duration timeout)"),
    (guard, "void stopAfterLateStart(Future<void> Function() stop)"),
    (guard, "_lateCleanupFailed = true;"),
    (guard, "bool get mayReportConnected =>"),
    (guard, "void authorizeConnected()"),
    (guard, "void invalidateConnected()"),
    (guard, "void blockUnsafeRestart()"),
    (guard, "Future<bool> cleanupFailedStart(Future<void> Function() stop)"),
    (vpn, "var nativeStartAttempted = false;"),
    (vpn, "if (nativeStartAttempted) {"),
    (vpn, "await _startGuard.cleanupFailedStart("),
    (tests, "rejected native start stops partial VPN before retry"),
    (tests, "failed partial-start cleanup locks down all future admissions"),
    (tests, "partial-start cleanup holds restart barrier until native stop settles"),
    (tests, "synchronous native stop failure is also fail closed"),
    (tests, "synchronous partial cleanup callback cannot start another cleanup"),
    (tests, "synchronous cleanup callback cannot reenter native start"),
    (tests, "synchronous native callback cannot reenter a second start"),
    (tests, "synchronous cancellation during begin blocks an authenticated start"),
    (tests, "direct native start is denied during failed cleanup latch"),
    (tests, "direct native start cannot bypass unfinished local cleanup"),
    (tests, "synchronous begin exception releases reservation after propagation"),
    (tests, "stop marker write fault still stops native tunnel after a late start"),
    (tests, "duplicate deferred native stop cannot replace cleanup barrier"),
    (tests, "duplicate deferred cleanup cannot conceal first native stop failure"),
    (vpn, "if (!_startGuard.mayReportConnected) return;"),
    (vpn, "final probe = ownedNonce == null"),
    (vpn, "await HivemindService.probeCurrentSession();"),
    (vpn, "if (probe == SessionProbeResult.active && !stopPending)"),
    (vpn, "final stopPending = await CryptoService.isSessionStopPending();"),
    (vpn, "'Revocation pending'"),
    (vpn, "_startGuard.blockUnsafeRestart();"),
    (tests, "native connected callbacks are denied without authenticated state"),
    (tests, "cancelled or reset generations reject old connected callbacks"),
    (tests, "failed startup restoration teardown permanently blocks reconnect"),
    (tests, "late start cleanup never authorizes connected in a new attempt"),
    (tests, "cancel during native start cannot report connected"),
    (tests, "timed out native start stays blocked through deferred cleanup"),
    (tests, "failed deferred native stop denies reconnection"),
    (tests, "failed explicit native disconnect permanently denies reconnect"),
    (tests, "failed startup revocation stop cannot be reset by status callbacks"),
    (workflow, "python3 tool/check_vpn_start_guard_contract.py"),
]
for source, token in required:
    assert token in source, f"Missing native VPN start/stop invariant: {token}"

# An in-process caller can bypass the UI's connect() entrypoint. Guarding
# only connect() is insufficient; the native start slot itself must reject
# reentrant callbacks and forbidden post-teardown restart attempts.
native_start = guard.split("Future<bool> start(Future<void> Function() begin) async {", 1)[1].split("Future<bool> waitForStart(", 1)[0]
assert "if (_cancelled || cannotRestart) return false;" in native_start
assert native_start.index("_starting = operation;") < native_start.index("Future<void>.sync(begin)")
assert native_start.index("Future<void>.sync(begin)") < native_start.index("await operation;")
assert "completion.completeError(error, trace);" in native_start
assert "if (identical(_starting, operation)) _starting = null;" in native_start

# Partial failed-start teardown must also acquire its own reservation before
# invoking platform stop, or a synchronous status event can start a second stop.
native_cleanup = guard.split("Future<bool> cleanupFailedStart(Future<void> Function() stop) async {", 1)[1].split("void stopAfterLateStart(", 1)[0]
assert "if (_lateCleanup != null || _lateCleanupFailed) return false;" in native_cleanup
assert native_cleanup.index("_lateCleanup = cleanup;") < native_cleanup.index("Future<void>.sync(stop)")
assert "completion.completeError(error, trace);" in native_cleanup
assert "if (identical(_lateCleanup, cleanup)) _lateCleanup = null;" in native_cleanup

deferred_cleanup = guard.split("void stopAfterLateStart(Future<void> Function() stop) {", 1)[1]
assert "if (operation == null || _lateCleanup != null) return;" in deferred_cleanup
assert deferred_cleanup.index("if (operation == null || _lateCleanup != null) return;") < deferred_cleanup.index("final cleanup = operation.then<void>(") < deferred_cleanup.index("_lateCleanup = cleanup;")
assert "if (operation == null || _lateCleanupFailed) return;" not in deferred_cleanup
assert "if (identical(_lateCleanup, cleanup)) _lateCleanup = null;" in deferred_cleanup

connect = vpn.split("Future<bool> _connectInner(", 1)[1].split("Future<void> disconnect()", 1)[0]
assert connect.count("_vless.startVless(") == 1
assert "_startGuard.start(() => _vless.startVless(" in connect
assert connect.index("nativeStartAttempted = true;") < connect.index("_startGuard.start(() => _vless.startVless(")
failed_start = connect.split("if (nativeStartAttempted) {", 1)[1].split("if (_cancelled) return false;", 1)[0]
assert "await _startGuard.cleanupFailedStart(" in failed_start
assert "() => _vless.stopVless().timeout(const Duration(seconds: 5))" in failed_start
assert "if (!cleaned) {" in failed_start
assert connect.index("if (!started || _cancelled) return false;") < connect.index("_startGuard.authorizeConnected();") < connect.index("_setStatus(VpnStatus.connected, 'Secured');")

restore = vpn.split("final delay = await _vless.getConnectedServerDelay();", 1)[1].split("void _mapStatus(", 1)[0]
assert restore.index("await HivemindService.probeCurrentSession();") < restore.index("final stopPending = await CryptoService.isSessionStopPending();") < restore.index("_startGuard.authorizeConnected();") < restore.index("_setStatus(VpnStatus.connected, 'Secured');")
assert restore.index("await _vless.stopVless().timeout(") < restore.index("_startGuard.blockUnsafeRestart();")

# Native disconnect and disconnecting events must own server revocation even
# if no SessionTimer/UI observer is registered at the moment the event fires.
for state, next_state in (
    ("disconnected", "connecting"),
    ("disconnecting", "unknown"),
):
    branch = vpn.split(f"case VlessConnectionState.{state}:", 1)[1].split(
        f"case VlessConnectionState.{next_state}:", 1
    )[0]
    assert "_revokeUnexpectedNativeDrop();" in branch, state
    assert "_setStatus(VpnStatus.disconnected" not in branch, state

unexpected_drop = vpn.split("void _revokeUnexpectedNativeDrop() {", 1)[1].split("// ── Connect", 1)[0]
assert "unawaited(disconnect().catchError(" in unexpected_drop
assert "_startGuard.blockUnsafeRestart();" in unexpected_drop
assert "_setStatus(VpnStatus.error, 'Revocation failed');" in unexpected_drop

# Closing a UI notifier is not a session stop. Unawaited native stop from
# dispose previously bypassed the durable intent and server revoke entirely.
dispose = vpn.split("void dispose() {", 1)[1]
assert "_vless.stopVless()" not in dispose
assert "_disposed = true;" in dispose
startup_init = vpn.split("Future<void> _init() async {", 1)[1].split("Future<void> _startEngine() async {", 1)[0]
assert "if (!kIsWeb && !_disposed)" in startup_init
assert "if (_disposed) return;" in vpn.split("void _mapStatus(VlessStatus status)", 1)[1].split("switch (status.connectionState)", 1)[0]
assert "if (_disposed) return;" in vpn.split("void _setStatus(VpnStatus s, String msg)", 1)[1].split("Future<void> _checkHealth()", 1)[0]
assert "if (stillCurrent()) notifyListeners();" in vpn.split("Future<void> _checkHealthOnce()", 1)[1].split("void dispose()", 1)[0]

native_connected = vpn.split("case VlessConnectionState.connected:", 1)[1].split("case VlessConnectionState.disconnected:", 1)[0]
assert native_connected.index("if (!_startGuard.mayReportConnected) return;") < native_connected.index("_setStatus(VpnStatus.connected, 'Secured');")
disconnect = vpn.split("Future<void> disconnect()", 1)[1].split("void _setStatus(", 1)[0]
assert "final SessionStopBarrier _disconnectBarrier = SessionStopBarrier();" in vpn
assert "_disconnectBarrier.isStopping ||" in vpn.split("Future<bool> connect(", 1)[1].split("Future<bool> _connectInner(", 1)[0]
assert "return _disconnectBarrier.run(_disconnectInner);" in disconnect
assert disconnect.index("_startGuard.cancel();") < disconnect.index("return _disconnectBarrier.run(_disconnectInner);") < disconnect.index("CryptoService.setSessionStopPending();")
assert "if (_status == VpnStatus.disconnecting) return;" not in disconnect
normal_disconnect = disconnect.split("bool localStopFailed = false;", 1)[1]
assert normal_disconnect.index("_startGuard.waitForStart(") < normal_disconnect.index("_vless.stopVless().timeout(")
assert normal_disconnect.index("_vless.stopVless().timeout(") < normal_disconnect.index("HivemindService.stopSession(markPending: false)")
assert "await CryptoService.setSessionStopPending();" in disconnect

# Failure to persist stop intent must not strand the UI in disconnecting or
# permit a new native start. Best-effort local + remote stop still execute.
persistence = disconnect.split("await CryptoService.setSessionStopPending();", 1)[1].split("bool localStopFailed = false;", 1)[0]
assert "catch (e) {" in persistence
assert "if (_startGuard.isStarting) {" in persistence
assert "_startGuard.stopAfterLateStart(" in persistence
assert persistence.index("_startGuard.blockUnsafeRestart();") < persistence.index("_startGuard.stopAfterLateStart(") < persistence.index("await _vless.stopVless().timeout(")
assert persistence.index("await _vless.stopVless().timeout(") < persistence.index("await HivemindService.stopSession(markPending: false);")
assert persistence.index("await HivemindService.stopSession(markPending: false);") < persistence.index("_setStatus(VpnStatus.error, 'Shutdown not durable');")

# A failed local stop is an unresolved TUN state, not merely a UI error.
# Server revocation success does not prove the device's VPN engine stopped.
local_failure = disconnect.split("if (localStopFailed) {", 1)[1].split("if (revocationPending) {", 1)[0]
assert local_failure.index("_startGuard.blockUnsafeRestart();") < local_failure.index("_setStatus(VpnStatus.error, 'Shutdown failed');")
assert disconnect.index("stopResult = await HivemindService.stopSession(markPending: false);") < disconnect.index("if (localStopFailed) {")
stop_error = disconnect.split("stopResult = await HivemindService.stopSession(markPending: false);", 1)[1].split("final revocationPending =", 1)[0]
assert stop_error.index("_startGuard.blockUnsafeRestart();") < stop_error.index("_setStatus(VpnStatus.error, 'Revocation unverified');") < stop_error.index("rethrow;")

pending_startup = vpn.split("if (await CryptoService.isSessionStopPending()) {", 1)[1].split("final coreVersion =", 1)[0]
assert pending_startup.index("if (!_initialized) {") < pending_startup.index("_startGuard.blockUnsafeRestart();") < pending_startup.index("await _vless.stopVless().timeout(")
assert pending_startup.index("await _vless.stopVless().timeout(") < pending_startup.rindex("_startGuard.blockUnsafeRestart();")
assert "var localStopFailed = !_initialized;" in pending_startup
assert pending_startup.index("_startGuard.blockUnsafeRestart();") < pending_startup.index("final resolved = await HivemindService.retryPendingSessionStop();")
assert pending_startup.index("if (localStopFailed) {") < pending_startup.index("if (resolved) {")

# Initial health checks must never consume pending stop intent before local
# engine shutdown and the first authenticated recovery decision have finished.
init = vpn.split("Future<void> _init() async {", 1)[1].split("Future<void> _startEngine() async {", 1)[0]
engine = vpn.split("Future<void> _startEngine() async {", 1)[1].split("void _mapStatus(", 1)[0]
assert init.index("await _startEngine();") < init.index("unawaited(_checkHealth());")
assert init.index("await _startEngine();") < init.index("_healthTimer ??=")
assert "_checkHealth();" not in engine
assert "Timer.periodic(" not in engine

# A background recovery query is unawaited by the periodic timer. Storage
# errors must produce a visible failure and no-restart latch, not an unhandled
# Future which silently loses the stop-intent verification requirement.
health = vpn.split("Future<void> _checkHealthOnce() async {", 1)[1].split("void dispose()", 1)[0]
assert "Future<void> _checkHealth() => _healthPollGate.run(_checkHealthOnce);" in vpn
assert "final VpnHealthPollGate _healthPollGate = VpnHealthPollGate();" in vpn
assert "Future<void>? _pending;" in health_gate
assert "if (existing != null) return existing;" in health_gate
assert health_gate.index("_pending = current;") < health_gate.index("Future<void>.sync(poll)")
assert "timer reentry and overlapping ticks share one recovery operation" in health_tests
assert "pending recovery error reaches every waiter then releases the gate" in health_tests
assert "if (_disposed || _disconnectBarrier.isStopping) return;" in health
assert "final healthGeneration = _healthPollGate.generation;" in health
assert "_healthPollGate.accepts(healthGeneration)" in health
assert health.count("if (!stillCurrent()) return;") >= 3
assert "bool stillCurrent() =>" in health
assert "if (!stillCurrent()) return;" in health.split("catch (e) {", 1)[1]
assert "void invalidate() => _generation++;" in health_gate
assert "bool accepts(int capturedGeneration) => capturedGeneration == _generation;" in health_gate
assert "completed disconnect epoch invalidates delayed storage recovery" in health_tests
assert "next connect epoch ignores obsolete health recovery errors" in health_tests
assert "_healthPollGate.invalidate();" in vpn.split("Future<bool> connect(", 1)[1].split("Future<bool> _connectInner(", 1)[0]
assert "_healthPollGate.invalidate();" in vpn.split("Future<void> disconnect() {", 1)[1].split("Future<void> _disconnectInner()", 1)[0]
assert health.index("await CryptoService.isSessionStopPending()") < health.index("final resolved = await HivemindService.retryPendingSessionStop();")
assert "try {" in health
assert "await HivemindService.checkHealth();" in health
assert "!_disconnectBarrier.isStopping &&" in health
assert "await CryptoService.isSessionStopPending()" in health
assert "await HivemindService.retryPendingSessionStop();" in health
assert "catch (e) {" in health
assert health.index("catch (e) {") < health.index("_startGuard.blockUnsafeRestart();") < health.index("_setStatus(VpnStatus.error, 'Recovery unverified');")
assert "if (!stillCurrent()) return;" in health.split("catch (e) {", 1)[1]

print("[PASS] Native start/stop and recovery checks reject reentrant callbacks, unverifiable health and ambiguous teardown.")
