#!/usr/bin/env python3
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"[FAIL] AdMob candidate contract: {message}")


hive = Path("lib/logic/hivemind_service.dart").read_text()
crypto = Path("lib/logic/crypto_service.dart").read_text()
ads = Path("lib/logic/ad_manager.dart").read_text()
h13 = Path("lib/logic/session_activation_service.dart").read_text()
config = Path("lib/logic/app_config.example.dart").read_text()

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
    fail("legacy main reservation guard must exist exactly in debug and production paths")

debug_branch = ads.index("if (!adsEnabled && kDebugMode)")
debug_reserve = ads.index(reserve_call, debug_branch)
debug_callback = ads.index("/admob/callback", debug_branch)
if not debug_branch < debug_reserve < debug_callback:
    fail("debug main candidate must be reserved before callback simulation")
debug_end = ads.index("\n    if (!adsEnabled) return false;", debug_callback)
debug = ads[debug_branch:debug_end]
if debug.count("await HivemindService.cancelSessionCandidate(nonce);") != 2:
    fail("debug reservation must be cleaned on callback rejection and request failure")

production_start = ads.index("await ensureSdkInitialized();")
h13_gate = ads.index("if (AppConfig.h13ActivationEnabled)", production_start)
h13_prepare = ads.index("SessionActivationService.prepare()", h13_gate)
h13_public = ads.index("nonce = prepared.activationId;", h13_prepare)
production_reserve = ads.index(reserve_call, h13_gate)
ssv_options = ads.index("final ssvOptions = ServerSideVerificationOptions(", production_start)
show_call = ads.index("await _rewardedAd!.show(", production_start)
if not production_start < h13_gate < h13_prepare < h13_public < ssv_options < show_call:
    fail("H13 preparation/public correlation must complete before SSV options and ad show")
if not h13_gate < production_reserve < ssv_options:
    fail("legacy production reservation must remain before SSV options")

custom_data = ads[ssv_options:show_call]
if "prepared.sessionSecret" in custom_data or "sessionSecret" in custom_data:
    fail("private H13 session secret must never enter Google-visible custom_data")
if "'nonce': nonce" not in custom_data:
    fail("SSV custom_data lost the selected public correlation value")

cleanup_start = ads.index("Future<void> cleanupUnrewardedMain() async", ssv_options)
cleanup_end = ads.index("\n    try {", cleanup_start)
cleanup = ads[cleanup_start:cleanup_end]
for needle in (
    "SessionActivationService.recoverPendingAbandonment()",
    "HivemindService.cancelSessionCandidate(nonce)",
):
    if needle not in cleanup:
        fail(f"unrewarded cleanup dispatcher is missing: {needle}")

post_show = ads[show_call:]
cleanup_call = "await cleanupUnrewardedMain();"
if post_show.count(cleanup_call) != 2:
    fail("show failure and unearned dismissal must both enter the cleanup dispatcher")
first_cleanup = ads.index(cleanup_call, show_call)
earned = ads.index("final earned = await rewardCompleter.future;", show_call)
second_cleanup = ads.index(cleanup_call, first_cleanup + 1)
h13_confirm = ads.index("SessionActivationService.confirmAndPromote(prepared)", earned)
legacy_confirm = ads.index("HivemindService.confirmAndSetSessionNonce(nonce)", earned)
if not show_call < first_cleanup < earned < second_cleanup < h13_confirm < legacy_confirm:
    fail("cleanup must finish before either H13 or legacy possession promotion")
if cleanup_call in ads[legacy_confirm:]:
    fail("no cleanup may run after possession promotion begins")

for needle in (
    "static const bool h13ActivationEnabled = false;",
    "'h13_pending_session_secret'",
    "'h13_pending_activation_id'",
    "throw const FormatException('Corrupt H13 pending ownership state');",
    "on FormatException",
    "_publicUrl('/session/activation-intents')",
    "_publicUrl('/session/status?device_id=$deviceId')",
    "headers: <String, String>{",
    "_sessionNonceHeader: intent.sessionSecret",
    "HivemindService.setSessionNonce(intent.sessionSecret)",
):
    source = config if needle.startswith("static const bool h13") else h13
    if needle not in source:
        fail(f"H13 cutover invariant is missing: {needle}")

read_start = h13.index("static Future<String?> _readSecret() async")
read_end = h13.index("\n  static Future<void> _clearPending()", read_start)
read_secret = h13[read_start:read_end]
if "_storage.delete" in read_secret:
    fail("corrupt H13 ownership must be retained instead of being silently forgotten")

if "ServerSideVerificationOptions" in h13 or "customData:" in h13:
    fail("H13 capability service must not construct third-party-visible AdMob payloads")

print(
    "[PASS] legacy candidates recover safely, candidate cleanup cannot stop a live entitlement, and default-off H13 keeps private authorization off Google-visible correlation while failing closed on corrupt ownership."
)
