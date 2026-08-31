from pathlib import Path

ROOT = Path('.')
SERVICE = ROOT / 'third_party/flutter_vless_android/android/src/main/kotlin/com/github/tfox/flutter_vless/xray/service/XrayVPNService.kt'
CORE = ROOT / 'third_party/flutter_vless_android/android/src/main/kotlin/com/github/tfox/flutter_vless/xray/core/XrayCoreManager.kt'
PLUGIN = ROOT / 'third_party/flutter_vless_android/android/src/main/kotlin/com/github/tfox/flutter_vless/FlutterVlessPlugin.kt'
LOGGER = ROOT / 'third_party/flutter_vless_android/android/src/main/kotlin/com/github/tfox/flutter_vless/xray/utils/VpnDiagnosticLog.kt'
DIAG_DART = ROOT / 'lib/screens/settings/in_settings/vpn_diagnostics.dart'
SETTINGS = ROOT / 'lib/screens/settings/settings_screen.dart'


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    if new in text:
        print(f'[already] {label}')
        return
    if old not in text:
        raise SystemExit(f'{label}: expected source block not found in {path}')
    path.write_text(text.replace(old, new, 1))
    print(f'[ok] {label}')


LOGGER.parent.mkdir(parents=True, exist_ok=True)
LOGGER.write_text(r'''package com.github.tfox.flutter_vless.xray.utils

import android.content.Context
import android.os.Process
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object VpnDiagnosticLog {
    private const val TAG = "ReVoltVpnDiag"
    private const val FILE_NAME = "revolt_vpn_diagnostics.log"
    private const val MAX_BYTES = 1024 * 1024L
    private val lock = Any()
    private val formatter = ThreadLocal.withInitial {
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)
    }

    private fun logFile(context: Context) = File(context.filesDir, FILE_NAME)

    private fun sanitize(value: String): String {
        var out = value
        out = out.replace(Regex("socks5://[^@\\s]+@"), "socks5://<redacted>@")
        out = out.replace(Regex("(?i)(SOCKS_(?:USER|PASS)|password|passwd|token|uuid|id)=([^\\s,;]+)"), "$1=<redacted>")
        if (out.length > 6000) out = out.take(6000) + " …<truncated>"
        return out
    }

    fun write(context: Context, component: String, message: String, error: Throwable? = null) {
        synchronized(lock) {
            try {
                val file = logFile(context)
                if (file.exists() && file.length() > MAX_BYTES) {
                    val old = File(context.filesDir, "$FILE_NAME.old")
                    try { old.delete() } catch (_: Exception) {}
                    if (!file.renameTo(old)) file.writeText("")
                }
                val ts = formatter.get().format(Date())
                val line = "$ts pid=${Process.myPid()} thread=${Thread.currentThread().name} [$component] ${sanitize(message)}"
                file.appendText(line + "\n")
                if (error != null) {
                    file.appendText(sanitize(Log.getStackTraceString(error)) + "\n")
                }
                Log.i(TAG, line)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to persist VPN diagnostic log", e)
            }
        }
    }

    fun read(context: Context): String = synchronized(lock) {
        try {
            val old = File(context.filesDir, "$FILE_NAME.old")
            val current = logFile(context)
            buildString {
                if (old.exists()) {
                    append("===== PREVIOUS ROLL =====\n")
                    append(old.readText())
                    append("\n===== CURRENT =====\n")
                }
                if (current.exists()) append(current.readText())
            }
        } catch (e: Exception) {
            "Could not read diagnostic log: ${e.message}"
        }
    }

    fun clear(context: Context) = synchronized(lock) {
        try { logFile(context).delete() } catch (_: Exception) {}
        try { File(context.filesDir, "$FILE_NAME.old").delete() } catch (_: Exception) {}
    }
}
''')
print('[ok] wrote native diagnostic logger')

