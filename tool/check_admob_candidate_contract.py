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
reserve_end = hive.index(
    "\n  /// Inspect only the exact pre-activation capability lifecycle", reserve_start
)
reserve = hive[reserve_start:reserve_end]
for needle in (
    "_canonicalSessionNonce.hasMatch(nonce)",
    "getPendingSessionCandidate() != null",
    "setPendingSessionCandidate(nonce)",
    "_publicUrl('/session/candidate')",
    "'operation': 'register'",
    "headers: {_sessionNonceHeader: nonce}",
    "response.statusCode == 200",
    "data['ok'] == true",
    "await cancelSessionCandidate(nonce);",
):
    if needle not in reserve:
        fail(f"reservation method is missing: {needle}")

durable_index = reserve.index("await CryptoService.setPendingSessionCandidate(nonce);")
register_index = reserve.index("_publicUrl('/session/candidate')")
cleanup_index = reserve.index("await cancelSessionCandidate(nonce);")
if not durable_index < register_index < cleanup_index:
    fail(
        "candidate ownership must be durable before remote reservation and retained until candidate-only cleanup converges"
    )
if "cancelSessionCandidate(pending)" in reserve:
    fail("reservation must never blindly cancel an older candidate")
if "_cancelSessionCandidateRemote" in reserve:
    fail("reservation failure must go through durable candidate cleanup")
if "setSessionNonce(" in reserve or "CryptoService.setSessionNonce" in reserve:
    fail("reservation must not promote possession before SSV activation")

probe_method = "static Future<CandidateLifecycleState> probeSessionCandidate("
if hive.count(probe_method) != 1:
    fail("candidate lifecycle probe must exist exactly once")
probe_start = hive.index(probe_method)
probe_end = hive.index("\n  /// Converge a durable candidate", probe_start)
probe = hive[probe_start:probe_end]
for needle in (
    "_publicUrl('/session/candidate')",
    "'operation': 'status'",
    "CandidateLifecycleState.pending",
    "CandidateLifecycleState.activating",
    "CandidateLifecycleState.active",
    "CandidateLifecycleState.absent",
    "CandidateLifecycleState.unavailable",
):
    if needle not in probe:
        fail(f"candidate lifecycle probe is missing: {needle}")
if "/session/stop" in probe:
    fail("candidate lifecycle probe must never touch the active stop boundary")

recovery_method = "recoverPendingSessionCandidate() async"
if hive.count(recovery_method) != 1:
    fail("pending candidate recovery must exist exactly once")
recovery_start = hive.index("static Future<PendingCandidateRecovery>", probe_end)
recovery_end = hive.index(
    "\n  /// Cancel a reservation through the candidate-only", recovery_start
)
recovery = hive[recovery_start:recovery_end]
for needle in (
    "getPendingSessionCandidate()",
    "probeSessionCandidate(pending)",
    "confirmAndSetSessionNonce(pending)",
    "clearPendingSessionCandidate()",
    "PendingCandidateRecovery.active",
    "PendingCandidateRecovery.none",
    "PendingCandidateRecovery.unresolved",
):
    if needle not in recovery:
        fail(f"pending candidate recovery is missing: {needle}")
if "cancelSessionCandidate(" in recovery:
    fail("ambiguous delayed-SSV recovery must not cancel the candidate")

cancel_method = "static Future<bool> cancelSessionCandidate(String nonce) async"
if hive.count(cancel_method) != 1:
    fail("cancelSessionCandidate must exist exactly once")
cancel_start = hive.index(cancel_method)
cancel_end = hive.index(
    "\n  static Future<bool> _cancelSessionCandidateRemote", cancel_start
)
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
    "_publicUrl('/session/candidate')",
    "'operation': 'cancel'",
    "headers: {_sessionNonceHeader: nonce}",
    "response.statusCode != 200",
    "data['ok'] == true",
):
    if needle not in remote:
        fail(f"remote candidate cancellation is missing: {needle}")
if "/session/stop" in remote:
    fail("candidate cleanup must not use the live-session stop endpoint")

