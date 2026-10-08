from pathlib import Path

root = Path(__file__).resolve().parents[1]
vpn = (root / "lib/logic/vpn_connection.dart").read_text(encoding="utf-8")
guard = (root / "lib/logic/vpn_start_guard.dart").read_text(encoding="utf-8")
tests = (root / "test/vpn_start_guard_test.dart").read_text(encoding="utf-8")
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
assert "if (!_disposed) notifyListeners();" in vpn.split("Future<void> _checkHealth()", 1)[1].split("void dispose()", 1)[0]

native_connected = vpn.split("case VlessConnectionState.connected:", 1)[1].split("case VlessConnectionState.disconnected:", 1)[0]
assert native_connected.index("if (!_startGuard.mayReportConnected) return;") < native_connected.index("_setStatus(VpnStatus.connected, 'Secured');")
disconnect = vpn.split("Future<void> disconnect()", 1)[1].split("void _setStatus(", 1)[0]
assert disconnect.index("_startGuard.cancel();") < disconnect.index("CryptoService.setSessionStopPending();")
assert disconnect.index("_startGuard.waitForStart(") < disconnect.index("_vless.stopVless().timeout(")
assert disconnect.index("_vless.stopVless().timeout(") < disconnect.index("HivemindService.stopSession(markPending: false)")
assert "await CryptoService.setSessionStopPending();" in disconnect

# A failed local stop is an unresolved TUN state, not merely a UI error.
# Server revocation success does not prove the device's VPN engine stopped.
local_failure = disconnect.split("if (localStopFailed) {", 1)[1].split("if (revocationPending) {", 1)[0]
assert local_failure.index("_startGuard.blockUnsafeRestart();") < local_failure.index("_setStatus(VpnStatus.error, 'Shutdown failed');")
assert disconnect.index("final stopResult = await HivemindService.stopSession(markPending: false);") < disconnect.index("if (localStopFailed) {")

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

print("[PASS] Native VPN start completion cannot override disconnect; uncertain local shutdown denies restart and startup health waits for revocation handling.")