replace_once(PLUGIN, 'import com.github.tfox.flutter_vless.xray.utils.TunnelStateStore\n', 'import com.github.tfox.flutter_vless.xray.utils.TunnelStateStore\nimport com.github.tfox.flutter_vless.xray.utils.VpnDiagnosticLog\n', 'plugin logger import')
replace_once(PLUGIN, '        context = binding.applicationContext\n        vpnControlMethod = MethodChannel(binding.binaryMessenger, "flutter_vless")\n', '        context = binding.applicationContext\n        VpnDiagnosticLog.write(context, "PLUGIN", "onAttachedToEngine")\n        vpnControlMethod = MethodChannel(binding.binaryMessenger, "flutter_vless")\n', 'plugin attach log')
replace_once(PLUGIN, '    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {\n        when (call.method) {\n', '    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {\n        VpnDiagnosticLog.write(context, "METHOD", "call=${call.method}")\n        when (call.method) {\n', 'method call log')
replace_once(PLUGIN, '            "stopVless" -> {\n                val intent = Intent(context, XrayVPNService::class.java)\n', '            "stopVless" -> {\n                VpnDiagnosticLog.write(context, "METHOD", "STOP requested by Flutter")\n                val intent = Intent(context, XrayVPNService::class.java)\n', 'explicit stop log')
replace_once(PLUGIN, '            "getTunnelState" -> result.success(TunnelStateStore.read(context))\n', '''            "getTunnelState" -> {
                val state = TunnelStateStore.read(context)
                VpnDiagnosticLog.write(context, "STATE_READ", state.toString())
                result.success(state)
            }
            "getDiagnosticLog" -> result.success(VpnDiagnosticLog.read(context))
            "clearDiagnosticLog" -> {
                VpnDiagnosticLog.clear(context)
                VpnDiagnosticLog.write(context, "DIAG", "diagnostic log cleared")
                result.success(true)
            }
            "appendDiagnosticLog" -> {
                val component = call.argument<String>("component") ?: "DART"
                val message = call.argument<String>("message") ?: ""
                VpnDiagnosticLog.write(context, component, message)
                result.success(true)
            }
''', 'diagnostic method channel APIs')
replace_once(PLUGIN, '        val proxyOnly = call.argument<Boolean>("proxy_only") == true\n        AppConfigs.V2RAY_CONNECTION_MODE = if (proxyOnly) {\n', '        val proxyOnly = call.argument<Boolean>("proxy_only") == true\n        VpnDiagnosticLog.write(context, "START", "startVless proxyOnly=$proxyOnly allowed=${config.ALLOWED_APPS.size} blocked=${config.BLOCKED_APPS.size}")\n        AppConfigs.V2RAY_CONNECTION_MODE = if (proxyOnly) {\n', 'startVless summary log')
replace_once(PLUGIN, '                    vpnStatusSink?.success(data)\n', '''                    VpnDiagnosticLog.write(
                        context,
                        "STATUS",
                        "event state=$lastState tun=$lastTunEstablished fd=$lastFdDelivered socks=$lastSocksReady gen=$lastGeneration error=$lastError"
                    )
                    vpnStatusSink?.success(data)
''', 'status event log')
replace_once(PLUGIN, '    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {\n        unregisterReceiver()\n', '    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {\n        VpnDiagnosticLog.write(context, "PLUGIN", "onDetachedFromEngine")\n        unregisterReceiver()\n', 'plugin detach log')

