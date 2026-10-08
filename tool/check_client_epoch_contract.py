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
    (ads, "await CryptoService.rotateClientEpochBeforeNewSession();"),
    (timer, "await CryptoService.acknowledgeClientEpochTerminal();"),
    (tests, "failed secure write never creates repeated untracked rotations"),
    (tests, "keeps epoch when a session, candidate or stop remains durable"),
    (evidence, "statusCode == 200"),
    (evidence, "body['active'] == false"),
    (evidence, "body['ok'] == true"),
    (hivemind, "SessionTerminalEvidence.confirmedStopped("),
    (hivemind, "SessionTerminalEvidence.confirmedInactive("),
    (timer, "SessionTerminalEvidence.confirmedInactive("),
    (evidence_tests, "HTTP $code must not authorize rotation"),
]
for source, phrase in required:
    assert phrase in source, f"Missing required client epoch invariant: {phrase}"

# Rotation must be local-only. The public API must not gain a linkable
# old/new epoch mapping or an endpoint for pseudonym exchange.
for source in (hivemind, ads, crypto):
    for forbidden in ("/session/rotate", "old_epoch", "new_epoch"):
        assert forbidden not in source, f"Remote/linkable rotation: {forbidden}"

for label, source in (("stop", hivemind), ("status timer", timer)):
    # A remote 401 is not authenticated Xray teardown evidence: retain the
    # nonce and let retry/backoff/lockdown preserve fail-closed behavior.
    fragment = source.split("} else if (response.statusCode == 401) {", 1)
    assert len(fragment) == 2, f"Missing explicit 401 boundary: {label}"
    guarded = fragment[1].split("}", 1)[0]
    assert "acknowledgeClientEpochTerminal" not in guarded, label
    assert "clearSessionNonce" not in guarded, label

assert epoch.index("await _storage.delete(rotationReadyKey);") < epoch.index(
    "await _storage.write(identityKey, replacement);"
), "Consume the durable marker before publishing the new epoch"

print("[PASS] client epoch rotation requires terminal proof, checks all durable blockers, and has no server-side mapping.")
