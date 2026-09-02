package com.github.tfox.flutter_vless.xray.service

import android.content.Intent
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.github.tfox.flutter_vless.xray.core.XrayCoreManager
import com.github.tfox.flutter_vless.xray.dto.XrayConfig
import com.github.tfox.flutter_vless.xray.utils.AppConfigs
import org.json.JSONObject
import java.io.File
import java.io.FileDescriptor
import java.util.ArrayList

/**
 * Android VPN Service implementation.
 * 
 * This service is responsible for:
 * 1. Establishing the VPN interface (TUN device) using Android's VpnService API.
 * 2. Managing the `tun2socks` process, which routes traffic from the TUN device to the SOCKS proxy.
 * 3. Handling the lifecycle of the VPN connection (start, stop, cleanup).
 * 4. Supporting "Proxy Only" mode where VPN is skipped.
 * 
 * Key Technical Detail:
 * To support Android 15 (16KB page size) and avoid "bad file descriptor" errors, we use a custom
 * mechanism to pass the TUN file descriptor to `tun2socks`. Instead of passing it via command line
 * (which fails across process boundaries), we send it over a Unix Domain Socket.
 */
class XrayVPNService : VpnService() {

    private var mInterface: ParcelFileDescriptor? = null
    private var tun2socksProcess: Process? = null
    @Volatile private var isRunning = false
    @Volatile private var recoveringXray = false
    @Volatile private var recoveringTun2socks = false
    private var tun2socksRecoveryAttempt = 0
    private var currentConfig: XrayConfig? = null
    private var currentProxyOnly = false
    private val deadlineHandler = Handler(Looper.getMainLooper())
    private var sessionDeadlineElapsed: Long? = null
    private var sessionDeadlineToken: String? = null
    private val sessionDeadlineRunnable = Runnable { enforceSessionDeadline() }

    override fun onCreate() {
        super.onCreate()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            if (isRunning && currentConfig != null) return START_REDELIVER_INTENT
            stopSelf()
            return START_NOT_STICKY
        }