replace_once(SERVICE, 'import com.github.tfox.flutter_vless.xray.utils.AppConfigs\n', 'import com.github.tfox.flutter_vless.xray.utils.AppConfigs\nimport com.github.tfox.flutter_vless.xray.utils.VpnDiagnosticLog\n', 'service logger import')
replace_once(SERVICE, '    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {\n        if (intent == null) {\n', '    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {\n        VpnDiagnosticLog.write(this, "SERVICE", "onStartCommand startId=$startId flags=$flags intentNull=${intent == null}")\n        if (intent == null) {\n', 'service command entry log')
replace_once(SERVICE, '        // Tunnel readiness lives in this remote VpnService process. Answer state\n', '        VpnDiagnosticLog.write(this, "SERVICE", "command=$command state=${AppConfigs.V2RAY_STATE} gen=$currentGeneration stopping=$stopping runtimeExpected=$runtimeExpected")\n\n        // Tunnel readiness lives in this remote VpnService process. Answer state\n', 'parsed command log')
replace_once(SERVICE, '    private fun failBeforeRuntime(reason: String) {\n        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED\n', '    private fun failBeforeRuntime(reason: String) {\n        VpnDiagnosticLog.write(this, "FAIL", "failBeforeRuntime: $reason")\n        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED\n', 'pre-runtime fail log')
replace_once(SERVICE, '    private fun startRuntime(config: XrayConfig, proxyOnly: Boolean) {\n        synchronized(runtimeLock) {\n            if (stopping) return\n            val generation = ++currentGeneration\n', '    private fun startRuntime(config: XrayConfig, proxyOnly: Boolean) {\n        VpnDiagnosticLog.write(this, "RUNTIME", "startRuntime entered proxyOnly=$proxyOnly currentGen=$currentGeneration stopping=$stopping")\n        synchronized(runtimeLock) {\n            if (stopping) {\n                VpnDiagnosticLog.write(this, "RUNTIME", "startRuntime aborted because stopping=true")\n                return\n            }\n            val generation = ++currentGeneration\n            VpnDiagnosticLog.write(this, "RUNTIME", "generation allocated=$generation")\n', 'runtime start logs')
replace_once(SERVICE, '            shutdownRuntimeInternal(broadcast = false, keepConfig = true)\n            prepareRuntimeIsolation(config)\n', '            VpnDiagnosticLog.write(this, "RUNTIME", "pre-start shutdown begin")\n            shutdownRuntimeInternal(broadcast = false, keepConfig = true)\n            VpnDiagnosticLog.write(this, "RUNTIME", "pre-start shutdown complete")\n            prepareRuntimeIsolation(config)\n            VpnDiagnosticLog.write(this, "RUNTIME", "isolation prepared socksPort=${config.LOCAL_SOCKS5_PORT}")\n', 'pre-start cleanup logs')
replace_once(SERVICE, '                if (!XrayCoreManager.startCore(this, config, generation)) {\n                    throw IllegalStateException(AppConfigs.LAST_ERROR.ifEmpty { "Xray failed to start" })\n                }\n', '                VpnDiagnosticLog.write(this, "RUNTIME", "starting Xray gen=$generation")\n                if (!XrayCoreManager.startCore(this, config, generation)) {\n                    throw IllegalStateException(AppConfigs.LAST_ERROR.ifEmpty { "Xray failed to start" })\n                }\n                VpnDiagnosticLog.write(this, "RUNTIME", "Xray alive after startup probe gen=$generation")\n', 'xray startup logs')
replace_once(SERVICE, '                setupVpn(config, generation)\n                runtimeExpected = true\n', '                VpnDiagnosticLog.write(this, "RUNTIME", "setupVpn begin gen=$generation")\n                setupVpn(config, generation)\n                VpnDiagnosticLog.write(this, "RUNTIME", "setupVpn complete gen=$generation")\n                runtimeExpected = true\n', 'setupVpn boundary logs')
replace_once(SERVICE, '                if (!XrayCoreManager.markConnected(this, config, generation)) {\n                    throw IllegalStateException("Native readiness state was incomplete")\n                }\n', '                if (!XrayCoreManager.markConnected(this, config, generation)) {\n                    throw IllegalStateException("Native readiness state was incomplete")\n                }\n                VpnDiagnosticLog.write(this, "RUNTIME", "CONNECTED committed gen=$generation tun=${AppConfigs.TUN_ESTABLISHED} fd=${AppConfigs.FD_DELIVERED} socks=${AppConfigs.SOCKS_READY}")\n', 'connected commit log')
replace_once(SERVICE, '            } catch (e: Exception) {\n                Log.e(TAG, "Runtime start failed", e)\n', '            } catch (e: Exception) {\n                VpnDiagnosticLog.write(this, "RUNTIME_FAIL", "Runtime start failed: ${e.message}", e)\n                Log.e(TAG, "Runtime start failed", e)\n', 'runtime exception log')
replace_once(SERVICE, '        val established = builder.establish()\n            ?: throw IllegalStateException("Android refused to establish the VPN interface")\n', '        VpnDiagnosticLog.write(this, "TUN", "builder.establish begin allowed=${config.ALLOWED_APPS.size} blocked=${config.BLOCKED_APPS.size}")\n        val established = builder.establish()\n            ?: throw IllegalStateException("Android refused to establish the VPN interface")\n        VpnDiagnosticLog.write(this, "TUN", "builder.establish success gen=$generation")\n', 'TUN establish logs')
replace_once(SERVICE, '        startTun2socks(config, generation)\n        if (!sendFdAndWait(generation)) {\n', '        VpnDiagnosticLog.write(this, "TUN2SOCKS", "startTun2socks begin port=${config.LOCAL_SOCKS5_PORT}")\n        startTun2socks(config, generation)\n        VpnDiagnosticLog.write(this, "FD", "sendFdAndWait begin gen=$generation")\n        if (!sendFdAndWait(generation)) {\n', 'tun2socks/fd boundary logs')
replace_once(SERVICE, '        AppConfigs.FD_DELIVERED = true\n        XrayCoreManager.sendStateBroadcast(this)\n\n        if (!waitForSocks(config, generation)) {\n', '        AppConfigs.FD_DELIVERED = true\n        VpnDiagnosticLog.write(this, "FD", "FD delivered gen=$generation")\n        XrayCoreManager.sendStateBroadcast(this)\n\n        VpnDiagnosticLog.write(this, "SOCKS", "waitForSocks begin port=${config.LOCAL_SOCKS5_PORT} gen=$generation")\n        if (!waitForSocks(config, generation)) {\n', 'fd success and socks boundary logs')
replace_once(SERVICE, '        AppConfigs.SOCKS_READY = true\n        XrayCoreManager.sendStateBroadcast(this)\n', '        AppConfigs.SOCKS_READY = true\n        VpnDiagnosticLog.write(this, "SOCKS", "SOCKS ready port=${config.LOCAL_SOCKS5_PORT} gen=$generation")\n        XrayCoreManager.sendStateBroadcast(this)\n', 'socks ready log')
replace_once(SERVICE, '        val process = ProcessBuilder(\n', '        VpnDiagnosticLog.write(this, "TUN2SOCKS", "launch executable=$executable sockPath=${socketFile.absolutePath} proxy=socks5://<redacted>@127.0.0.1:${config.LOCAL_SOCKS5_PORT}")\n        val process = ProcessBuilder(\n', 'tun2socks launch log')
replace_once(SERVICE, '                process.inputStream.bufferedReader().use { reader ->\n                    reader.forEachLine { }\n                }\n                val code = process.waitFor()\n', '                process.inputStream.bufferedReader().use { reader ->\n                    reader.forEachLine { line -> VpnDiagnosticLog.write(this, "TUN2SOCKS_OUT", line) }\n                }\n                val code = process.waitFor()\n                VpnDiagnosticLog.write(this, "TUN2SOCKS", "process exited code=$code gen=$generation runtimeExpected=$runtimeExpected stopping=$stopping")\n', 'tun2socks output/exit logs')
replace_once(SERVICE, '            } catch (_: InterruptedException) {\n            } catch (e: Exception) {\n', '            } catch (_: InterruptedException) {\n                VpnDiagnosticLog.write(this, "TUN2SOCKS", "monitor interrupted gen=$generation")\n            } catch (e: Exception) {\n                VpnDiagnosticLog.write(this, "TUN2SOCKS", "monitor exception: ${e.message}", e)\n', 'tun2socks monitor exception logs')
replace_once(SERVICE, '            while (tries < 10 && generation == currentGeneration && !stopping) {\n                var socket: LocalSocket? = null\n                try {\n                    Thread.sleep(500L)\n', '            while (tries < 10 && generation == currentGeneration && !stopping) {\n                val attempt = tries + 1\n                VpnDiagnosticLog.write(this, "FD", "attempt=$attempt gen=$generation current=$currentGeneration stopping=$stopping childAlive=${tun2socksProcess?.isAlive == true}")\n                var socket: LocalSocket? = null\n                try {\n                    Thread.sleep(500L)\n', 'FD attempt logs')
replace_once(SERVICE, '                    socket.close()\n                    delivered = true\n                    break\n', '                    socket.close()\n                    VpnDiagnosticLog.write(this, "FD", "unix FD send succeeded attempt=$attempt")\n                    delivered = true\n                    break\n', 'FD send success log')
replace_once(SERVICE, '                } catch (_: Exception) {\n                    tries++\n                    try { socket?.close() } catch (_: Exception) {}\n                }\n', '                } catch (e: Exception) {\n                    VpnDiagnosticLog.write(this, "FD", "attempt=$attempt failed: ${e.javaClass.simpleName}: ${e.message}")\n                    tries++\n                    try { socket?.close() } catch (_: Exception) {}\n                }\n', 'FD failure logs')
replace_once(SERVICE, '        worker.start()\n        worker.join(6000L)\n        if (worker.isAlive) {\n', '        worker.start()\n        worker.join(6000L)\n        VpnDiagnosticLog.write(this, "FD", "worker joined alive=${worker.isAlive} delivered=$delivered gen=$generation current=$currentGeneration stopping=$stopping")\n        if (worker.isAlive) {\n', 'FD worker completion log')
replace_once(SERVICE, '    private fun waitForSocks(config: XrayConfig, generation: Long): Boolean {\n        repeat(20) {\n            if (generation != currentGeneration || stopping || !XrayCoreManager.isXrayRunning()) return false\n            if (XrayCoreManager.probeSocks(\n', '    private fun waitForSocks(config: XrayConfig, generation: Long): Boolean {\n        repeat(20) { attempt ->\n            val xrayAlive = XrayCoreManager.isXrayRunning()\n            VpnDiagnosticLog.write(this, "SOCKS", "probe attempt=${attempt + 1} gen=$generation current=$currentGeneration stopping=$stopping xrayAlive=$xrayAlive")\n            if (generation != currentGeneration || stopping || !xrayAlive) return false\n            if (XrayCoreManager.probeSocks(\n', 'SOCKS probe attempt logs')
replace_once(SERVICE, '                )\n            ) return true\n            Thread.sleep(100)\n', '                )\n            ) {\n                VpnDiagnosticLog.write(this, "SOCKS", "probe success attempt=${attempt + 1}")\n                return true\n            }\n            VpnDiagnosticLog.write(this, "SOCKS", "probe failed attempt=${attempt + 1}")\n            Thread.sleep(100)\n', 'SOCKS probe result logs')
replace_once(SERVICE, '    fun handleXrayCoreExit(generation: Long) {\n        if (generation != currentGeneration || stopping) return\n', '    fun handleXrayCoreExit(generation: Long) {\n        VpnDiagnosticLog.write(this, "XRAY", "handleXrayCoreExit gen=$generation current=$currentGeneration stopping=$stopping")\n        if (generation != currentGeneration || stopping) return\n', 'Xray exit callback log')
replace_once(SERVICE, '    private fun shutdownRuntimeInternal(broadcast: Boolean, keepConfig: Boolean) {\n        runtimeExpected = false\n', '    private fun shutdownRuntimeInternal(broadcast: Boolean, keepConfig: Boolean) {\n        VpnDiagnosticLog.write(this, "SHUTDOWN", "shutdownRuntimeInternal broadcast=$broadcast keepConfig=$keepConfig state=${AppConfigs.V2RAY_STATE} gen=$currentGeneration stopping=$stopping")\n        runtimeExpected = false\n', 'shutdown entry log')
replace_once(SERVICE, '    private fun terminateServiceLocked(\n        reason: String,\n        preserveConfig: Boolean,\n    ) {\n        if (stopping) return\n', '    private fun terminateServiceLocked(\n        reason: String,\n        preserveConfig: Boolean,\n    ) {\n        VpnDiagnosticLog.write(this, "TERMINATE", "reason=$reason preserveConfig=$preserveConfig state=${AppConfigs.V2RAY_STATE} gen=$currentGeneration runtimeExpected=$runtimeExpected stopping=$stopping tun=${AppConfigs.TUN_ESTABLISHED} fd=${AppConfigs.FD_DELIVERED} socks=${AppConfigs.SOCKS_READY}")\n        if (stopping) {\n            VpnDiagnosticLog.write(this, "TERMINATE", "ignored because stopping already true")\n            return\n        }\n', 'terminate reason log')
replace_once(SERVICE, '    override fun onRevoke() {\n        terminateService("VPN permission revoked", preserveConfig = false)\n', '    override fun onRevoke() {\n        VpnDiagnosticLog.write(this, "LIFECYCLE", "onRevoke")\n        terminateService("VPN permission revoked", preserveConfig = false)\n', 'onRevoke log')
replace_once(SERVICE, '    override fun onDestroy() {\n        synchronized(runtimeLock) {\n', '    override fun onDestroy() {\n        VpnDiagnosticLog.write(this, "LIFECYCLE", "onDestroy stopping=$stopping state=${AppConfigs.V2RAY_STATE} gen=$currentGeneration runtimeExpected=$runtimeExpected")\n        synchronized(runtimeLock) {\n', 'onDestroy log')
replace_once(SERVICE, '        } catch (e: Exception) {\n            Log.e(TAG, "Failed to start foreground service", e)\n            false\n', '        } catch (e: Exception) {\n            VpnDiagnosticLog.write(this, "FOREGROUND", "Failed to start foreground service: ${e.message}", e)\n            Log.e(TAG, "Failed to start foreground service", e)\n            false\n', 'foreground failure log')

