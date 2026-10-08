#!/usr/bin/env python3
"""Fail closed if the privacy-v2 client epoch boundary is accidentally removed."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
epoch = (root / "lib/logic/client_epoch_identity.dart").read_text(encoding="utf-8")
crypto = (root / "lib/logic/crypto_service.dart").read_text(encoding="utf-8")
hivemind = (root / "lib/logic/hivemind_service.dart").read_text(encoding="utf-8")
ads = (root / "lib/logic/ad_manager.dart").read_text(encoding="utf-8")
timer = (root / "lib/logic/session_timer.dart").read_text(encoding="utf-8")
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
]
for source, phrase in required:
    assert phrase in source, f"Missing required client epoch invariant: {phrase}"

# Rotation must be local-only. The public API must not gain a linkable
# old/new epoch mapping or an endpoint for pseudonym exchange.
for source in (hivemind, ads, crypto):
    for forbidden in ("/session/rotate", "old_epoch", "new_epoch"):
        assert forbidden not in source, f"Remote/linkable rotation: {forbidden}"

assert epoch.index("await _storage.delete(rotationReadyKey);") < epoch.index(
    "await _storage.write(identityKey, replacement);"
), "Consume the durable marker before publishing the new epoch"

print("[PASS] client epoch rotation requires terminal proof, checks all durable blockers, and has no server-side mapping.")
