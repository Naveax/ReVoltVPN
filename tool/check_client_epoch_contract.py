#!/usr/bin/env python3
"""Fail closed if the privacy-v2 client epoch boundary is accidentally removed."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
epoch = (root / "lib/logic/client_epoch_identity.dart").read_text(encoding="utf-8")
crypto = (root / "lib/logic/crypto_service.dart").read_text(encoding="utf-8")
hivemind = (root / "lib/logic/hivemind_service.dart").read_text(encoding="utf-8")
ads = (root / "lib/logic/ad_manager.dart").read_text(encoding="utf-8")
timer = (root / "lib/logic/session_timer.dart").read_text(encoding="utf-8")
evidence = (root / "lib/logic/session_terminal_evidence.dart").read_text(encoding="utf-8")
evidence_tests = (root / "test/session_terminal_evidence_test.dart").read_text(encoding="utf-8")
tests = (root / "test/client_epoch_identity_test.dart").read_text(encoding="utf-8")

required = [
    (epoch, "client_epoch_rotation_ready"),
    (epoch, "session_auth_nonce"),
    (epoch, "pending_session_candidate_nonce"),
    (epoch, "session_stop_pending"),
    (epoch, "await _storage.delete(rotationReadyKey);"),
    (epoch, "await _storage.write(identityKey, replacement);"),
    (epoch, "Future<bool> rotateBeforeNewSession()"),
    (epoch, "Client epoch UUIDv4 generation failed"),
    (epoch, "Missing or invalid old client epoch"),
    (crypto, "FlutterSecureStorage"),
    (crypto, "acknowledgeClientEpochTerminal()"),
    (hivemind, "await CryptoService.acknowledgeClientEpochTerminal();"),
    (hivemind, "return SessionStopResult.retryNeeded;"),
    (crypto, "beginMainSessionCandidate(String nonce)"),
    (epoch, "Future<String?> beginCandidateReservation(String nonce)"),
    (epoch, "await _storage.write(candidateKey, nonce);"),
    (epoch, "synchronizedStorage<T>"),
    (hivemind, "await CryptoService.beginMainSessionCandidate(nonce);"),
    (ads, "reserveSessionCandidate(nonce)"),
    (tests, "atomic admission rotates and owns exactly one candidate"),
    (tests, "stop intent and candidate claim share a serialization gate"),
    (tests, "corrupt durable nonce and candidate still block a new epoch"),
    (epoch, "Future<bool> promoteCandidate(String nonce)"),
    (epoch, "Future<bool> clearCandidateIfMatches(String nonce)"),
    (epoch, "Future<bool> clearStopIntentIfNoOwnership()"),
    (crypto, "promoteSessionCandidate(String nonce)"),
    (crypto, "releaseCandidateIfOwned(String nonce)"),
    (hivemind, "if (!await _promoteAndCacheSessionCandidate(nonce))"),
    (hivemind, "await CryptoService.clearStopIntentIfNoOwnership()"),
    (tests, "cancel and promotion compete without losing a live credential"),
    (tests, "a concurrent stop marker is never erased by promotion"),
    (timer, "await _doDisconnect('Server ended session');"),
    (timer, "await _doDisconnect('Data cap reached');"),
    (hivemind, "final stop = await stopSession();"),
    (tests, "failed secure write never creates repeated untracked rotations"),
    (tests, "reservation write failure retains rotation proof and old epoch"),
    (tests, "marker deletion failure cannot expose retired epoch to new candidate"),
    (tests, "malformed rotation marker blocks main admission and legacy rotation"),
    (tests, "missing epoch with any durable ownership fails closed across restart"),
    (tests, "unowned corrupted stop marker cannot silently disappear"),
    (tests, "missing identity and rejected concurrent admission cannot mint a UUID"),
    (epoch, "Missing client epoch with durable session state"),
    (epoch, "Corrupt client epoch rotation marker"),
    (tests, "keeps epoch when a session, candidate or stop remains durable"),
    (evidence, "statusCode == 200"),
    (evidence, "body['active'] == false"),
    (evidence, "body['ok'] == true"),
    (hivemind, "SessionTerminalEvidence.confirmedStopped("),
    (hivemind, "SessionTerminalEvidence.reportsInactive("),
    (timer, "SessionTerminalEvidence.reportsInactive("),
    (evidence_tests, "HTTP $code must not authorize rotation"),
]
for source, phrase in required:
    assert phrase in source, f"Missing required client epoch invariant: {phrase}"

# Corrupt durable possession/candidate values cannot be safely interpreted, but
# must never be silently deleted: the reservation gate still blocks on them.
for getter, following in (
    ("getSessionNonce()", "clearSessionNonce()"),
    ("getPendingSessionCandidate()", "releaseCandidateIfOwned(String nonce)"),
):
    body = crypto.split("static Future<String?> " + getter, 1)[1].split(
        ("static Future<bool> " if following.startswith("release") else "static Future<void> ") + following, 1
    )[0]
    assert "_storage.delete" not in body, f"Corrupt {getter} must not be discarded"

assert "rotateClientEpochBeforeNewSession" not in ads
assert "rotateClientEpochBeforeNewSession" not in hivemind
assert "setPendingSessionCandidate(String nonce)" not in crypto
assert "clearPendingSessionCandidate()" not in crypto
assert "setSessionNonce(String nonce)" not in crypto
assert "await CryptoService.clearSessionStopPending();" not in hivemind.split("static Future<bool> confirmAndSetSessionNonce", 1)[1].split("static Future<SessionStopResult> stopSession", 1)[0]

# Rotation must be local-only. The public API must not gain a linkable
# old/new epoch mapping or an endpoint for pseudonym exchange.
for source in (hivemind, ads, crypto):
    for forbidden in ("/session/rotate", "old_epoch", "new_epoch"):
        assert forbidden not in source, f"Remote/linkable rotation: {forbidden}"

# Status inactive can be emitted on invalid authorization and fail-closed
# conditions. It is NOT a teardown receipt and cannot directly rotate epochs.
assert "acknowledgeClientEpochTerminal" not in timer
status_probe = hivemind.split("static Future<SessionProbeResult> probeCurrentSession() async", 1)[1]
status_probe = status_probe.split("static Future<bool> confirmAndSetSessionNonce", 1)[0]
assert "await stopSession();" in status_probe
assert "acknowledgeClientEpochTerminal" not in status_probe
assert "clearSessionNonce();" not in status_probe

for label, source in (("stop", hivemind), ("status timer", timer)):
    # A remote 401 is not authenticated Xray teardown evidence: retain the
    # nonce and let retry/backoff/lockdown preserve fail-closed behavior.
    fragment = source.split("} else if (response.statusCode == 401) {", 1)
    assert len(fragment) == 2, f"Missing explicit 401 boundary: {label}"
    guarded = fragment[1].split("}", 1)[0]
    assert "acknowledgeClientEpochTerminal" not in guarded, label
    assert "clearSessionNonce" not in guarded, label

legacy_rotation = epoch.split("Future<bool> rotateBeforeNewSession()", 1)[1]
assert legacy_rotation.index("await _storage.write(identityKey, replacement);") < legacy_rotation.index(
    "await _storage.delete(rotationReadyKey);"
), "Never consume rotation proof before publishing the replacement UUID"

admission = epoch.split("Future<String?> beginCandidateReservation(String nonce)", 1)[1].split(
    "/// Promote the exact server-confirmed candidate", 1
)[0]
assert admission.index("await _storage.write(identityKey, identity);") < admission.index(
    "await _storage.delete(rotationReadyKey);"
) < admission.index("await _storage.write(candidateKey, nonce);")
assert "if (rotationMarker != null && rotationMarker != '1')" in admission

current = epoch.split("Future<String> current()", 1)[1].split("Future<void> acknowledgeTerminal()", 1)[0]
assert current.index("for (final key in [") < current.index("_checkedNewId(null)")
for key in ("sessionNonceKey", "candidateKey", "stopPendingKey", "rotationReadyKey"):
    assert key in current, f"Missing pseudonym must preserve durable {key}"
assert "await _storage.read(key) != null" in current
assert "if (stopRecord != null && stopRecord != '1') return false;" in epoch
assert "await _storage.read(key: _sessionStopPendingPref) != null" in crypto

print("[PASS] client epoch rotation requires terminal proof, checks all durable blockers, and has no server-side mapping.")