replace_once(CORE, 'import com.github.tfox.flutter_vless.xray.utils.Utilities\n', 'import com.github.tfox.flutter_vless.xray.utils.Utilities\nimport com.github.tfox.flutter_vless.xray.utils.VpnDiagnosticLog\n', 'core logger import')
replace_once(CORE, '    fun startCore(context: XrayVPNService, config: XrayConfig, generation: Long): Boolean {\n        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING\n', '    fun startCore(context: XrayVPNService, config: XrayConfig, generation: Long): Boolean {\n        VpnDiagnosticLog.write(context, "XRAY", "startCore gen=$generation")\n        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING\n', 'xray start entry log')
replace_once(CORE, '            configFile.writeText(buildRuntimeConfigJson(config, context.filesDir).toString())\n            Utilities.copyAssets(context)\n', '            configFile.writeText(buildRuntimeConfigJson(config, context.filesDir).toString())\n            Utilities.copyAssets(context)\n            VpnDiagnosticLog.write(context, "XRAY", "runtime config prepared bytes=${configFile.length()}")\n', 'xray config prepared log')
replace_once(CORE, '        } catch (e: Exception) {\n            AppConfigs.LAST_ERROR = "Failed to prepare Xray config"\n', '        } catch (e: Exception) {\n            VpnDiagnosticLog.write(context, "XRAY", "Failed to prepare Xray config: ${e.message}", e)\n            AppConfigs.LAST_ERROR = "Failed to prepare Xray config"\n', 'xray config error log')
replace_once(CORE, '            val process = pb.start()\n            synchronized(processLock) {\n', '            VpnDiagnosticLog.write(context, "XRAY", "ProcessBuilder.start")\n            val process = pb.start()\n            synchronized(processLock) {\n', 'xray process start log')
replace_once(CORE, '            Thread.sleep(300)\n            if (!process.isAlive) {\n', '            Thread.sleep(300)\n            VpnDiagnosticLog.write(context, "XRAY", "startup probe alive=${process.isAlive} gen=$generation")\n            if (!process.isAlive) {\n', 'xray startup probe log')
replace_once(CORE, '                val output = process.inputStream.bufferedReader().readText()\n                Log.e(TAG, "Xray exited during startup: $output")\n', '                val output = process.inputStream.bufferedReader().readText()\n                VpnDiagnosticLog.write(context, "XRAY_EXIT", "Xray exited during startup output=$output")\n                Log.e(TAG, "Xray exited during startup: $output")\n', 'xray startup exit log')
replace_once(CORE, '                    process.inputStream.bufferedReader().use { reader ->\n                        reader.forEachLine { }\n                    }\n                    val exitCode = process.waitFor()\n', '                    process.inputStream.bufferedReader().use { reader ->\n                        reader.forEachLine { line -> VpnDiagnosticLog.write(context, "XRAY_OUT", line) }\n                    }\n                    val exitCode = process.waitFor()\n                    VpnDiagnosticLog.write(context, "XRAY_EXIT", "process exited code=$exitCode gen=$generation")\n', 'xray output/exit logs')
replace_once(CORE, '                } catch (_: InterruptedException) {\n                } catch (e: Exception) {\n                    Log.e(TAG, "Xray monitor failed", e)\n', '                } catch (_: InterruptedException) {\n                    VpnDiagnosticLog.write(context, "XRAY", "monitor interrupted gen=$generation")\n                } catch (e: Exception) {\n                    VpnDiagnosticLog.write(context, "XRAY", "monitor failed: ${e.message}", e)\n                    Log.e(TAG, "Xray monitor failed", e)\n', 'xray monitor exception logs')
replace_once(CORE, '        } catch (e: Exception) {\n            AppConfigs.LAST_ERROR = "Failed to start Xray"\n', '        } catch (e: Exception) {\n            VpnDiagnosticLog.write(context, "XRAY", "Failed to start Xray: ${e.message}", e)\n            AppConfigs.LAST_ERROR = "Failed to start Xray"\n', 'xray launch exception log')
replace_once(CORE, '    fun stopCore(context: XrayVPNService, broadcast: Boolean = true) {\n        val process = synchronized(processLock) {\n', '    fun stopCore(context: XrayVPNService, broadcast: Boolean = true) {\n        VpnDiagnosticLog.write(context, "XRAY", "stopCore broadcast=$broadcast state=${AppConfigs.V2RAY_STATE}")\n        val process = synchronized(processLock) {\n', 'xray stop log')
replace_once(CORE, '        if (!AppConfigs.TUN_ESTABLISHED ||\n            !AppConfigs.FD_DELIVERED ||\n            !AppConfigs.SOCKS_READY\n        ) return false\n', '        if (!AppConfigs.TUN_ESTABLISHED ||\n            !AppConfigs.FD_DELIVERED ||\n            !AppConfigs.SOCKS_READY\n        ) {\n            VpnDiagnosticLog.write(context, "READY", "markConnected rejected tun=${AppConfigs.TUN_ESTABLISHED} fd=${AppConfigs.FD_DELIVERED} socks=${AppConfigs.SOCKS_READY}")\n            return false\n        }\n', 'markConnected readiness rejection log')