        val command = if (Build.VERSION.SDK_INT >= 33) {
            intent.getSerializableExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getSerializableExtra("COMMAND") as? AppConfigs.V2RAY_SERVICE_COMMANDS
        }

        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE) {
            val requestedToken = intent.getStringExtra("RUNTIME_TOKEN")
            val activeToken = currentConfig?.RUNTIME_TOKEN.orEmpty()
            if (!requestedToken.isNullOrEmpty() && activeToken.isNotEmpty() && requestedToken != activeToken) {
                Log.w(TAG, "Ignoring stale STOP_SERVICE for a different runtime generation")
                return START_NOT_STICKY
            }
            stopAll(activeToken.ifEmpty { requestedToken.orEmpty() })
            return START_NOT_STICKY
        }

        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.UPDATE_SESSION_DEADLINE) {
            updateSessionDeadline(intent)
            return if (isRunning) START_REDELIVER_INTENT else START_NOT_STICKY
        }

        // Create notification channel and start foreground immediately to prevent crash.
        createNotificationChannel()
        val notification = createNotification("VPN Service Running")
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(1, notification, FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(1, notification)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start foreground", e)
            stopSelf()
            return START_NOT_STICKY
        }

        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE) {
            val config = if (Build.VERSION.SDK_INT >= 33) {
                intent.getSerializableExtra("V2RAY_CONFIG", XrayConfig::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getSerializableExtra("V2RAY_CONFIG") as? XrayConfig
            }

            if (config != null) {
                // A fast reconnect must not leave the previous Xray process
                // owning the local proxy port.
                if (XrayCoreManager.isXrayRunning()) {
                    Log.w(TAG, "Stopping stale Xray core before restart")
                    XrayCoreManager.stopCore(this)
                }
                cleanup()
                currentConfig = config

                // Check if we should run in Proxy Only mode (no VPN interface)
                val proxyOnly = intent.getBooleanExtra("PROXY_ONLY", false)
                currentProxyOnly = proxyOnly
                armSessionDeadline(config, BOOTSTRAP_SESSION_SECONDS)
                
                // Start the Xray Core (SOCKS/HTTP proxy)
                if (XrayCoreManager.startCore(this, config)) {
                    if (!proxyOnly) {
                        // If not proxy-only, establish the VPN interface and start tun2socks
                        setupVpn(config)
                    } else {
                        isRunning = true
                        Log.d(TAG, "Starting in PROXY_ONLY mode")
                        XrayCoreManager.markRuntimeReady(this, config)
                    }
                } else {
                    stopSelf()
                }
            }
        } else {
            stopSelf()
        }

        return START_REDELIVER_INTENT
    }

    /**
     * Establishes the VPN interface (TUN) and starts tun2socks.
     */
    private fun setupVpn(config: XrayConfig) {
        try {
            if (mInterface != null) {
                mInterface?.close()
                mInterface = null
            }

            val builder = Builder()
            builder.setSession(config.REMARK)
            builder.setMtu(1500)
            builder.addAddress("26.26.26.1", 30)
            builder.addAddress("fd00:26:26::1", 126)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
            }
            
            if (config.BLOCKED_APPS.isNotEmpty()) {
                throw IllegalStateException("Per-app VPN bypass is disabled in ReVolt")
            }
            try {
                builder.addDisallowedApplication(packageName)
            } catch (e: Exception) {
                throw IllegalStateException("Failed to exclude ReVolt from its own VPN", e)
            }

            // Full-tunnel routing. ReVolt itself is already outside the VPN.
            builder.addRoute("0.0.0.0", 0)
            builder.addRoute("::", 0)

            // Add DNS servers
            try {
                builder.addDnsServer("8.8.8.8")
                builder.addDnsServer("1.1.1.1")
            } catch (e: Exception) {
                throw IllegalStateException("Failed to configure VPN DNS", e)
            }

            // Establish the VPN interface
            mInterface = builder.establish()
                ?: throw IllegalStateException("Android refused to establish VPN interface")
            isRunning = true
            
            // Start tun2socks to handle the traffic
            runTun2socks(config)

        } catch (e: Exception) {
            Log.e(TAG, "Failed to setup VPN", e)
            stopAll()
        }
    }

    private data class SecureSocksCredentials(
        val port: Int,
        val username: String,
        val password: String,
    )

    private fun secureSocksCredentials(config: XrayConfig): SecureSocksCredentials? {
        val inbounds = try {
            JSONObject(config.V2RAY_FULL_JSON_CONFIG).optJSONArray("inbounds")
        } catch (_: Exception) {
            null
        } ?: return null

        for (i in 0 until inbounds.length()) {
            val inbound = inbounds.optJSONObject(i) ?: continue
            if (inbound.optString("tag") != "revolt-secure-socks") continue
            if (inbound.optString("protocol") != "socks" ||
                inbound.optString("listen") != "127.0.0.1"
            ) return null

            val settings = inbound.optJSONObject("settings") ?: return null
            if (settings.optString("auth") != "password") return null
            val user = settings.optJSONArray("users")?.optJSONObject(0) ?: return null
            val port = inbound.optInt("port", -1)
            val username = user.optString("user")
            val password = user.optString("pass")
            if (port <= 1024 || port > 65535 || username.isEmpty() || password.isEmpty()) {
                return null
            }
            return SecureSocksCredentials(port, username, password)
        }
        return null
    }

    private fun scheduleTun2socksRecovery(config: XrayConfig, reason: String) {
        if (!isRunning || currentConfig !== config || recoveringTun2socks) return
        XrayCoreManager.markRuntimeConnecting(this, config)
        recoveringTun2socks = true
        val attempt = ++tun2socksRecoveryAttempt
        val shift = (attempt - 1).coerceIn(0, 6)
        val delayMs = (500L * (1L shl shift)).coerceAtMost(30_000L)
        Log.w(TAG, "Scheduling tun2socks recovery attempt $attempt in ${delayMs}ms: $reason")

        Thread {
            try {
                Thread.sleep(delayMs)
            } catch (_: InterruptedException) {
                recoveringTun2socks = false
                return@Thread
            }

            recoveringTun2socks = false
            if (isRunning && currentConfig === config) {
                runTun2socks(config)
            }
        }.start()
    }

    /**
     * Starts the tun2socks process and initiates the FD transfer.
     */
    private fun runTun2socks(config: XrayConfig) {
        val tun2socksPath = File(applicationInfo.nativeLibraryDir, "libtun2socks.so").absolutePath
        val socketFile = File(filesDir, "sock_path")
        if (socketFile.exists() && !socketFile.delete()) {
            Log.w(TAG, "Could not delete stale tun2socks socket")
        }
        val sockPath = socketFile.absolutePath
        
        val secure = secureSocksCredentials(config)
            ?: throw IllegalStateException("Authenticated ReVolt SOCKS5 inbound missing")
        config.LOCAL_SOCKS5_PORT = secure.port

        // Command to start tun2socks. 
        // Note: We pass -sock-path to tell it where to listen for the FD.
        val cmd = arrayListOf(
            tun2socksPath,
            "-sock-path", sockPath,
            "-proxy", "socks5://${secure.username}:${secure.password}@127.0.0.1:${secure.port}",
            "-mtu", "1500",
            "-loglevel", "debug"
        )

        Log.d(TAG, "Starting tun2socks with authenticated loopback SOCKS5")

        try {
            val pb = ProcessBuilder(cmd)
            pb.redirectErrorStream(true)
            pb.directory(filesDir)
            val process = pb.start()
            tun2socksProcess = process

            // Read tun2socks output in a separate thread
            Thread {
                try {
                    process.inputStream.bufferedReader().use { reader ->
                        reader.forEachLine { _ -> }
                    }
                    
                    process.waitFor()
                    if (isRunning && tun2socksProcess === process && currentConfig === config) {
                        Log.e(TAG, "tun2socks exited unexpectedly; keeping TUN fail-closed")
                        tun2socksProcess = null
                        scheduleTun2socksRecovery(config, "process exited")
                    }
                } catch (e: java.io.InterruptedIOException) {
                    // Expected when stopping
                } catch (e: InterruptedException) {
                } catch (e: Exception) {
                    Log.e(TAG, "Error reading tun2socks output", e)
                }
            }.start()

            // Send the TUN file descriptor to tun2socks via socket
            sendFd(process, config)

        } catch (e: Exception) {
            Log.e(TAG, "Failed to start tun2socks; keeping TUN fail-closed", e)
            scheduleTun2socksRecovery(config, "start failure")
        }
    }

    /**
     * Sends the TUN interface file descriptor to the running tun2socks process.
     * This uses a Unix Domain Socket to pass the FD, which is required because
     * ProcessBuilder cannot inherit FDs on Android.
     */
    private fun sendFd(process: Process, config: XrayConfig) {
        val fd = mInterface?.fileDescriptor ?: return
        val sockFile = File(filesDir, "sock_path").absolutePath

        Thread {
            var tries = 0
            while (tries < 10 && isRunning && tun2socksProcess === process && process.isAlive) {
                var localSocket: LocalSocket? = null
                try {
                    Thread.sleep(500)
                    localSocket = LocalSocket()
                    localSocket.connect(LocalSocketAddress(sockFile, LocalSocketAddress.Namespace.FILESYSTEM))
                    val out = localSocket.outputStream
                    localSocket.setFileDescriptorsForSend(arrayOf(fd))
                    out.write(32)
                    out.flush()
                    localSocket.setFileDescriptorsForSend(null)
                    localSocket.shutdownOutput()
                    localSocket.close()
                    if (isRunning && currentConfig === config && tun2socksProcess === process) {
                        tun2socksRecoveryAttempt = 0
                        XrayCoreManager.markRuntimeReady(this, config)
                    }
                    return@Thread
                } catch (_: Exception) {
                    tries++
                    try { localSocket?.close() } catch (_: Exception) {}
                }
            }

            if (isRunning && tun2socksProcess === process) {
                Log.e(TAG, "FD handoff failed; recycling tun2socks without dropping TUN")
                try { process.destroy() } catch (_: Exception) {}
            }
        }.start()
    }

    fun handleXrayCoreExit(config: XrayConfig) {
        if (!isRunning || currentConfig !== config || recoveringXray) return
        recoveringXray = true

        Thread {
            var attempt = 0
            try {
                while (isRunning && currentConfig === config) {
                    attempt++
                    val shift = (attempt - 1).coerceIn(0, 6)
                    val delayMs = (500L * (1L shl shift)).coerceAtMost(30_000L)
                    Log.w(TAG, "Recovering Xray core attempt $attempt in ${delayMs}ms")
                    Thread.sleep(delayMs)
                    if (!isRunning || currentConfig !== config) break

                    if (XrayCoreManager.startCore(this, config)) {
                        Log.w(TAG, "Xray core recovered without dropping TUN")
                        if (currentProxyOnly || (mInterface != null && tun2socksProcess?.isAlive == true)) {
                            XrayCoreManager.markRuntimeReady(this, config)
                        }
                        return@Thread
                    }
                }
            } catch (_: InterruptedException) {
            } finally {
                recoveringXray = false
            }
        }.start()
    }

    /**
     * Cleans up resources (tun2socks process, VPN interface) without stopping the service completely.
     * Used when restarting or switching configurations.
     */
    private fun cleanup() {
        isRunning = false
        clearSessionDeadline()
        recoveringXray = false
        recoveringTun2socks = false
        tun2socksRecoveryAttempt = 0
        currentProxyOnly = false
        AppConfigs.RUNTIME_READY = false
        tun2socksProcess?.destroy()
        tun2socksProcess = null
        try {
            mInterface?.close()
            mInterface = null
        } catch (e: Exception) {}
    }

    /**
     * Stops everything: tun2socks, VPN interface, and Xray Core.
     */
    private fun stopAll(confirmationToken: String = currentConfig?.RUNTIME_TOKEN.orEmpty()) {
        cleanup()
        currentConfig = null
        XrayCoreManager.stopCore(this, confirmationToken)
        stopForeground(true)
        stopSelf()
    }

    private fun armSessionDeadline(config: XrayConfig, remainingSeconds: Long) {
        val boundedSeconds = remainingSeconds.coerceAtLeast(0L).coerceAtMost(Long.MAX_VALUE / 1000L)
        val delayMs = boundedSeconds * 1000L
        sessionDeadlineToken = config.RUNTIME_TOKEN
        sessionDeadlineElapsed = SystemClock.elapsedRealtime() + delayMs
        deadlineHandler.removeCallbacks(sessionDeadlineRunnable)
        if (delayMs == 0L) deadlineHandler.post(sessionDeadlineRunnable)
        else deadlineHandler.postDelayed(sessionDeadlineRunnable, delayMs)
    }

    private fun clearSessionDeadline() {
        deadlineHandler.removeCallbacks(sessionDeadlineRunnable)
        sessionDeadlineElapsed = null
        sessionDeadlineToken = null
    }

    private fun enforceSessionDeadline() {
        val token = sessionDeadlineToken ?: return
        val deadline = sessionDeadlineElapsed ?: return
        val config = currentConfig ?: return
        if (config.RUNTIME_TOKEN != token) return
        val remaining = deadline - SystemClock.elapsedRealtime()
        if (remaining > 0L) {
            deadlineHandler.postDelayed(sessionDeadlineRunnable, remaining)
            return
        }
        Log.w(TAG, "Native session deadline expired; stopping runtime fail-closed")
        stopAll(token)
    }

    private fun updateSessionDeadline(intent: Intent) {
        val config = currentConfig ?: return
        val token = intent.getStringExtra("RUNTIME_TOKEN").orEmpty()
        if (token.isEmpty() || token != config.RUNTIME_TOKEN) {
            Log.w(TAG, "Ignoring session deadline update for stale runtime generation")
            return
        }
        val remainingSeconds = intent.getLongExtra("REMAINING_SECONDS", -1L)
        if (remainingSeconds < 0L) {
            Log.w(TAG, "Ignoring invalid negative session deadline")
            return
        }
        armSessionDeadline(config, remainingSeconds)
    }

    override fun onDestroy() {
        stopAll()
        super.onDestroy()
    }

    override fun onRevoke() {
        stopAll()
        super.onRevoke()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channelId = "REVOLT_VPN_SERVICE"
            val channelName = "VPN Service"
            val channel = android.app.NotificationChannel(
                channelId,
                channelName,
                android.app.NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(android.app.NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun createNotification(content: String): android.app.Notification {
        val channelId = "REVOLT_VPN_SERVICE"
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(this)
        }
        
        // Use a default icon if not set
        var icon = android.R.drawable.ic_dialog_info
        
        val notification = builder
            .setContentTitle("VPN Service")
            .setContentText(content)
            .setSmallIcon(icon)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .build()

        notification.flags = notification.flags or
            android.app.Notification.FLAG_ONGOING_EVENT or
            android.app.Notification.FLAG_NO_CLEAR
        return notification
    }

    companion object {
        private const val TAG = "XrayVPNService"
        private const val FOREGROUND_SERVICE_TYPE_SPECIAL_USE = 0x40000000
        private const val BOOTSTRAP_SESSION_SECONDS = 120L
    }
}