confirm_start = hive.index("static Future<bool> confirmAndSetSessionNonce")
confirm_end = hive.index("\n  static Future<SessionStopResult> stopSession", confirm_start)
confirm = hive[confirm_start:confirm_end]
if confirm.count("getPendingSessionCandidate()") < 2:
    fail("confirmation must verify durable candidate ownership before and at promotion")
if "await setSessionNonce(nonce);" not in confirm:
    fail("confirmed candidate is not promoted to active possession")

main_start = ads.index("if (adType == 'main') {")
recovery_call = ads.index(
    "await HivemindService.recoverPendingSessionCandidate()", main_start
)
probe_current = ads.index("await HivemindService.probeCurrentSession()", main_start)
new_nonce = ads.index("HivemindService.newNonce()", main_start)
if not main_start < recovery_call < probe_current < new_nonce:
    fail(
        "main flow must recover an older exact candidate before probing/minting a new generation"
    )
for needle in (
    "PendingCandidateRecovery.active",
    "PendingCandidateRecovery.unresolved",
):
    if needle not in ads[recovery_call:new_nonce]:
        fail(f"main recovery branch is missing: {needle}")

reserve_call = "!await HivemindService.reserveSessionCandidate(nonce)"
if ads.count(reserve_call) != 2:
    fail("main reservation guard must exist exactly in debug and production paths")

debug_branch = ads.index("if (!adsEnabled && kDebugMode)")
debug_reserve = ads.index(reserve_call, debug_branch)
debug_callback = ads.index("/admob/callback", debug_branch)
if not debug_branch < debug_reserve < debug_callback:
    fail("debug main candidate must be reserved before callback simulation")

production_start = ads.index("await ensureSdkInitialized();")
production_reserve = ads.index(reserve_call, production_start)
ssv_options = ads.index("final ssvOptions = ServerSideVerificationOptions(", production_start)
show_call = ads.index("await _rewardedAd!.show(", production_start)
if not production_start < production_reserve < ssv_options < show_call:
    fail("production main candidate must be reserved before SSV options and ad show")

cleanup_call = "await HivemindService.cancelSessionCandidate(nonce);"
production = ads[show_call:]
if production.count(cleanup_call) != 2:
    fail("production main candidate must have exactly two definitive no-reward cleanup sites")
first_cleanup = ads.index(cleanup_call, show_call)
earned = ads.index("final earned = await rewardCompleter.future;", show_call)
second_cleanup = ads.index(cleanup_call, first_cleanup + 1)
confirm_call = ads.index(
    "return HivemindService.confirmAndSetSessionNonce(nonce);", earned
)
if not show_call < first_cleanup < earned < second_cleanup < confirm_call:
    fail(
        "candidate cleanup must cover show failure and unearned dismissal before confirmation"
    )
if cleanup_call in ads[confirm_call:]:
    fail("candidate must not be cancelled after a locally earned reward enters SSV confirmation")

support_start = ads.index("} else {\n      // Support rewards")
support_end = ads.index("\n    // Debug bypass", support_start)
if "reserveSessionCandidate" in ads[support_start:support_end]:
    fail("support reward path must not create a main-session reservation")

compat_start = hive.index("static Future<String> fetchConfigDirectly")
compat_end = hive.index("\n  static Future<bool> checkHealth()", compat_start)
compat = hive[compat_start:compat_end]
compat_recovery = compat.find("await recoverPendingSessionCandidate()")
compat_reserve = compat.find("await reserveSessionCandidate(candidate)")
compat_callback = compat.find("/admob/callback")
if min(compat_recovery, compat_reserve, compat_callback) < 0:
    fail("debug compatibility path lost recovery/reservation/callback stages")
if not compat_recovery < compat_reserve < compat_callback:
    fail("debug compatibility must recover old candidate before reserving a new one")

print(
    "[PASS] main reward candidates are durably owned before remote reservation, recovered before remint, candidate cleanup cannot stop a live entitlement, and promotion remains gated on exact active SSV state."
)
