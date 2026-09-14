#!/usr/bin/env python3
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"[FAIL] AdMob candidate contract: {message}")


hive = Path("lib/logic/hivemind_service.dart").read_text()
crypto = Path("lib/logic/crypto_service.dart").read_text()
ads = Path("lib/logic/ad_manager.dart").read_text()

for needle in (
    "_pendingSessionCandidatePref",
    "setPendingSessionCandidate(String nonce)",
    "getPendingSessionCandidate()",
    "clearPendingSessionCandidate()",
    "await _storage.write(key: _sessionNoncePref, value: nonce);",
    "await _storage.delete(key: _pendingSessionCandidatePref);",
):
    if needle not in crypto:
        fail(f"durable pending-candidate storage is missing: {needle}")

reserve_method = "static Future<bool> reserveSessionCandidate(String nonce) async"
if hive.count(reserve_method) != 1:
    fail("reserveSessionCandidate must exist exactly once")
reserve_start = hive.index(reserve_method)
reserve_end = hive.find("\n  /// Cancel an exact pre-activation reservation", reserve_start)
if reserve_end < 0:
    fail("could not bound reserveSessionCandidate")
reserve = hive[reserve_start:reserve_end]

for needle in (
    "_canonicalSessionNonce.hasMatch(nonce)",
    "getPendingSessionCandidate()",
    "cancelSessionCandidate(pending)",
    "_publicUrl('/session/candidate')",
    "jsonEncode({'device_id': deviceId})",
    "headers: {_sessionNonceHeader: nonce}",
    "response.statusCode != 200",
    "data['ok'] != true",
    "setPendingSessionCandidate(nonce)",
    "_cancelSessionCandidateRemote(deviceId, nonce)",
):
    if needle not in reserve:
        fail(f"reservation method is missing: {needle}")

if "setSessionNonce(" in reserve or "CryptoService.setSessionNonce" in reserve:
    fail("reservation must not promote possession before SSV activation")

cancel_method = "static Future<bool> cancelSessionCandidate(String nonce) async"
if hive.count(cancel_method) != 1:
    fail("cancelSessionCandidate must exist exactly once")
cancel_start = hive.index(cancel_method)
cancel_end = hive.find("\n  static Future<bool> retryPendingSessionCandidateCleanup", cancel_start)
if cancel_end < 0:
    fail("could not bound cancelSessionCandidate")
cancel = hive[cancel_start:cancel_end]
for needle in (
    "_canonicalSessionNonce.hasMatch(nonce)",
    "_cancelSessionCandidateRemote(deviceId, nonce)",
    "getPendingSessionCandidate()",
    "clearPendingSessionCandidate()",
):
    if needle not in cancel:
        fail(f"candidate cancellation method is missing: {needle}")
if "setSessionNonce(" in cancel or "clearSessionNonce(" in cancel:
    fail("pre-activation cancellation must not mutate active possession")

remote_start = hive.index("static Future<bool> _cancelSessionCandidateRemote")
remote_end = hive.index("\n  static void cancel()", remote_start)
remote = hive[remote_start:remote_end]
for needle in (
    "_publicUrl('/session/stop')",
    "jsonEncode({'device_id': deviceId})",
    "headers: {_sessionNonceHeader: nonce}",
    "response.statusCode != 200",
    "data['ok'] == true",
):
    if needle not in remote:
        fail(f"remote candidate cancellation is missing: {needle}")

confirm_start = hive.index("static Future<bool> confirmAndSetSessionNonce")
confirm_end = hive.index("\n  static Future<SessionStopResult> stopSession", confirm_start)
confirm = hive[confirm_start:confirm_end]
if confirm.count("getPendingSessionCandidate()") < 2:
    fail("confirmation must verify durable candidate ownership before and at promotion")
if "await setSessionNonce(nonce);" not in confirm:
    fail("confirmed candidate is not promoted to active possession")

call = "!await HivemindService.reserveSessionCandidate(nonce)"
if ads.count(call) != 2:
    fail("main reservation guard must exist exactly in debug and production paths")

debug_branch = ads.index("if (!adsEnabled && kDebugMode)")
debug_reserve = ads.index(call, debug_branch)
debug_callback = ads.index("/admob/callback", debug_branch)
if not debug_branch < debug_reserve < debug_callback:
    fail("debug main candidate must be reserved before callback simulation")

production_start = ads.index("await ensureSdkInitialized();")
production_reserve = ads.index(call, production_start)
ssv_options = ads.index("final ssvOptions = ServerSideVerificationOptions(", production_start)
show_call = ads.index("await _rewardedAd!.show(", production_start)
if not production_start < production_reserve < ssv_options < show_call:
    fail("production main candidate must be reserved before SSV options and ad show")

cleanup_call = "await HivemindService.cancelSessionCandidate(nonce);"
if ads.count(cleanup_call) != 2:
    fail("abandoned production main candidate must have exactly two cleanup attempts")
first_cleanup = ads.index(cleanup_call, show_call)
earned = ads.index("final earned = await rewardCompleter.future;", show_call)
second_cleanup = ads.index(cleanup_call, first_cleanup + 1)
confirm_call = ads.index("return HivemindService.confirmAndSetSessionNonce(nonce);", earned)
if not show_call < first_cleanup < earned < second_cleanup < confirm_call:
    fail("candidate cleanup must cover show failure and unearned dismissal before confirmation")
if cleanup_call in ads[confirm_call:]:
    fail("candidate must not be cancelled after a locally earned reward enters SSV confirmation")

support_start = ads.index("} else {\n      // Support rewards")
support_end = ads.index("\n    // Debug bypass", support_start)
if "reserveSessionCandidate" in ads[support_start:support_end]:
    fail("support reward path must not create a main-session reservation")

compat_start = hive.index("static Future<String> fetchConfigDirectly")
compat_end = hive.index("\n  static Future<bool> checkHealth()", compat_start)
compat = hive[compat_start:compat_end]
compat_reserve = compat.find("await reserveSessionCandidate(candidate)")
compat_callback = compat.find("/admob/callback")
if compat_reserve < 0 or compat_callback < 0 or compat_reserve > compat_callback:
    fail("debug compatibility candidate must be reserved before callback simulation")

print(
    "[PASS] main reward candidates are durably owned before callback/show, orphan cleanup fails closed across restart, and promotion remains gated on exact active SSV state."
)
