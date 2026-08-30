package com.github.tfox.flutter_vless.xray.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Base64
import android.util.Log
import com.github.tfox.flutter_vless.xray.core.XrayCoreManager
import com.github.tfox.flutter_vless.xray.dto.XrayConfig
import com.github.tfox.flutter_vless.xray.utils.AppConfigs
import java.io.File
import java.net.ServerSocket
import java.security.SecureRandom
import java.util.ArrayList

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

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            terminateService("Service restarted without command")
            return START_NOT_STICKY
        }

        val command = if (Build.VERSION.SDK_INT >= 33) {
            intent.getSerializableExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getSerializableExtra("COMMAND") as? AppConfigs.V2RAY_SERVICE_COMMANDS
        }

        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE) {
            terminateService("Stop requested")
            return START_NOT_STICKY
        }

        startForegroundSafely("Starting secure tunnel…")

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
                // After the Flutter process is recreated, this service instance
                // may be new while the daemon process still owns the last private
                // config snapshot. Never expose the snapshot outside this process.
                val config = currentConfig ?: AppConfigs.V2RAY_CONFIG
                if (config == null) {
                    terminateService("No active runtime snapshot to restart")
                    return START_NOT_STICKY
                }
                currentConfig = config
                Thread { startRuntime(config, currentProxyOnly) }.start()
            }

            else -> {
                terminateService("Unknown VPN command")
                return START_NOT_STICKY
            }
        }
        return START_STICKY
    }

    private fun startRuntime(config: XrayConfig, proxyOnly: Boolean) {
        synchronized(runtimeLock) {
            if (stopping) return
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
                Log.e(TAG, "Runtime start failed", e)
                AppConfigs.LAST_ERROR = e.message ?: "Runtime start failed"
                // Initial setup failure is not a recoverable snapshot.
                terminateServiceLocked(AppConfigs.LAST_ERROR, preserveConfig = false)
            }
        }
    }

    private fun prepareRuntimeIsolation(config: XrayConfig) {
        config.LOCAL_SOCKS5_PORT = findFreePort()
        config.LOCAL_API_PORT = findFreePort(excluding = config.LOCAL_SOCKS5_PORT)
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

    private fun findFreePort(excluding: Int = -1): Int {
        repeat(8) {
            val port = ServerSocket(0).use { it.localPort }
            if (port > 1024 && port != excluding) return port
        }
        throw IllegalStateException("Could not allocate an isolated local port")
    }

    private fun setupVpn(config: XrayConfig, generation: Long) {
        val builder = Builder()
        builder.setSession(config.REMARK)
        builder.setMtu(1500)
        builder.addAddress("26.26.26.1", 30)
        builder.addAddress("fd00:26:26::1", 64)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

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

        val serverIp = config.CONNECTED_V2RAY_SERVER_ADDRESS
        if (!serverIp.isIpv4Literal()) {
            throw IllegalStateException("VPN server address must be an IPv4 literal to avoid a routing loop")
        }
        for (route in excludeIp(serverIp)) {
            val parts = route.split("/")
            builder.addRoute(parts[0], parts[1].toInt())
        }
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
        val proxy = "socks5://${config.LOCAL_SOCKS5_USER}:${config.LOCAL_SOCKS5_PASS}@127.0.0.1:${config.LOCAL_SOCKS5_PORT}"
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
                    reader.forEachLine { /* release output deliberately discarded */ }
                }
                val code = process.waitFor()
                if (generation == currentGeneration && runtimeExpected && !stopping) {
                    Log.e(TAG, "tun2socks exited unexpectedly with code $code")
                    terminateService(
                        "tun2socks exited unexpectedly",
                        preserveConfig = true,
                    )
                }
            } catch (_: InterruptedException) {
            } catch (e: Exception) {
                if (generation == currentGeneration && runtimeExpected && !stopping) {
                    Log.e(TAG, "tun2socks monitor failed", e)
                    terminateService(
                        "tun2socks monitor failed",
                        preserveConfig = true,
                    )
                }
            }
        }.start()
    }

    private fun sendFdAndWait(generation: Long): Boolean {
        val pfd = mInterface ?: return false
        val fd = pfd.fileDescriptor
        val sockPath = File(filesDir, "sock_path").absolutePath
        for (attempt in 1..12) {
            if (generation != currentGeneration || stopping || tun2socksProcess?.isAlive != true) return false
            var socket: LocalSocket? = null
            try {
                Thread.sleep(if (attempt == 1) 120L else 250L)
                socket = LocalSocket()
                socket.connect(LocalSocketAddress(sockPath, LocalSocketAddress.Namespace.FILESYSTEM))
                socket.setFileDescriptorsForSend(arrayOf(fd))
                socket.outputStream.write(32)
                socket.outputStream.flush()
                socket.setFileDescriptorsForSend(null)
                socket.shutdownOutput()
                socket.close()
                Thread.sleep(250)
                return generation == currentGeneration && !stopping && tun2socksProcess?.isAlive == true
            } catch (_: Exception) {
                try { socket?.close() } catch (_: Exception) {}
            }
        }
        return false
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
        terminateService(
            "Xray core exited unexpectedly",
            preserveConfig = true,
        )
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

    private fun startForegroundSafely(text: String) {
        val channelId = "vpn_service_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(channelId, "VPN Service", NotificationManager.IMPORTANCE_LOW)
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
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(1, notification, FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(1, notification)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start foreground service", e)
        }
    }

    private fun excludeIp(ip: String): List<String> {
        val parts = ip.split(".").map { it.toInt() }
        val target = (parts[0].toLong() shl 24) + (parts[1].toLong() shl 16) +
            (parts[2].toLong() shl 8) + parts[3].toLong()
        val routes = ArrayList<String>()
        fun addRoutesExcluding(current: Long, prefix: Int) {
            if (prefix >= 32) return
            val nextPrefix = prefix + 1
            val half = 1L shl (32 - nextPrefix)
            val left = current
            val right = current + half
            if (target >= left && target < left + half) {
                routes.add(longToIp(right) + "/$nextPrefix")
                addRoutesExcluding(left, nextPrefix)
            } else {
                routes.add(longToIp(left) + "/$nextPrefix")
                addRoutesExcluding(right, nextPrefix)
            }
        }
        addRoutesExcluding(0L, 0)
        return routes
    }

    private fun longToIp(ip: Long): String =
        "${(ip shr 24) and 0xFF}.${(ip shr 16) and 0xFF}.${(ip shr 8) and 0xFF}.${ip and 0xFF}"

    private fun String.isIpv4Literal(): Boolean {
        val parts = split(".")
        if (parts.size != 4) return false
        return parts.all { it.isNotEmpty() && it.all(Char::isDigit) && (it.toIntOrNull() ?: -1) in 0..255 }
    }

    companion object {
        private const val TAG = "XrayVPNService"
        private const val FOREGROUND_SERVICE_TYPE_SPECIAL_USE = 0x40000000
    }
}