DIAG_DART.parent.mkdir(parents=True, exist_ok=True)
DIAG_DART.write_text(r'''import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:revoltvpn/logic/app_colors.dart';

class VpnDiagnosticsScreen extends StatefulWidget {
  const VpnDiagnosticsScreen({super.key});

  @override
  State<VpnDiagnosticsScreen> createState() => _VpnDiagnosticsScreenState();
}

class _VpnDiagnosticsScreenState extends State<VpnDiagnosticsScreen> {
  static const _channel = MethodChannel('flutter_vless');
  String _log = 'Loading VPN diagnostics…';
  Timer? _timer;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    _loading = true;
    try {
      final value = await _channel.invokeMethod<String>('getDiagnosticLog');
      if (mounted) setState(() => _log = value?.isNotEmpty == true ? value! : 'No VPN diagnostic events yet.');
    } catch (e) {
      if (mounted) setState(() => _log = 'Could not read VPN diagnostics: $e');
    } finally {
      _loading = false;
    }
  }

  Future<void> _clear() async {
    await _channel.invokeMethod<bool>('clearDiagnosticLog');
    await _refresh();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _log));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('VPN diagnostic log copied')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDeep,
      appBar: AppBar(
        backgroundColor: AppColors.bgSurface,
        title: const Text('VPN Diagnostics'),
        actions: [
          IconButton(tooltip: 'Refresh', onPressed: _refresh, icon: const Icon(Icons.refresh)),
          IconButton(tooltip: 'Copy all', onPressed: _copy, icon: const Icon(Icons.copy)),
          IconButton(tooltip: 'Clear', onPressed: _clear, icon: const Icon(Icons.delete_outline)),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: DecoratedBox(
          decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white24)),
          child: SizedBox.expand(
            child: SingleChildScrollView(
              reverse: true,
              padding: const EdgeInsets.all(12),
              child: SelectableText(_log, style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 11, height: 1.35)),
            ),
          ),
        ),
      ),
    );
  }
}

class VpnDiagnosticsTile extends StatelessWidget {
  const VpnDiagnosticsTile({super.key});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.bug_report_outlined, color: Colors.orangeAccent),
      title: const Text('VPN Diagnostics', style: TextStyle(color: Colors.white)),
      subtitle: const Text('Live native/Xray/tun2socks/start-stop log', style: TextStyle(color: Colors.white60)),
      trailing: const Icon(Icons.chevron_right, color: Colors.white54),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VpnDiagnosticsScreen())),
    );
  }
}
''')
print('[ok] wrote Flutter diagnostics screen')

replace_once(SETTINGS, "import 'package:revoltvpn/screens/settings/in_settings/resilience.dart';\n", "import 'package:revoltvpn/screens/settings/in_settings/resilience.dart';\nimport 'package:revoltvpn/screens/settings/in_settings/vpn_diagnostics.dart';\n", 'settings diagnostics import')
replace_once(SETTINGS, '          const LightningToggleTile(),\n', '          const LightningToggleTile(),\n          const Divider(color: Colors.white12),\n          const VpnDiagnosticsTile(),\n', 'settings diagnostics tile')

print('Full VPN diagnostics instrumentation applied.')
