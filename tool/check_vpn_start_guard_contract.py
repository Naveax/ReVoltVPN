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
    (tests, "cancel during native start cannot report connected"),
    (tests, "timed out native start stays blocked through deferred cleanup"),
    (tests, "failed deferred native stop denies reconnection"),
    (workflow, "python3 tool/check_vpn_start_guard_contract.py"),
]
for source, token in required:
    assert token in source, f"Missing native VPN start/stop invariant: {token}"

connect = vpn.split("Future<bool> _connectInner(", 1)[1].split("Future<void> disconnect()", 1)[0]
assert connect.count("_vless.startVless(") == 1
assert "_startGuard.start(() => _vless.startVless(" in connect
assert connect.index("if (!started || _cancelled) return false;") < connect.index("_setStatus(VpnStatus.connected, 'Secured');")
disconnect = vpn.split("Future<void> disconnect()", 1)[1].split("void _setStatus(", 1)[0]
assert disconnect.index("_startGuard.cancel();") < disconnect.index("CryptoService.setSessionStopPending();")
assert disconnect.index("_startGuard.waitForStart(") < disconnect.index("_vless.stopVless().timeout(")
assert disconnect.index("_vless.stopVless().timeout(") < disconnect.index("HivemindService.stopSession(markPending: false)")
assert "await CryptoService.setSessionStopPending();" in disconnect

print("[PASS] Native VPN start completion cannot override disconnect; late native stop is tracked and reconnect fails closed.")
