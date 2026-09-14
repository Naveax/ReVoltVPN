#!/usr/bin/env python3
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"[FAIL] AdMob candidate contract: {message}")


hive = Path("lib/logic/hivemind_service.dart").read_text()
ads = Path("lib/logic/ad_manager.dart").read_text()

reserve_method = "static Future<bool> reserveSessionCandidate(String nonce) async"
if hive.count(reserve_method) != 1:
    fail("reserveSessionCandidate must exist exactly once")
reserve_start = hive.index(reserve_method)
reserve_end = hive.find("\n  static Future<bool> cancelSessionCandidate", reserve_start)
if reserve_end < 0:
    fail("could not bound reserveSessionCandidate")
reserve = hive[reserve_start:reserve_end]

for needle in (
    "RegExp(r'^[0-9a-f]{32}$')",
    "_publicUrl('/session/candidate')",
    "jsonEncode({'device_id': deviceId})",
    "headers: {_sessionNonceHeader: nonce}",
    "response.statusCode != 200",
    "data['ok'] == true",
):
    if needle not in reserve:
        fail(f"reservation method is missing: {needle}")

if "setSessionNonce(" in reserve or "CryptoService.setSessionNonce" in reserve:
    fail("reservation must not persist possession before SSV activation")

cancel_method = "static Future<bool> cancelSessionCandidate(String nonce) async"
if hive.count(cancel_method) != 1:
    fail("cancelSessionCandidate must exist exactly once")
cancel_start = hive.index(cancel_method)
cancel_end = hive.find("\n  static void cancel()", cancel_start)
if cancel_end < 0:
    fail("could not bound cancelSessionCandidate")
cancel = hive[cancel_start:cancel_end]
for needle in (
    "RegExp(r'^[0-9a-f]{32}$')",
    "_publicUrl('/session/stop')",
    "jsonEncode({'device_id': deviceId})",
    "headers: {_sessionNonceHeader: nonce}",
    "response.statusCode != 200",
    "data['ok'] == true",
):
    if needle not in cancel:
        fail(f"candidate cancellation method is missing: {needle}")
if "setSessionNonce(" in cancel or "clearSessionNonce(" in cancel:
    fail("pre-activation cancellation must not mutate persisted possession")

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
    fail("abandoned production main candidate must have exactly two definitive cleanup sites")
first_cleanup = ads.index(cleanup_call, show_call)
earned = ads.index("final earned = await rewardCompleter.future;", show_call)
second_cleanup = ads.index(cleanup_call, first_cleanup + 1)
confirm = ads.index("return HivemindService.confirmAndSetSessionNonce(nonce);", earned)
if not show_call < first_cleanup < earned < second_cleanup < confirm:
    fail("candidate cleanup must cover show failure and unearned dismissal before confirmation")
if cleanup_call in ads[confirm:]:
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
    "[PASS] main reward candidates are reserved before callback/show, abandoned reservations are cancelled only on definitive no-reward paths, and possession is not persisted early."
)
