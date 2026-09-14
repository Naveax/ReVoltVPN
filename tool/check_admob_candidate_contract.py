#!/usr/bin/env python3
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"[FAIL] AdMob candidate contract: {message}")


hive = Path("lib/logic/hivemind_service.dart").read_text()
ads = Path("lib/logic/ad_manager.dart").read_text()

method = "static Future<bool> reserveSessionCandidate(String nonce) async"
if hive.count(method) != 1:
    fail("reserveSessionCandidate must exist exactly once")
start = hive.index(method)
end = hive.find("\n  static void cancel()", start)
if end < 0:
    fail("could not bound reserveSessionCandidate")
reserve = hive[start:end]

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

support_start = ads.index("} else {\n      // Support rewards")
support_end = ads.index("\n    // Debug bypass", support_start)
if "reserveSessionCandidate" in ads[support_start:support_end]:
    fail("support reward path must not create a main-session reservation")

print("[PASS] main rewarded-ad paths reserve the exact candidate before callback/show and do not persist possession early.")
