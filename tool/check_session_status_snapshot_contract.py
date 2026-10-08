from pathlib import Path

root = Path(__file__).resolve().parents[1]
schema = (root / "lib/logic/session_status_snapshot.dart").read_text(encoding="utf-8")
timer = (root / "lib/logic/session_timer.dart").read_text(encoding="utf-8")
tests = (root / "test/session_status_snapshot_test.dart").read_text(encoding="utf-8")
workflow = (root / ".github/workflows/flutter-strict.yml").read_text(encoding="utf-8")
fence = (root / "lib/logic/session_sync_fence.dart").read_text(encoding="utf-8")
fence_tests = (root / "test/session_sync_fence_test.dart").read_text(encoding="utf-8")
stop_barrier = (root / "lib/logic/session_stop_barrier.dart").read_text(encoding="utf-8")
stop_tests = (root / "test/session_stop_barrier_test.dart").read_text(encoding="utf-8")

for token in (
    "body is! Map<String, dynamic>",
    "body['active'] != true",
    "remaining is! int",
    "used is! int",
    "cap is! int",
    "exhausted is! bool",
    "remaining < 0",
    "used < 0",
    "cap <= 0",
    "remainingSeconds == 0 || capExhausted || usedBytes >= hardCapBytes",
):
    assert token in schema, f"Missing required status contract: {token}"

for token in (
    "SessionStatusSnapshot.parseActive(data)",
    "(_hasSyncedOnce && snapshot.usedBytes < _usedBytes)",
    "_markSyncFailure();",
    "if (snapshot.mustStop)",
    "_remainingSeconds = snapshot.remainingSeconds;",
    "_usedBytes = snapshot.usedBytes;",
    "_lastUsedBytes = snapshot.usedBytes;",
    "if (data is! Map<String, dynamic> || data['active'] is! bool)",
):
    assert token in timer, f"Missing status sync gate: {token}"

start = timer.split("final snapshot = SessionStatusSnapshot.parseActive(data);", 1)[1]
assert start.index("if (snapshot == null") < start.index("_remainingSeconds = snapshot.remainingSeconds;")
assert start.index("if (snapshot.mustStop)") < start.index("_remainingSeconds = snapshot.remainingSeconds;")
assert "data['expires_in_seconds'] ??" not in timer
assert "data['used_bytes'] ??" not in timer
assert "data['cap_exhausted'] ??" not in timer

for test in (
    "accepts full Rust active status with strict integer counters",
    "rejects active payload with missing required accounting fields",
    "rejects non-object and inactive payloads",
    "rejects fractional, string and null counters",
    "rejects negative expiry and bytes and nonpositive cap",
    "cap-exhaustion field must be a boolean",
    "zero expiry triggers stop regardless of cap flag",
    "used byte count equal to or exceeding hard cap triggers stop",
):
    assert test in tests, f"Missing accounting regression: {test}"

for token in ("int _generation = 0", "bool accepts(int generation)", "void invalidate()", "int? beginRequest()", "void finishRequest(int generation)", "_inFlightGeneration = null;"):
    assert token in fence, f"Missing epoch fence invariant: {token}"

for test in (
    "a status reply belongs to the generation which requested it",
    "an old reply is rejected after disconnect and subsequent start",
    "later reconnect cannot revive either previous request",
    "same-session concurrent requests retain the same generation",
    "same session permits only one active status request",
    "new session can poll while old HTTP request remains unresolved",
    "old HTTP completion never releases new session request slot",
    "two invalidations retire every earlier HTTP generation",
    "old identity preflight cannot dispatch status for a new session",
):
    assert test in fence_tests, f"Missing stale-status regression: {test}"

