#!/usr/bin/env python3
from pathlib import Path

SERVICE = Path("third_party/flutter_vless_android/android/src/main/kotlin/com/github/tfox/flutter_vless/xray/service/XrayVPNService.kt")
DART = Path("lib/logic/vpn_connection.dart")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


service = SERVICE.read_text()

service = replace_once(
    service,
    "import android.os.ResultReceiver\n",
    "import android.os.ResultReceiver\nimport android.os.SystemClock\n",
    "SystemClock import",
)

service = replace_once(
    service,
    "    @Volatile private var runtimeExpected = false\n    @Volatile private var stopping = false\n",
    "    @Volatile private var runtimeExpected = false\n"
    "    @Volatile private var stopping = false\n"
    "    @Volatile private var recoveringRuntime = false\n"
    "    private var recoveryWindowStartedAtMs = 0L\n"
    "    private var recoveryAttempts = 0\n",
    "recovery fields",
)

service = replace_once(
    service,
    "        if (intent == null) {\n"
    "            terminateService(\"Service restarted without command\")\n"
    "            return START_NOT_STICKY\n"
    "        }\n",
    "        if (intent == null) {\n"
    "            // START_STICKY may recreate a service with a null intent. Killing the\n"
    "            // VPN in that callback turns normal Android process/service recovery\n"
    "            // into a user-visible disconnect. Prefer redelivery for future starts\n"
    "            // and recover from an in-process snapshot when one still exists.\n"
    "            val config = currentConfig ?: AppConfigs.V2RAY_CONFIG\n"
    "            if (config != null && !stopping && startForegroundSafely(\"Restoring secure tunnel…\")) {\n"
    "                val proxyOnly = currentProxyOnly ||\n"
    "                    AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY\n"
    "                Thread { startRuntime(config, proxyOnly) }.start()\n"
    "                return START_REDELIVER_INTENT\n"
    "            }\n"
    "            stopping = true\n"
    "            AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED\n"
    "            AppConfigs.resetReadiness(\"Service restarted without runtime snapshot\")\n"
    "            XrayCoreManager.sendStateBroadcast(this)\n"
    "            stopSelf()\n"
    "            return START_NOT_STICKY\n"
    "        }\n",
    "null-intent lifecycle",
)

service = replace_once(
    service,
    "        return START_STICKY\n    }\n\n    private fun buildStateBundle(): Bundle {",
    "        // If Android has to recreate this foreground VPN service, redeliver the\n"
    "        // START/RESTART intent containing the runtime configuration instead of\n"
    "        // invoking us with a null intent that cannot rebuild the tunnel.\n"
    "        return START_REDELIVER_INTENT\n    }\n\n    private fun buildStateBundle(): Bundle {",
    "service restart mode",
)

service = replace_once(
    service,
    "    private fun failBeforeRuntime(reason: String) {\n"
    "        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED\n"
    "        AppConfigs.resetReadiness(reason)\n"
    "        XrayCoreManager.sendStateBroadcast(this)\n"
    "        stopSelf()\n"
    "    }\n",
    "    private fun failBeforeRuntime(reason: String) {\n"
    "        stopping = true\n"
    "        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED\n"
    "        AppConfigs.resetReadiness(reason)\n"
    "        XrayCoreManager.sendStateBroadcast(this)\n"
    "        stopSelf()\n"
    "    }\n",
    "foreground failure state",
)

service = replace_once(
    service,
    "    private fun startRuntime(config: XrayConfig, proxyOnly: Boolean) {\n"
    "        synchronized(runtimeLock) {\n"
    "            if (stopping) return\n"
    "            val generation = ++currentGeneration\n",
    "    private fun startRuntime(\n"
    "        config: XrayConfig,\n"
    "        proxyOnly: Boolean,\n"
    "        isRecovery: Boolean = false,\n"
    "    ) {\n"
    "        synchronized(runtimeLock) {\n"
    "            if (stopping) return\n"
    "            if (!isRecovery) {\n"
    "                recoveringRuntime = false\n"
    "                recoveryWindowStartedAtMs = 0L\n"
    "                recoveryAttempts = 0\n"
    "            }\n"
    "            currentConfig = config\n"
    "            currentProxyOnly = proxyOnly\n"
    "            val generation = ++currentGeneration\n",
    "startRuntime recovery mode",
)

