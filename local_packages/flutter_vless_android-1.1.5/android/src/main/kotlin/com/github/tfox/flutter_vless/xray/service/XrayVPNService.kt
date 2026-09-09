package com.github.tfox.flutter_vless.xray.service

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.ResultReceiver
import android.os.SystemClock
import android.util.Log
import com.github.tfox.flutter_vless.xray.core.XrayCoreManager
import com.github.tfox.flutter_vless.xray.dto.XrayConfig
import com.github.tfox.flutter_vless.xray.utils.AppConfigs
import com.github.tfox.flutter_vless.xray.utils.ProcessTerminator
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

class XrayVPNService : VpnService() {
    private var mInterface: ParcelFileDescriptor? = null
    private var tun2socksProcess: Process? = null
    @Volatile private var isRunning = false
    private val xrayRecoveryGate = RuntimeRecoveryGate()
    private val tun2socksRecoveryGate = RuntimeRecoveryGate()
    @Volatile private var currentConfig: XrayConfig? = null
    @Volatile private var currentProxyOnly = false
    @Volatile private var shuttingDownIntentionally = false
    private var tun2socksRecoveryAttempt = 0
    private var shutdownRetryAttempt = 0
    private var pendingShutdownToken = ""
    private val runtimeExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "revolt-vpn-runtime").apply { isDaemon = true }
    }

    private val deadlineHandler = Handler(Looper.getMainLooper())
    private var sessionDeadlineElapsed: Long? = null
    private var sessionDeadlineToken: String? = null
    private val sessionDeadlineRunnable = Runnable { enforceSessionDeadline() }
    private val shutdownRetryRunnable = Runnable {
        val token = pendingShutdownToken
        if (token.isEmpty()) return@Runnable
        shuttingDownIntentionally = false
        stopAll(token)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            if (isRunning && currentConfig != null) return START_REDELIVER_INTENT
            clearPersistedDeadline()
            cancelSessionExpiryAlarm()
            stopSelf()
            return START_NOT_STICKY
        }

        if (intent.getBooleanExtra(EXTRA_SESSION_EXPIRED, false)) {
            enforcePersistedDeadline(intent.getStringExtra("RUNTIME_TOKEN").orEmpty())
            return START_NOT_STICKY
        }

        val command = if (Build.VERSION.SDK_INT >= 33) {
            intent.getSerializableExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getSerializableExtra("COMMAND") as? AppConfigs.V2RAY_SERVICE_COMMANDS
        }

        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.QUERY_STATE) {
            replyRuntimeState(intent)
            if (!runtimeAppearsActive()) stopSelfResult(startId)
            return if (runtimeAppearsActive()) START_REDELIVER_INTENT else START_NOT_STICKY
        }

        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE) {
            val requestedToken = intent.getStringExtra("RUNTIME_TOKEN").orEmpty()
            val activeToken = currentConfig?.RUNTIME_TOKEN.orEmpty()
            if (requestedToken.isEmpty() || activeToken.isEmpty() || requestedToken != activeToken) {
                Log.w(TAG, "Ignoring STOP_SERVICE without matching runtime generation")
                return if (runtimeAppearsActive()) START_REDELIVER_INTENT else START_NOT_STICKY
            }
            stopAll(requestedToken)
            return START_NOT_STICKY
        }

        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.UPDATE_SESSION_DEADLINE) {
            updateSessionDeadline(intent)
            return if (runtimeAppearsActive()) START_REDELIVER_INTENT else START_NOT_STICKY
        }

        if (command != AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE) {
            Log.w(TAG, "Ignoring unknown VPN service command: $command")
            if (!runtimeAppearsActive()) stopSelfResult(startId)
            return if (runtimeAppearsActive()) START_REDELIVER_INTENT else START_NOT_STICKY
        }

        createNotificationChannel()
        val notification = createNotification("VPN Service Running")
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(1, notification, FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(1, notification)
            }
        } catch (error: Exception) {
            Log.e(TAG, "Failed to start foreground", error)
            clearPersistedDeadline()
            cancelSessionExpiryAlarm()
            stopSelf()
            return START_NOT_STICKY
        }

        val config = if (Build.VERSION.SDK_INT >= 33) {
            intent.getSerializableExtra("V2RAY_CONFIG", XrayConfig::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getSerializableExtra("V2RAY_CONFIG") as? XrayConfig
        }
        if (config == null || config.RUNTIME_TOKEN.isEmpty()) {
            Log.e(TAG, "START_SERVICE missing valid V2RAY_CONFIG")
            stopAll()
            return START_NOT_STICKY
        }

        // Never replace an owned generation until every old child has actually
        // stopped. Its quota deadline remains armed throughout failed cleanup.
        val previousRuntimeToken = currentConfig?.RUNTIME_TOKEN.orEmpty().ifEmpty {
            AppConfigs.V2RAY_CONFIG?.RUNTIME_TOKEN.orEmpty()
        }
        val cleanupToken = previousRuntimeToken.ifEmpty { config.RUNTIME_TOKEN }
        if (!cleanup(clearDeadline = false)) {
            Log.e(TAG, "Refusing to start while a previous tun2socks child is still alive")
            scheduleShutdownRetry(cleanupToken, "stale tun2socks survived startup cleanup")
            return START_REDELIVER_INTENT
        }
        if (XrayCoreManager.isXrayRunning() &&
            !XrayCoreManager.stopCore(this, previousRuntimeToken)
        ) {
            Log.e(TAG, "Refusing to start while a previous Xray child is still alive")
            scheduleShutdownRetry(cleanupToken, "stale Xray survived startup cleanup")
            return START_REDELIVER_INTENT
        }

        clearSessionDeadline()
        clearShutdownRetry()
        shuttingDownIntentionally = false
        currentConfig = config
        val proxyOnly = intent.getBooleanExtra("PROXY_ONLY", false)
        currentProxyOnly = proxyOnly
        if (!armSessionDeadline(config, BOOTSTRAP_SESSION_SECONDS)) {
            return START_NOT_STICKY
        }

        runtimeExecutor.execute { startRuntime(config, proxyOnly) }
        return START_REDELIVER_INTENT
    }

    private fun startRuntime(config: XrayConfig, proxyOnly: Boolean) {
        if (!isCurrent(config)) return
        if (XrayCoreManager.isXrayRunning()) {
            Log.e(TAG, "Refusing duplicate Xray startup after clean preflight")
            if (isCurrent(config)) stopAll(config.RUNTIME_TOKEN)
            return
        }
        if (!XrayCoreManager.startCore(this, config)) {
            if (isCurrent(config)) stopAll(config.RUNTIME_TOKEN)
            return
        }
        if (!isCurrent(config)) {
            XrayCoreManager.stopCore(this, config.RUNTIME_TOKEN)
            return
        }
        if (proxyOnly) {
            isRunning = true
            XrayCoreManager.markRuntimeReady(this, config)
        } else {
            setupVpn(config)
        }
    }

    private fun isCurrent(config: XrayConfig): Boolean =
        !shuttingDownIntentionally && currentConfig?.RUNTIME_TOKEN == config.RUNTIME_TOKEN

    private fun runtimeAppearsActive(): Boolean {
        val config = currentConfig ?: return false
        if (config.RUNTIME_TOKEN.isEmpty() || shuttingDownIntentionally) return false
        return isRunning || XrayCoreManager.isXrayRunning() ||
            AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTING
    }

    private fun replyRuntimeState(intent: Intent) {
        val receiver = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra("STATE_RECEIVER", ResultReceiver::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra("STATE_RECEIVER") as? ResultReceiver
        } ?: return
        val config = currentConfig
        val bundle = Bundle().apply {
            putBoolean("active", runtimeAppearsActive())
            putString("runtimeToken", config?.RUNTIME_TOKEN.orEmpty())
            putBoolean("runtimeReady", AppConfigs.RUNTIME_READY)
            putBoolean("proxyOnly", currentProxyOnly)
            putString("state", AppConfigs.V2RAY_STATE.name)
        }
        receiver.send(0, bundle)
    }

    private fun setupVpn(config: XrayConfig) {
        try {
            if (!isCurrent(config)) return
            mInterface?.close()
            mInterface = null
            val builder = Builder()
                .setSession(config.REMARK)
                .setMtu(1500)
                .addAddress("26.26.26.1", 30)
                .addAddress("fd00:26:26::1", 126)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
            if (config.BLOCKED_APPS.isNotEmpty()) {
                throw IllegalStateException("Per-app VPN bypass is disabled in ReVolt")
            }
            builder.addDisallowedApplication(packageName)
            builder.addRoute("0.0.0.0", 0)
            builder.addRoute("::", 0)
            builder.addDnsServer("8.8.8.8")
            builder.addDnsServer("1.1.1.1")
            val established = builder.establish()
                ?: throw IllegalStateException("Android refused to establish VPN interface")
            if (!isCurrent(config)) {
                established.close()
                return
            }
            mInterface = established
            isRunning = true
            runTun2socks(config)
        } catch (error: Exception) {
            Log.e(TAG, "Failed to setup VPN", error)
            if (isCurrent(config)) stopAll(config.RUNTIME_TOKEN)
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
        if (inbounds.length() != 1) return null
        val inbound = inbounds.optJSONObject(0) ?: return null
        if (inbound.optString("tag") != "revolt-secure-socks" ||
            inbound.optString("protocol") != "socks" ||
            inbound.optString("listen") != "127.0.0.1"
        ) return null
        val settings = inbound.optJSONObject("settings") ?: return null
        if (settings.optString("auth") != "password" ||
            !settings.optBoolean("udp", false) ||
            settings.optString("ip") != "127.0.0.1"
        ) return null
        val users = settings.optJSONArray("users") ?: return null
        if (users.length() != 1) return null
        val user = users.optJSONObject(0) ?: return null
        val port = inbound.optInt("port", -1)
        val username = user.optString("user")
        val password = user.optString("pass")
        if (port <= 1024 || port > 65535 || username.isEmpty() || password.isEmpty()) return null
        return SecureSocksCredentials(port, username, password)
    }

    private fun scheduleTun2socksRecovery(config: XrayConfig, reason: String) {
        if (!isRunning || !isCurrent(config)) return
        val token = config.RUNTIME_TOKEN
        if (!tun2socksRecoveryGate.tryAcquire(token)) return
        XrayCoreManager.markRuntimeConnecting(this, config)
        val attempt = ++tun2socksRecoveryAttempt
        val delayMs = (500L * (1L shl (attempt - 1).coerceIn(0, 6))).coerceAtMost(30_000L)
        Thread({
            try {
                Thread.sleep(delayMs)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                tun2socksRecoveryGate.release(token)
                return@Thread
            }
            if (!isRunning || !isCurrent(config)) {
                tun2socksRecoveryGate.release(token)
                return@Thread
            }

            tun2socksRecoveryGate.release(token)
            try {
                if (isRunning && isCurrent(config)) runTun2socks(config)
            } catch (error: Exception) {
                Log.e(TAG, "tun2socks recovery attempt failed", error)
                if (isRunning && isCurrent(config)) {
                    scheduleTun2socksRecovery(config, "restart failed")
                }
            }
        }, "revolt-tun2socks-recovery").start()
        Log.w(TAG, "Scheduled tun2socks recovery attempt $attempt: $reason")
    }

    private fun runTun2socks(config: XrayConfig) {
        if (!isCurrent(config)) return
        val tun2socksPath = File(applicationInfo.nativeLibraryDir, "libtun2socks.so").absolutePath
        val socketFile = File(filesDir, "sock_path")
        if (socketFile.exists() && !socketFile.delete()) {
            throw IllegalStateException("Could not delete stale tun2socks socket")
        }
        val secure = secureSocksCredentials(config)
            ?: throw IllegalStateException("Authenticated ReVolt SOCKS5 inbound missing")
        config.LOCAL_SOCKS5_PORT = secure.port
        val process = ProcessBuilder(
            tun2socksPath,
            "-sock-path", socketFile.absolutePath,
            "-proxy", "socks5://${secure.username}:${secure.password}@127.0.0.1:${secure.port}",
            "-mtu", "1500",
            "-loglevel", "warning",
        ).redirectErrorStream(true).directory(filesDir).start()
        tun2socksProcess = process
        Thread({
            try {
                process.inputStream.bufferedReader().use { reader -> reader.forEachLine { _ -> } }
            } catch (error: Exception) {
                Log.e(TAG, "Error reading tun2socks output", error)
            }

            try {
                val exitCode = process.waitFor()
                Log.w(TAG, "tun2socks process exited with code $exitCode")
                if (isRunning && tun2socksProcess === process && isCurrent(config)) {
                    tun2socksProcess = null
                    scheduleTun2socksRecovery(config, "process exited")
                }
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }, "revolt-tun2socks-monitor").start()
        sendFd(process, config)
    }

    private fun sendFd(process: Process, config: XrayConfig) {
        val fd = mInterface?.fileDescriptor ?: return
        val sockFile = File(filesDir, "sock_path").absolutePath
        Thread({
            var tries = 0
            while (
                tries < 10 &&
                isRunning &&
                tun2socksProcess === process &&
                ProcessTerminator.isAlive(process)
            ) {
                var localSocket: LocalSocket? = null
                try {
                    Thread.sleep(500)
                    localSocket = LocalSocket()
                    localSocket.connect(LocalSocketAddress(sockFile, LocalSocketAddress.Namespace.FILESYSTEM))
                    localSocket.setFileDescriptorsForSend(arrayOf(fd))
                    localSocket.outputStream.write(32)
                    localSocket.outputStream.flush()
                    localSocket.setFileDescriptorsForSend(null)
                    localSocket.shutdownOutput()
                    localSocket.close()
                    if (isRunning && isCurrent(config) && tun2socksProcess === process) {
                        tun2socksRecoveryAttempt = 0
                        XrayCoreManager.markRuntimeReady(this, config)
                    }
                    return@Thread
                } catch (_: Exception) {
                    tries++
                    try { localSocket?.close() } catch (_: Exception) {}
                }
            }
            if (isRunning && tun2socksProcess === process &&
                !ProcessTerminator.terminate(process)
            ) {
                Log.e(TAG, "tun2socks survived FD-handshake failure shutdown")
                stopAll(config.RUNTIME_TOKEN)
            }
        }, "revolt-tun2socks-fd").start()
    }

    fun handleXrayCoreExit(config: XrayConfig) {
        if (!isRunning || !isCurrent(config)) return
        val token = config.RUNTIME_TOKEN
        if (!xrayRecoveryGate.tryAcquire(token)) return
        XrayCoreManager.markRuntimeConnecting(this, config)
        Thread({
            var attempt = 0
            try {
                while (isRunning && isCurrent(config)) {
                    attempt++
                    val delayMs =
                        (500L * (1L shl (attempt - 1).coerceIn(0, 6))).coerceAtMost(30_000L)
                    Thread.sleep(delayMs)
                    if (!isRunning || !isCurrent(config)) break
                    if (XrayCoreManager.startCore(this, config)) {
                        if (currentProxyOnly ||
                            (mInterface != null && ProcessTerminator.isAlive(tun2socksProcess))
                        ) {
                            XrayCoreManager.markRuntimeReady(this, config)
                        }

                        xrayRecoveryGate.release(token)
                        if (isRunning && isCurrent(config) && !XrayCoreManager.isXrayRunning()) {
                            handleXrayCoreExit(config)
                        }
                        return@Thread
                    }
                }
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            } finally {
                xrayRecoveryGate.release(token)
            }
        }, "revolt-xray-recovery").start()
    }

    private fun cleanup(clearDeadline: Boolean = true): Boolean {
        isRunning = false
        if (clearDeadline) clearSessionDeadline()
        xrayRecoveryGate.reset()
        tun2socksRecoveryGate.reset()
        tun2socksRecoveryAttempt = 0
        currentProxyOnly = false
        AppConfigs.RUNTIME_READY = false

        val process = tun2socksProcess
        val tun2socksStopped = ProcessTerminator.terminate(process)
        if (tun2socksStopped) {
            if (tun2socksProcess === process) tun2socksProcess = null
        } else {
            Log.e(TAG, "tun2socks child process did not terminate after forced shutdown")
        }

        try { mInterface?.close() } catch (error: Exception) {
            Log.w(TAG, "Failed to close VPN interface during cleanup", error)
        }
        mInterface = null
        return tun2socksStopped
    }

    private fun scheduleShutdownRetry(runtimeToken: String, reason: String) {
        if (runtimeToken.isEmpty()) return
        pendingShutdownToken = runtimeToken
        val attempt = ++shutdownRetryAttempt
        val delayMs =
            (250L * (1L shl (attempt - 1).coerceIn(0, 4))).coerceAtMost(5_000L)
        deadlineHandler.removeCallbacks(shutdownRetryRunnable)
        deadlineHandler.postDelayed(shutdownRetryRunnable, delayMs)
        Log.e(TAG, "Native shutdown unconfirmed; retry $attempt scheduled in ${delayMs}ms: $reason")
    }

    private fun clearShutdownRetry() {
        deadlineHandler.removeCallbacks(shutdownRetryRunnable)
        shutdownRetryAttempt = 0
        pendingShutdownToken = ""
    }

    private fun stopAll(confirmationToken: String = currentConfig?.RUNTIME_TOKEN.orEmpty()) {
        if (shuttingDownIntentionally) return
        val runtimeToken = confirmationToken.ifEmpty { currentConfig?.RUNTIME_TOKEN.orEmpty() }
        shuttingDownIntentionally = true

        // Preserve the quota deadline until both native children are proven
        // dead. An unconfirmed shutdown must not silently remove its kill timer.
        if (!cleanup(clearDeadline = false)) {
            shuttingDownIntentionally = false
            scheduleShutdownRetry(runtimeToken, "tun2socks is still alive")
            return
        }
        if (!XrayCoreManager.stopCore(this, runtimeToken)) {
            shuttingDownIntentionally = false
            scheduleShutdownRetry(runtimeToken, "Xray is still alive")
            return
        }

        clearSessionDeadline()
        clearShutdownRetry()
        currentConfig = null
        stopForeground(true)
        stopSelf()
    }

    private fun armSessionDeadline(config: XrayConfig, remainingSeconds: Long): Boolean {
        val boundedSeconds = remainingSeconds.coerceAtLeast(0L).coerceAtMost(Long.MAX_VALUE / 1000L)
        val delayMs = boundedSeconds * 1000L
        val nowEpochMs = System.currentTimeMillis()
        val epochDeadline = if (Long.MAX_VALUE - nowEpochMs < delayMs) Long.MAX_VALUE else nowEpochMs + delayMs
        sessionDeadlineToken = config.RUNTIME_TOKEN
        sessionDeadlineElapsed = SystemClock.elapsedRealtime() + delayMs
        if (!persistDeadline(config.RUNTIME_TOKEN, epochDeadline) ||
            !scheduleSessionExpiryAlarm(config.RUNTIME_TOKEN, epochDeadline)
        ) {
            stopAll(config.RUNTIME_TOKEN)
            return false
        }
        deadlineHandler.removeCallbacks(sessionDeadlineRunnable)
        if (delayMs == 0L) deadlineHandler.post(sessionDeadlineRunnable)
        else deadlineHandler.postDelayed(sessionDeadlineRunnable, delayMs)
        return true
    }

    private fun clearSessionDeadline() {
        deadlineHandler.removeCallbacks(sessionDeadlineRunnable)
        sessionDeadlineElapsed = null
        sessionDeadlineToken = null
        clearPersistedDeadline()
        cancelSessionExpiryAlarm()
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
        stopAll(token)
    }

    private fun deadlineReceiver(intent: Intent): ResultReceiver? =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra("DEADLINE_RECEIVER", ResultReceiver::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra("DEADLINE_RECEIVER") as? ResultReceiver
        }

    private fun replyDeadline(
        receiver: ResultReceiver?,
        success: Boolean,
        code: String = "",
        message: String = "",
    ) {
        if (receiver == null) return
        val data = Bundle().apply {
            if (code.isNotEmpty()) putString("code", code)
            if (message.isNotEmpty()) putString("message", message)
        }
        receiver.send(if (success) DEADLINE_RESULT_OK else DEADLINE_RESULT_ERROR, data)
    }

    private fun updateSessionDeadline(intent: Intent) {
        val receiver = deadlineReceiver(intent)
        val config = currentConfig
        val requestedToken = intent.getStringExtra("RUNTIME_TOKEN").orEmpty()
        val remainingSeconds = intent.getLongExtra("REMAINING_SECONDS", -1L)
        when (
            SessionDeadlineGate.decide(
                config?.RUNTIME_TOKEN,
                requestedToken,
                remainingSeconds,
            )
        ) {
            SessionDeadlineGate.Decision.NO_RUNTIME -> {
                replyDeadline(receiver, false, "NO_RUNTIME", "VPN runtime is not active")
                return
            }
            SessionDeadlineGate.Decision.TOKEN_MISMATCH -> {
                replyDeadline(
                    receiver,
                    false,
                    "DEADLINE_TOKEN_MISMATCH",
                    "Session deadline belongs to a stale VPN generation",
                )
                return
            }
            SessionDeadlineGate.Decision.INVALID_REMAINING -> {
                replyDeadline(
                    receiver,
                    false,
                    "INVALID_DEADLINE",
                    "remainingSeconds must be non-negative",
                )
                return
            }
            SessionDeadlineGate.Decision.ALLOW -> Unit
        }

        val activeConfig = config ?: run {
            replyDeadline(receiver, false, "NO_RUNTIME", "VPN runtime is not active")
            return
        }
        if (!armSessionDeadline(activeConfig, remainingSeconds)) {
            replyDeadline(
                receiver,
                false,
                "DEADLINE_ARM_FAILED",
                "VPN service could not persist and arm the session deadline",
            )
            return
        }
        replyDeadline(receiver, true)
    }

    private fun persistDeadline(runtimeToken: String, expiresAtEpochMs: Long): Boolean = try {
        getSharedPreferences(DEADLINE_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(PREF_RUNTIME_TOKEN, runtimeToken)
            .putLong(PREF_EXPIRES_AT_MS, expiresAtEpochMs)
            .commit()
    } catch (error: Exception) {
        Log.e(TAG, "Failed to persist non-secret session deadline", error)
        false
    }

    private fun clearPersistedDeadline() {
        try {
            getSharedPreferences(DEADLINE_PREFS, Context.MODE_PRIVATE)
                .edit().remove(PREF_RUNTIME_TOKEN).remove(PREF_EXPIRES_AT_MS).apply()
        } catch (error: Exception) {
            Log.w(TAG, "Failed to clear persisted session deadline", error)
        }
    }

    private fun enforcePersistedDeadline(alarmToken: String) {
        val stored = try {
            val prefs = getSharedPreferences(DEADLINE_PREFS, Context.MODE_PRIVATE)
            prefs.getString(PREF_RUNTIME_TOKEN, null).orEmpty() to
                prefs.getLong(PREF_EXPIRES_AT_MS, 0L)
        } catch (error: Exception) {
            Log.e(TAG, "Failed to read persisted session deadline", error)
            clearPersistedDeadline()
            cancelSessionExpiryAlarm()
            stopSelf()
            return
        }
        val storedToken = stored.first
        val storedDeadline = stored.second
        if (alarmToken.isEmpty() || storedToken.isEmpty() || alarmToken != storedToken) {
            if (currentConfig == null) stopSelf()
            return
        }
        val remaining = storedDeadline - System.currentTimeMillis()
        if (storedDeadline > 0L && remaining > 0L) {
            if (!scheduleSessionExpiryAlarm(storedToken, storedDeadline)) {
                val activeToken = currentConfig?.RUNTIME_TOKEN.orEmpty()
                if (activeToken == storedToken) stopAll(storedToken) else stopSelf()
            } else if (currentConfig == null) {
                stopSelf()
            }
            return
        }
        val activeToken = currentConfig?.RUNTIME_TOKEN.orEmpty()
        if (activeToken.isNotEmpty() && activeToken == storedToken) {
            stopAll(storedToken)
        } else {
            clearPersistedDeadline()
            cancelSessionExpiryAlarm()
            stopForeground(true)
            stopSelf()
        }
    }

    private fun scheduleSessionExpiryAlarm(runtimeToken: String, expiresAtEpochMs: Long): Boolean {
        cancelSessionExpiryAlarm()
        if (runtimeToken.isEmpty() || expiresAtEpochMs <= 0L) return false
        return try {
            val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pendingIntent = sessionExpiryPendingIntent(runtimeToken)

            // This AlarmManager entry is a process-recovery backup. The active
            // service's elapsedRealtime Handler is the primary session deadline.
            // Android 12+ may deny exact-alarm special access; in that case use
            // an allowed inexact wakeup rather than pretending exactness exists.
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    alarmManager.canScheduleExactAlarms() -> {
                    alarmManager.setExactAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        expiresAtEpochMs,
                        pendingIntent,
                    )
                }
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.M -> {
                    alarmManager.setAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        expiresAtEpochMs,
                        pendingIntent,
                    )
                }
                else -> {
                    alarmManager.setExact(
                        AlarmManager.RTC_WAKEUP,
                        expiresAtEpochMs,
                        pendingIntent,
                    )
                }
            }
            true
        } catch (error: Exception) {
            Log.e(TAG, "Failed to schedule OS session-expiry backup alarm", error)
            false
        }
    }

    private fun cancelSessionExpiryAlarm() {
        try {
            val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
            alarmManager.cancel(sessionExpiryPendingIntent(""))
        } catch (error: Exception) {
            Log.w(TAG, "Failed to cancel session-expiry alarm", error)
        }
    }

    private fun sessionExpiryPendingIntent(runtimeToken: String): PendingIntent {
        val intent = Intent(this, XrayVPNService::class.java)
            .putExtra(EXTRA_SESSION_EXPIRED, true)
            .putExtra("RUNTIME_TOKEN", runtimeToken)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        return PendingIntent.getService(this, SESSION_EXPIRY_REQUEST_CODE, intent, flags)
    }

    override fun onDestroy() {
        deadlineHandler.removeCallbacks(shutdownRetryRunnable)
        pendingShutdownToken = ""
        if (!shuttingDownIntentionally) {
            val confirmationToken = currentConfig?.RUNTIME_TOKEN.orEmpty()
            val tunStopped = cleanup(clearDeadline = false)
            val xrayStopped = XrayCoreManager.stopCore(this, confirmationToken)
            if (!tunStopped || !xrayStopped) {
                Log.e(TAG, "Service destroyed before all child-process shutdown could be proven")
            } else {
                clearSessionDeadline()
                currentConfig = null
            }
            stopForeground(true)
        }
        runtimeExecutor.shutdownNow()
        super.onDestroy()
    }

    override fun onRevoke() {
        stopAll()
        super.onRevoke()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = android.app.NotificationChannel(
                "REVOLT_VPN_SERVICE",
                "VPN Service",
                android.app.NotificationManager.IMPORTANCE_LOW,
            )
            getSystemService(android.app.NotificationManager::class.java)
                ?.createNotificationChannel(channel)
        }
    }

    private fun createNotification(content: String): android.app.Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.Notification.Builder(this, "REVOLT_VPN_SERVICE")
        } else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(this)
        }
        val icon = resources.getIdentifier("notification_icon", "drawable", packageName)
            .takeIf { it != 0 } ?: android.R.drawable.ic_dialog_info
        return builder
            .setContentTitle("VPN Service")
            .setContentText(content)
            .setSmallIcon(icon)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setVisibility(android.app.Notification.VISIBILITY_PRIVATE)
            .build()
            .also {
                it.flags = it.flags or android.app.Notification.FLAG_ONGOING_EVENT or
                    android.app.Notification.FLAG_NO_CLEAR
            }
    }

    companion object {
        private const val TAG = "XrayVPNService"
        private const val FOREGROUND_SERVICE_TYPE_SPECIAL_USE = 0x40000000
        private const val BOOTSTRAP_SESSION_SECONDS = 120L
        private const val DEADLINE_PREFS = "revolt_session_deadline"
        private const val PREF_RUNTIME_TOKEN = "runtime_token"
        private const val PREF_EXPIRES_AT_MS = "expires_at_ms"
        private const val EXTRA_SESSION_EXPIRED = "SESSION_EXPIRED"
        private const val SESSION_EXPIRY_REQUEST_CODE = 1001
        private const val DEADLINE_RESULT_OK = 0
        private const val DEADLINE_RESULT_ERROR = 1
    }
}
