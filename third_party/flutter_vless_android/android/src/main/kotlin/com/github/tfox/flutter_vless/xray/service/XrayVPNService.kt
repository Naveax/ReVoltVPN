package com.github.tfox.flutter_vless.xray.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.ResultReceiver
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import com.github.tfox.flutter_vless.xray.core.XrayCoreManager
import com.github.tfox.flutter_vless.xray.dto.XrayConfig
import com.github.tfox.flutter_vless.xray.utils.AppConfigs
import java.io.File
import java.net.ServerSocket
import java.security.SecureRandom

class XrayVPNService : VpnService() {
    private val runtimeLock = Any()
    private val random = SecureRandom()
    private var mInterface: ParcelFileDescriptor? = null
    private var tun2socksProcess: Process? = null
    private var currentConfig: XrayConfig? = null
    private var currentProxyOnly = false
    @Volatile private var currentGeneration = 0L
    @Volatile private var runtimeExpected = false
    @Volatile private var stopping = false
    @Volatile private var recoveringRuntime = false
    private var recoveryWindowStartedAtMs = 0L
    private var recoveryAttempts = 0

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            // START_STICKY may recreate a service with a null intent. Killing the
            // VPN in that callback turns normal Android process/service recovery
            // into a user-visible disconnect. Prefer redelivery for future starts
            // and recover from an in-process snapshot when one still exists.
            val config = currentConfig ?: AppConfigs.V2RAY_CONFIG
            if (config != null && !stopping && startForegroundSafely("Restoring secure tunnel…")) {
                val proxyOnly = currentProxyOnly ||
                    AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY
                Thread { startRuntime(config, proxyOnly) }.start()
                return START_REDELIVER_INTENT
            }
            stopping = true
            AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED
            AppConfigs.resetReadiness("Service restarted without runtime snapshot")
            XrayCoreManager.sendStateBroadcast(this)
            stopSelf()
            return START_NOT_STICKY
        }

        val command = if (Build.VERSION.SDK_INT >= 33) {
            intent.getSerializableExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getSerializableExtra("COMMAND") as? AppConfigs.V2RAY_SERVICE_COMMANDS
        }

        // Tunnel readiness lives in this remote VpnService process. Answer state
        // queries here instead of asking the Flutter process to trust a cached
        // broadcast that may have been missed during startup/process recreation.
        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.QUERY_STATE) {
            val receiver = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra("STATE_RECEIVER", ResultReceiver::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra("STATE_RECEIVER") as? ResultReceiver
            }
            receiver?.send(0, buildStateBundle())

            // START_SERVICE stores the runtime snapshot before the startup worker
            // flips V2RAY_STATE to CONNECTING. A state query can arrive in that
            // tiny window. Never treat such a snapshot as an idle service, or the
            // observer itself can stop an otherwise healthy VPN startup.
            val hasRuntimeSnapshot = currentConfig != null || AppConfigs.V2RAY_CONFIG != null
            val activeOrStarting = hasRuntimeSnapshot ||
                runtimeExpected ||
                AppConfigs.V2RAY_STATE != AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED
            if (!activeOrStarting) {
                // This is only a query-created empty service instance. Mark it as
                // intentionally stopping so onDestroy does not publish a fake
                // "VPN service destroyed" error/generation change.
                stopping = true
                stopSelfResult(startId)
            }
            return if (activeOrStarting) START_STICKY else START_NOT_STICKY
        }

        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE) {
            terminateService("Stop requested")
            return START_NOT_STICKY
        }

        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE ||
            command == AppConfigs.V2RAY_SERVICE_COMMANDS.RESTART_SERVICE
        ) {
            // A previous QUERY_STATE may have scheduled an empty service
            // instance for stop. This newer startId supersedes that query-only
            // lifecycle decision, so let the requested runtime actually start.
            stopping = false
        }

        if (!startForegroundSafely("Starting secure tunnel…")) {
            failBeforeRuntime("Could not start foreground VPN service")
            return START_NOT_STICKY
        }

        when (command) {
            AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE -> {
                val config = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getSerializableExtra("V2RAY_CONFIG", XrayConfig::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getSerializableExtra("V2RAY_CONFIG") as? XrayConfig
                }
                if (config == null) {
                    terminateService("Missing VPN configuration")
                    return START_NOT_STICKY
                }
                currentConfig = config
                currentProxyOnly = intent.getBooleanExtra("PROXY_ONLY", false)
                Thread { startRuntime(config, currentProxyOnly) }.start()
            }

            AppConfigs.V2RAY_SERVICE_COMMANDS.RESTART_SERVICE -> {
                val config = currentConfig ?: AppConfigs.V2RAY_CONFIG
                if (config == null) {
                    terminateService("No active runtime snapshot to restart")
                    return START_NOT_STICKY
                }
                currentConfig = config
                currentProxyOnly =
                    AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY
                Thread { startRuntime(config, currentProxyOnly) }.start()
            }

            else -> {
                terminateService("Unknown VPN command")
                return START_NOT_STICKY
            }
        }
        // If Android has to recreate this foreground VPN service, redeliver the
        // START/RESTART intent containing the runtime configuration instead of
        // invoking us with a null intent that cannot rebuild the tunnel.
        return START_REDELIVER_INTENT
    }

    private fun buildStateBundle(): Bundle {
        val config = currentConfig ?: AppConfigs.V2RAY_CONFIG
        val state = when (AppConfigs.V2RAY_STATE) {
            AppConfigs.V2RAY_STATES.V2RAY_CONNECTED -> "CONNECTED"
            AppConfigs.V2RAY_STATES.V2RAY_CONNECTING -> "CONNECTING"
            AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED -> "DISCONNECTED"
        }
        return Bundle().apply {
            putString("state", state)
            putBoolean("tunEstablished", AppConfigs.TUN_ESTABLISHED)
            putBoolean("fdDelivered", AppConfigs.FD_DELIVERED)
            putBoolean("socksReady", AppConfigs.SOCKS_READY)
            putInt("socksPort", config?.LOCAL_SOCKS5_PORT ?: 0)
            putString("socksUser", config?.LOCAL_SOCKS5_USER.orEmpty())
            putString("socksPass", config?.LOCAL_SOCKS5_PASS.orEmpty())
            putLong("generation", AppConfigs.RUNTIME_GENERATION)
            putString("error", AppConfigs.LAST_ERROR)
        }
    }

    private fun failBeforeRuntime(reason: String) {
        stopping = true
        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED
        AppConfigs.resetReadiness(reason)
        XrayCoreManager.sendStateBroadcast(this)
        stopSelf()
    }

    private fun startRuntime(
        config: XrayConfig,
        proxyOnly: Boolean,
        isRecovery: Boolean = false,
    ) {
        synchronized(runtimeLock) {
            if (stopping) return
            if (!isRecovery) {
                recoveringRuntime = false
                recoveryWindowStartedAtMs = 0L
                recoveryAttempts = 0
            }
            currentConfig = config
            currentProxyOnly = proxyOnly
            val generation = ++currentGeneration
            runtimeExpected = false
            shutdownRuntimeInternal(broadcast = false, keepConfig = true)
            prepareRuntimeIsolation(config)
            AppConfigs.V2RAY_CONNECTION_MODE = if (proxyOnly) {
                AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY
            } else {
                AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN
            }
            AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING
            AppConfigs.RUNTIME_GENERATION = generation
            AppConfigs.V2RAY_CONFIG = config
            AppConfigs.resetReadiness()
            XrayCoreManager.sendStateBroadcast(this)

            try {
                if (!XrayCoreManager.startCore(this, config, generation)) {
                    throw IllegalStateException(AppConfigs.LAST_ERROR.ifEmpty { "Xray failed to start" })
                }

                if (proxyOnly) {
                    if (!waitForSocks(config, generation)) {
                        throw IllegalStateException("Local SOCKS5 did not become ready")
                    }
                    AppConfigs.SOCKS_READY = true
                    runtimeExpected = true
                    if (!XrayCoreManager.markProxyOnlyConnected(this, config, generation)) {
                        throw IllegalStateException("Proxy-only readiness state was incomplete")
                    }
                    return
                }

                setupVpn(config, generation)
                runtimeExpected = true
                if (!XrayCoreManager.markConnected(this, config, generation)) {
                    throw IllegalStateException("Native readiness state was incomplete")
                }
            } catch (e: Exception) {
                Log.e(TAG, if (isRecovery) "Runtime recovery failed" else "Runtime start failed", e)
                AppConfigs.LAST_ERROR = e.message ?: "Runtime start failed"
                if (isRecovery) {
                    // Keep the foreground service alive while the bounded recovery
                    // loop retries. Do not broadcast a transient DISCONNECTED state
                    // that would make Flutter clear its recovery snapshot.
                    shutdownRuntimeInternal(broadcast = false, keepConfig = true)
                    throw e
                }
                terminateServiceLocked(AppConfigs.LAST_ERROR, preserveConfig = false)
            }
        }
    }

    private fun prepareRuntimeIsolation(config: XrayConfig) {
        config.LOCAL_SOCKS5_PORT = findFreePort()
        config.LOCAL_API_PORT = 0
        config.LOCAL_HTTP_PORT = 0
        config.LOCAL_SOCKS5_USER = "rv_${randomToken(12)}"
        config.LOCAL_SOCKS5_PASS = randomToken(24)
        File(filesDir, "sock_path").delete()
    }

    private fun randomToken(bytes: Int): String {
        val raw = ByteArray(bytes)
        random.nextBytes(raw)
        return Base64.encodeToString(raw, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }

    private fun findFreePort(): Int {
        repeat(8) {
            val port = ServerSocket(0).use { it.localPort }
            if (port > 1024) return port
        }
        throw IllegalStateException("Could not allocate an isolated local port")
    }

    private fun setupVpn(config: XrayConfig, generation: Long) {
        if (config.ALLOWED_APPS.isNotEmpty() && config.BLOCKED_APPS.isNotEmpty()) {
            throw IllegalStateException("Allowed and blocked app routing cannot be combined")
        }

        val builder = Builder()
        builder.setSession(config.REMARK)
        builder.setMtu(1500)
        builder.addAddress("26.26.26.1", 30)
        builder.addAddress("fd00:26:26::1", 64)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

        if (config.ALLOWED_APPS.isNotEmpty()) {
            for (pkg in config.ALLOWED_APPS.distinct()) {
                if (pkg == packageName) {
                    throw IllegalStateException("ReVolt cannot route itself through its own VPN")
                }
                try {
                    builder.addAllowedApplication(pkg)
                } catch (e: Exception) {
                    throw IllegalStateException("Could not allow selected package $pkg", e)
                }
            }
        } else {
            try {
                builder.addDisallowedApplication(packageName)
            } catch (e: Exception) {
                throw IllegalStateException("Could not exclude ReVolt from its own VPN", e)
            }

            for (pkg in config.BLOCKED_APPS.distinct()) {
                if (pkg == packageName) continue
                try {
                    builder.addDisallowedApplication(pkg)
                } catch (e: Exception) {
                    Log.w(TAG, "Could not bypass package $pkg", e)
                }
            }
        }

        builder.addRoute("0.0.0.0", 0)
        builder.addRoute("::", 0)
        builder.addDnsServer("1.1.1.1")
        builder.addDnsServer("8.8.8.8")

        val established = builder.establish()
            ?: throw IllegalStateException("Android refused to establish the VPN interface")
        if (generation != currentGeneration || stopping) {
            established.close()
            throw IllegalStateException("VPN startup was superseded")
        }
        mInterface = established
        AppConfigs.TUN_ESTABLISHED = true
        XrayCoreManager.sendStateBroadcast(this)

        startTun2socks(config, generation)
        if (!sendFdAndWait(generation)) {
            throw IllegalStateException("TUN file descriptor was not delivered to tun2socks")
        }
        AppConfigs.FD_DELIVERED = true
        XrayCoreManager.sendStateBroadcast(this)

        if (!waitForSocks(config, generation)) {
            throw IllegalStateException("Authenticated SOCKS5 ingress did not become ready")
        }
        AppConfigs.SOCKS_READY = true
        XrayCoreManager.sendStateBroadcast(this)
    }

    private fun startTun2socks(config: XrayConfig, generation: Long) {
        val executable = File(applicationInfo.nativeLibraryDir, "libtun2socks.so").absolutePath
        val socketFile = File(filesDir, "sock_path")
        if (socketFile.exists() && !socketFile.delete()) {
            throw IllegalStateException("Could not remove stale tun2socks socket")
        }
        val proxy =
            "socks5://${config.LOCAL_SOCKS5_USER}:${config.LOCAL_SOCKS5_PASS}@127.0.0.1:${config.LOCAL_SOCKS5_PORT}"
        val process = ProcessBuilder(
            arrayListOf(
                executable,
                "-sock-path", socketFile.absolutePath,
                "-proxy", proxy,
                "-mtu", "1500",
                "-loglevel", "warning"
            )
        ).redirectErrorStream(true).directory(filesDir).start()
        tun2socksProcess = process

        Thread {
            try {
                process.inputStream.bufferedReader().use { reader ->
                    reader.forEachLine { }
                }
                val code = process.waitFor()
                if (generation == currentGeneration && runtimeExpected && !stopping) {
                    Log.e(TAG, "tun2socks exited unexpectedly with code $code")
                    requestRuntimeRecovery(
                        "tun2socks exited unexpectedly with code $code",
                        generation,
                    )
                }
            } catch (_: InterruptedException) {
            } catch (e: Exception) {
                if (generation == currentGeneration && runtimeExpected && !stopping) {
                    Log.e(TAG, "tun2socks monitor failed", e)
                    requestRuntimeRecovery("tun2socks monitor failed", generation)
                }
            }
        }.start()
    }

    private fun sendFdAndWait(generation: Long): Boolean {
        val pfd = mInterface ?: return false
        val fd = pfd.fileDescriptor
        val sockPath = File(filesDir, "sock_path").absolutePath

        // flutter_vless_android 1.1.5 waits 500 ms between UDS attempts and
        // does not use Process.isAlive as a precondition for connecting to the
        // FD socket. Preserve that proven device timing while still returning
        // a real success/failure result to the hardened fail-closed caller.
        var delivered = false
        val worker = Thread {
            var tries = 0
            while (tries < 10 && generation == currentGeneration && !stopping) {
                var socket: LocalSocket? = null
                try {
                    Thread.sleep(500L)
                    socket = LocalSocket()
                    socket.connect(
                        LocalSocketAddress(sockPath, LocalSocketAddress.Namespace.FILESYSTEM)
                    )
                    socket.setFileDescriptorsForSend(arrayOf(fd))
                    socket.outputStream.write(32)
                    socket.outputStream.flush()
                    socket.setFileDescriptorsForSend(null)
                    socket.shutdownOutput()
                    socket.close()
                    delivered = true
                    break
                } catch (_: Exception) {
                    tries++
                    try { socket?.close() } catch (_: Exception) {}
                }
            }
        }
        worker.start()
        worker.join(6000L)
        if (worker.isAlive) {
            worker.interrupt()
            return false
        }
        if (!delivered || generation != currentGeneration || stopping) return false

        // Fail closed only after the exact 1.1.5 FD transfer had a chance to
        // complete. A child that dies immediately after accepting the FD is not
        // a usable data path.
        Thread.sleep(250L)
        return tun2socksProcess?.isAlive == true
    }

    private fun waitForSocks(config: XrayConfig, generation: Long): Boolean {
        repeat(20) {
            if (generation != currentGeneration || stopping || !XrayCoreManager.isXrayRunning()) return false
            if (XrayCoreManager.probeSocks(
                    config.LOCAL_SOCKS5_PORT,
                    config.LOCAL_SOCKS5_USER,
                    config.LOCAL_SOCKS5_PASS,
                    timeoutMs = 500
                )
            ) return true
            Thread.sleep(100)
        }
        return false
    }

    fun handleXrayCoreExit(generation: Long) {
        if (generation != currentGeneration || stopping) return
        requestRuntimeRecovery("Xray core exited unexpectedly", generation)
    }

    private fun requestRuntimeRecovery(reason: String, generation: Long) {
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

    private fun shutdownRuntimeInternal(broadcast: Boolean, keepConfig: Boolean) {
        runtimeExpected = false
        try {
            val process = tun2socksProcess
            process?.destroy()
            if (process != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && process.isAlive) {
                Thread.sleep(100)
                if (process.isAlive) process.destroyForcibly()
            }
        } catch (_: Exception) {}
        tun2socksProcess = null
        try { mInterface?.close() } catch (_: Exception) {}
        mInterface = null
        File(filesDir, "sock_path").delete()
        AppConfigs.resetReadiness(AppConfigs.LAST_ERROR)
        XrayCoreManager.stopCore(this, broadcast = false)
        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED
        if (!keepConfig) {
            currentConfig = null
            AppConfigs.V2RAY_CONFIG = null
        }
        if (broadcast) XrayCoreManager.sendStateBroadcast(this)
    }

    private fun terminateService(
        reason: String,
        preserveConfig: Boolean = false,
    ) {
        synchronized(runtimeLock) {
            terminateServiceLocked(reason, preserveConfig)
        }
    }

    private fun terminateServiceLocked(
        reason: String,
        preserveConfig: Boolean,
    ) {
        if (stopping) return
        stopping = true
        AppConfigs.LAST_ERROR = if (reason == "Stop requested") "" else reason
        currentGeneration++
        shutdownRuntimeInternal(
            broadcast = true,
            keepConfig = preserveConfig,
        )
        try { stopForeground(true) } catch (_: Exception) {}
        stopSelf()
    }

    override fun onRevoke() {
        terminateService("VPN permission revoked", preserveConfig = false)
        super.onRevoke()
    }

    override fun onDestroy() {
        synchronized(runtimeLock) {
            if (!stopping) {
                stopping = true
                currentGeneration++
                AppConfigs.LAST_ERROR = "VPN service destroyed"
                shutdownRuntimeInternal(broadcast = true, keepConfig = false)
            }
        }
        super.onDestroy()
    }

    private fun startForegroundSafely(text: String): Boolean {
        val channelId = "vpn_service_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "VPN Service",
                NotificationManager.IMPORTANCE_LOW,
            )
            channel.lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
        }
        val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }.setContentTitle("ReVolt VPN")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .build()
        return try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(1, notification, FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(1, notification)
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start foreground service", e)
            false
        }
    }

    companion object {
        private const val TAG = "XrayVPNService"
        private const val FOREGROUND_SERVICE_TYPE_SPECIAL_USE = 0x40000000
        private const val MAX_RUNTIME_RECOVERY_ATTEMPTS = 3
        private const val RECOVERY_WINDOW_MS = 60_000L
        private const val RECOVERY_BASE_DELAY_MS = 450L
    }
}