service = replace_once(
    service,
    "            } catch (e: Exception) {\n"
    "                Log.e(TAG, \"Runtime start failed\", e)\n"
    "                AppConfigs.LAST_ERROR = e.message ?: \"Runtime start failed\"\n"
    "                terminateServiceLocked(AppConfigs.LAST_ERROR, preserveConfig = false)\n"
    "            }\n",
    "            } catch (e: Exception) {\n"
    "                Log.e(TAG, if (isRecovery) \"Runtime recovery failed\" else \"Runtime start failed\", e)\n"
    "                AppConfigs.LAST_ERROR = e.message ?: \"Runtime start failed\"\n"
    "                if (isRecovery) {\n"
    "                    // Keep the foreground service alive while the bounded recovery\n"
    "                    // loop retries. Do not broadcast a transient DISCONNECTED state\n"
    "                    // that would make Flutter clear its recovery snapshot.\n"
    "                    shutdownRuntimeInternal(broadcast = false, keepConfig = true)\n"
    "                    throw e\n"
    "                }\n"
    "                terminateServiceLocked(AppConfigs.LAST_ERROR, preserveConfig = false)\n"
    "            }\n",
    "runtime start failure policy",
)

service = replace_once(
    service,
    "                if (generation == currentGeneration && runtimeExpected && !stopping) {\n"
    "                    Log.e(TAG, \"tun2socks exited unexpectedly with code $code\")\n"
    "                    terminateService(\n"
    "                        \"tun2socks exited unexpectedly\",\n"
    "                        preserveConfig = true,\n"
    "                    )\n"
    "                }\n",
    "                if (generation == currentGeneration && runtimeExpected && !stopping) {\n"
    "                    Log.e(TAG, \"tun2socks exited unexpectedly with code $code\")\n"
    "                    requestRuntimeRecovery(\n"
    "                        \"tun2socks exited unexpectedly with code $code\",\n"
    "                        generation,\n"
    "                    )\n"
    "                }\n",
    "tun2socks exit recovery",
)

service = replace_once(
    service,
    "                if (generation == currentGeneration && runtimeExpected && !stopping) {\n"
    "                    Log.e(TAG, \"tun2socks monitor failed\", e)\n"
    "                    terminateService(\n"
    "                        \"tun2socks monitor failed\",\n"
    "                        preserveConfig = true,\n"
    "                    )\n"
    "                }\n",
    "                if (generation == currentGeneration && runtimeExpected && !stopping) {\n"
    "                    Log.e(TAG, \"tun2socks monitor failed\", e)\n"
    "                    requestRuntimeRecovery(\"tun2socks monitor failed\", generation)\n"
    "                }\n",
    "tun2socks monitor recovery",
)

