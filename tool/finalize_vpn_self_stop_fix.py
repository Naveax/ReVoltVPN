#!/usr/bin/env python3
from pathlib import Path

SERVICE = Path("third_party/flutter_vless_android/android/src/main/kotlin/com/github/tfox/flutter_vless/xray/service/XrayVPNService.kt")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


service = SERVICE.read_text()

# QUERY_STATE can create an otherwise-empty service instance and mark it stopping
# while stopSelfResult waits for Android to destroy it. If START_SERVICE arrives
# in that small window, it is a newer start request and must clear that query-only
# stop latch or startRuntime() silently returns without ever building the tunnel.
service = replace_once(
    service,
    "        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE) {\n"
    "            terminateService(\"Stop requested\")\n"
    "            return START_NOT_STICKY\n"
    "        }\n\n"
    "        if (!startForegroundSafely(\"Starting secure tunnel…\")) {",
    "        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE) {\n"
    "            terminateService(\"Stop requested\")\n"
    "            return START_NOT_STICKY\n"
    "        }\n\n"
    "        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE ||\n"
    "            command == AppConfigs.V2RAY_SERVICE_COMMANDS.RESTART_SERVICE\n"
    "        ) {\n"
    "            // A previous QUERY_STATE may have scheduled an empty service\n"
    "            // instance for stop. This newer startId supersedes that query-only\n"
    "            // lifecycle decision, so let the requested runtime actually start.\n"
    "            stopping = false\n"
    "        }\n\n"
    "        if (!startForegroundSafely(\"Starting secure tunnel…\")) {",
    "query stop latch",
)

old_recovery = '''    private fun requestRuntimeRecovery(reason: String, generation: Long) {
        val config: XrayConfig
        val proxyOnly: Boolean
        synchronized(runtimeLock) {
            if (generation != currentGeneration || stopping || !runtimeExpected || recoveringRuntime) return
            config = currentConfig ?: AppConfigs.V2RAY_CONFIG ?: run {
                terminateServiceLocked("$reason; runtime snapshot missing", preserveConfig = false)
                return
            }
            proxyOnly = currentProxyOnly
            recoveringRuntime = true
            runtimeExpected = false
            AppConfigs.LAST_ERROR = reason
            Log.w(TAG, "Keeping VPN service alive for bounded runtime recovery: $reason")
        }

        Thread {
            var lastFailure = reason
            while (true) {
                val attempt = synchronized(runtimeLock) {
                    if (stopping || !recoveringRuntime) return@Thread
                    val now = SystemClock.elapsedRealtime()
                    if (recoveryWindowStartedAtMs == 0L ||
                        now - recoveryWindowStartedAtMs > RECOVERY_WINDOW_MS
                    ) {
                        recoveryWindowStartedAtMs = now
                        recoveryAttempts = 0
                    }
                    if (recoveryAttempts >= MAX_RUNTIME_RECOVERY_ATTEMPTS) {
                        recoveringRuntime = false
                        terminateServiceLocked(
                            "Runtime recovery exhausted: $lastFailure",
                            preserveConfig = true,
                        )
                        return@Thread
                    }
                    recoveryAttempts++
                    recoveryAttempts
                }

                try {
                    Thread.sleep(RECOVERY_BASE_DELAY_MS * attempt)
                    startRuntime(config, proxyOnly, isRecovery = true)
                    synchronized(runtimeLock) {
                        if (!stopping) recoveringRuntime = false
                    }
                    Log.i(TAG, "Runtime recovered on attempt $attempt")
                    return@Thread
                } catch (e: Exception) {
                    lastFailure = e.message ?: "runtime recovery failed"
                    Log.e(TAG, "Runtime recovery attempt $attempt failed", e)
                }
            }
        }.start()
    }
'''

new_recovery = '''    private fun requestRuntimeRecovery(reason: String, generation: Long) {
        var runtimeConfig: XrayConfig? = null
        var proxyOnly = false
        synchronized(runtimeLock) {
            if (generation != currentGeneration || stopping || !runtimeExpected || recoveringRuntime) return
            runtimeConfig = currentConfig ?: AppConfigs.V2RAY_CONFIG
            if (runtimeConfig == null) {
                terminateServiceLocked("$reason; runtime snapshot missing", preserveConfig = false)
                return
            }
            proxyOnly = currentProxyOnly
            recoveringRuntime = true
            runtimeExpected = false
            AppConfigs.LAST_ERROR = reason
            Log.w(TAG, "Keeping VPN service alive for bounded runtime recovery: $reason")
        }

        val config = runtimeConfig ?: return
        Thread recoveryThread@ {
            var lastFailure = reason
            while (true) {
                var attempt = 0
                synchronized(runtimeLock) {
                    if (stopping || !recoveringRuntime) return@recoveryThread
                    val now = SystemClock.elapsedRealtime()
                    if (recoveryWindowStartedAtMs == 0L ||
                        now - recoveryWindowStartedAtMs > RECOVERY_WINDOW_MS
                    ) {
                        recoveryWindowStartedAtMs = now
                        recoveryAttempts = 0
                    }
                    if (recoveryAttempts >= MAX_RUNTIME_RECOVERY_ATTEMPTS) {
                        recoveringRuntime = false
                        terminateServiceLocked(
                            "Runtime recovery exhausted: $lastFailure",
                            preserveConfig = true,
                        )
                        return@recoveryThread
                    }
                    recoveryAttempts++
                    attempt = recoveryAttempts
                }

                try {
                    Thread.sleep(RECOVERY_BASE_DELAY_MS * attempt)
                    startRuntime(config, proxyOnly, isRecovery = true)
                    val recovered = synchronized(runtimeLock) {
                        val ready = !stopping &&
                            runtimeExpected &&
                            AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED
                        if (!stopping) recoveringRuntime = false
                        ready
                    }
                    // Explicit disconnect/revoke can race the recovery sleep. In that
                    // case startRuntime intentionally returns without restarting and
                    // this worker must exit quietly rather than claiming success.
                    if (!recovered) return@recoveryThread
                    Log.i(TAG, "Runtime recovered on attempt $attempt")
                    return@recoveryThread
                } catch (e: Exception) {
                    lastFailure = e.message ?: "runtime recovery failed"
                    Log.e(TAG, "Runtime recovery attempt $attempt failed", e)
                }
            }
        }.start()
    }
'''

service = replace_once(service, old_recovery, new_recovery, "bounded recovery race handling")
SERVICE.write_text(service)
print("Finalized ReVoltVPN 3.3.11 VPN recovery race handling")
