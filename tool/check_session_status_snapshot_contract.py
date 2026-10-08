from pathlib import Path

root = Path(__file__).resolve().parents[1]
schema = (root / "lib/logic/session_status_snapshot.dart").read_text(encoding="utf-8")
timer = (root / "lib/logic/session_timer.dart").read_text(encoding="utf-8")
tests = (root / "test/session_status_snapshot_test.dart").read_text(encoding="utf-8")
workflow = (root / ".github/workflows/flutter-strict.yml").read_text(encoding="utf-8")
fence = (root / "lib/logic/session_sync_fence.dart").read_text(encoding="utf-8")
fence_tests = (root / "test/session_sync_fence_test.dart").read_text(encoding="utf-8")

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

for token in ("int _generation = 0", "bool accepts(int generation)", "void invalidate()"):
    assert token in fence, f"Missing epoch fence invariant: {token}"

for test in (
    "a status reply belongs to the generation which requested it",
    "an old reply is rejected after disconnect and subsequent start",
    "later reconnect cannot revive either previous request",
    "same-session concurrent requests retain the same generation",
):
    assert test in fence_tests, f"Missing stale-status regression: {test}"

assert timer.count("_syncFence.invalidate();") >= 3
sync = timer.split("Future<void> _syncWithHivemind() async {", 1)[1].split("void _markSyncFailure()", 1)[0]
assert sync.index("final syncGeneration = _syncFence.current;") < sync.index("await HivemindService.authenticatedGet(url);")
assert sync.index("await HivemindService.authenticatedGet(url);") < sync.index("if (_isDisconnecting || !_syncFence.accepts(syncGeneration)) return;") < sync.index("if (response.statusCode == 200) {")
assert "if (_syncFence.accepts(syncGeneration) && !_isDisconnecting)" in sync

assert "python3 tool/check_session_status_snapshot_contract.py" in workflow
print("[PASS] SessionTimer accepts only fully typed active Rust accounting; malformed and rolled-back counters cannot refresh its watchdog.")