service = replace_once(
    service,
    "    fun handleXrayCoreExit(generation: Long) {\n"
    "        if (generation != currentGeneration || stopping) return\n"
    "        terminateService(\n"
    "            \"Xray core exited unexpectedly\",\n"
    "            preserveConfig = true,\n"
    "        )\n"
    "    }\n\n"
    "    private fun shutdownRuntimeInternal(broadcast: Boolean, keepConfig: Boolean) {",
    "    fun handleXrayCoreExit(generation: Long) {\n"
    "        if (generation != currentGeneration || stopping) return\n"
    "        requestRuntimeRecovery(\"Xray core exited unexpectedly\", generation)\n"
    "    }\n\n"
    "    private fun requestRuntimeRecovery(reason: String, generation: Long) {\n"
    "        val config: XrayConfig\n"
    "        val proxyOnly: Boolean\n"
    "        synchronized(runtimeLock) {\n"
    "            if (generation != currentGeneration || stopping || !runtimeExpected || recoveringRuntime) return\n"
    "            config = currentConfig ?: AppConfigs.V2RAY_CONFIG ?: run {\n"
    "                terminateServiceLocked(\"$reason; runtime snapshot missing\", preserveConfig = false)\n"
    "                return\n"
    "            }\n"
    "            proxyOnly = currentProxyOnly\n"
    "            recoveringRuntime = true\n"
    "            runtimeExpected = false\n"
    "            AppConfigs.LAST_ERROR = reason\n"
    "            Log.w(TAG, \"Keeping VPN service alive for bounded runtime recovery: $reason\")\n"
    "        }\n\n"
    "        Thread {\n"
    "            var lastFailure = reason\n"
    "            while (true) {\n"
    "                val attempt = synchronized(runtimeLock) {\n"
    "                    if (stopping || !recoveringRuntime) return@Thread\n"
    "                    val now = SystemClock.elapsedRealtime()\n"
    "                    if (recoveryWindowStartedAtMs == 0L ||\n"
    "                        now - recoveryWindowStartedAtMs > RECOVERY_WINDOW_MS\n"
    "                    ) {\n"
    "                        recoveryWindowStartedAtMs = now\n"
    "                        recoveryAttempts = 0\n"
    "                    }\n"
    "                    if (recoveryAttempts >= MAX_RUNTIME_RECOVERY_ATTEMPTS) {\n"
    "                        recoveringRuntime = false\n"
    "                        terminateServiceLocked(\n"
    "                            \"Runtime recovery exhausted: $lastFailure\",\n"
    "                            preserveConfig = true,\n"
    "                        )\n"
    "                        return@Thread\n"
    "                    }\n"
    "                    recoveryAttempts++\n"
    "                    recoveryAttempts\n"
    "                }\n\n"
    "                try {\n"
    "                    Thread.sleep(RECOVERY_BASE_DELAY_MS * attempt)\n"
    "                    startRuntime(config, proxyOnly, isRecovery = true)\n"
    "                    synchronized(runtimeLock) {\n"
    "                        if (!stopping) recoveringRuntime = false\n"
    "                    }\n"
    "                    Log.i(TAG, \"Runtime recovered on attempt $attempt\")\n"
    "                    return@Thread\n"
    "                } catch (e: Exception) {\n"
    "                    lastFailure = e.message ?: \"runtime recovery failed\"\n"
    "                    Log.e(TAG, \"Runtime recovery attempt $attempt failed\", e)\n"
    "                }\n"
    "            }\n"
    "        }.start()\n"
    "    }\n\n"
    "    private fun shutdownRuntimeInternal(broadcast: Boolean, keepConfig: Boolean) {",
    "Xray/runtime bounded recovery",
)

service = replace_once(
    service,
    "    companion object {\n"
    "        private const val TAG = \"XrayVPNService\"\n"
    "        private const val FOREGROUND_SERVICE_TYPE_SPECIAL_USE = 0x40000000\n"
    "    }\n",
    "    companion object {\n"
    "        private const val TAG = \"XrayVPNService\"\n"
    "        private const val FOREGROUND_SERVICE_TYPE_SPECIAL_USE = 0x40000000\n"
    "        private const val MAX_RUNTIME_RECOVERY_ATTEMPTS = 3\n"
    "        private const val RECOVERY_WINDOW_MS = 60_000L\n"
    "        private const val RECOVERY_BASE_DELAY_MS = 450L\n"
    "    }\n",
    "recovery constants",
)

SERVICE.write_text(service)

dart = DART.read_text()
dart = replace_once(
    dart,
    "    _networkSubscription?.cancel();\n"
    "    if (_status == VpnStatus.connected || _status == VpnStatus.connecting) {\n"
    "      unawaited(_vless.stopVless());\n"
    "    }\n"
    "    super.dispose();\n",
    "    _networkSubscription?.cancel();\n"
    "    // Provider/widget lifetime is not the VPN lifetime. Native teardown is\n"
    "    // owned only by explicit disconnect/permission-revoke paths.\n"
    "    super.dispose();\n",
    "Dart dispose must not stop VPN",
)
DART.write_text(dart)

print("Applied ReVoltVPN 3.3.11 self-stop stability fix")