assert timer.count("_syncFence.invalidate();") >= 3
sync = timer.split("Future<void> _syncWithHivemind() async {", 1)[1].split("void _markSyncFailure()", 1)[0]
assert "_syncInProgress" not in timer
assert sync.index("final syncGeneration = _syncFence.beginRequest();") < sync.index("if (syncGeneration == null) return;") < sync.index("await HivemindService.authenticatedGet(url);")
assert "_syncFence.finishRequest(syncGeneration);" in sync
assert "if (_disposed || _isDisconnecting || !_syncFence.accepts(syncGeneration))" in sync
assert "if (!_disposed &&" in sync
assert "_syncFence.accepts(syncGeneration) &&" in sync
assert "!_isDisconnecting) {" in sync
assert "_notifyIfAlive();" in timer
assert "if (!_disposed) notifyListeners();" in timer
assert "_disposed = true;" in timer.split("void dispose() {", 1)[1]
assert "_syncFence.invalidate();" in timer.split("void dispose() {", 1)[1]
preflight_check = "if (_disposed ||\\n          _isDisconnecting ||\\n          !_syncFence.accepts(syncGeneration)) {".replace("\\n", "\n")
response_check = "if (_disposed || _isDisconnecting || !_syncFence.accepts(syncGeneration))"
assert preflight_check in sync
assert response_check in sync
assert sync.index("await CryptoService.getDeviceId();") < sync.index(preflight_check) < sync.index("await HivemindService.authenticatedGet(url);")
assert sync.index("await HivemindService.authenticatedGet(url);") < sync.index(response_check) < sync.index("if (response.statusCode == 200) {")

for token in (
    "Future<void>? _pending;",
    "bool get isStopping => _pending != null;",
    "final existing = _pending;",
    "if (existing != null) return existing;",
    "Future<void>.sync(stop)",
    "final completer = Completer<void>();",
    "_pending = future;",
    "if (identical(_pending, future)) _pending = null;",
    "completer.completeError(error, stack);",
):
    assert token in stop_barrier, f"Missing shared teardown barrier: {token}"

for test in (
    "concurrent disconnect callers share one pending teardown",
    "a failed teardown rejects all waiters and clears the barrier",
    "a synchronous native exception is an observable stop error",
    "a subsequent stop cannot overlap the previous pending future",
    "synchronous listener reentrancy cannot start a second stop",
    "synchronous reentrant failure is propagated to all callers",
):
    assert test in stop_tests, f"Missing stop serialization regression: {test}"

assert stop_barrier.index("_pending = future;") < stop_barrier.index("Future<void>.sync(stop)")
assert "final SessionStopBarrier _stopBarrier = SessionStopBarrier();" in timer
session_start = timer.split("Future<void> start() async {", 1)[1].split("void _tick(", 1)[0]
assert "_stopBarrier.isStopping ||" in session_start
assert "vpnConnection.status != VpnStatus.connected) return;" in session_start
restore = timer.split("void _onVpnConnectionChanged() {", 1)[1].split("Future<void> start()", 1)[0]
assert "!_stopBarrier.isStopping &&" in restore
assert "!_isDisconnecting &&" in restore
resume = timer.split("void _resumeTicking() {", 1)[1].split("void _notifyIfAlive()", 1)[0]
assert "_stopBarrier.isStopping ||" in resume
assert "vpnConnection.status != VpnStatus.connected) return;" in resume
stop = timer.split("Future<void> _doDisconnect(String reason)", 1)[1].split("Future<void> _syncWithHivemind()", 1)[0]
assert "_stopBarrier.run(() async" in stop
assert "await vpnConnection.disconnect();" in stop
assert "finally {" in stop
assert "_isDisconnecting = false;" in stop
assert "_requestDisconnect(String reason)" in stop
assert "unawaited(_doDisconnect(reason).then<void>" in stop
assert "_doDisconnect(String reason) async" not in timer

assert "python3 tool/check_session_status_snapshot_contract.py" in workflow
print("[PASS] SessionTimer accepts only fully typed active Rust accounting; malformed and rolled-back counters cannot refresh its watchdog.")
