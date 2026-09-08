package com.github.tfox.flutter_vless.xray.core

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Build
import android.os.CountDownTimer
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import com.github.tfox.flutter_vless.xray.dto.XrayConfig
import com.github.tfox.flutter_vless.xray.service.XrayVPNService
import com.github.tfox.flutter_vless.xray.utils.AppConfigs
import com.github.tfox.flutter_vless.xray.utils.Utilities
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Owns the Xray child process and its fail-closed runtime state. */
object XrayCoreManager {
    private const val NOTIFICATION_ID = 1
    private const val TAG = "XrayCoreManager"
    private var xrayProcess: Process? = null
    private var countDownTimer: CountDownTimer? = null
    private var seconds = 0

    private fun removeLegacyConfig(filesDir: File): Boolean {
        return try {
            val legacy = File(filesDir, "config.json")
            !legacy.exists() || legacy.delete()
        } catch (error: Exception) {
            Log.e(TAG, "Could not remove legacy Xray config", error)
            false
        }
    }

    private fun normalizeRuntimeConfig(value: Any?): Any? = when (value) {
        is JSONObject -> {
            val normalized = JSONObject()
            val aliases = mapOf(
                "xHTTPSettings" to "xhttpSettings",
                "httpUpgradeSettings" to "httpupgradeSettings",
                "splitHTTPSettings" to "splithttpSettings",
            )
            val keys = value.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                if (key == "allowInsecure") continue
                val targetKey = aliases[key] ?: key
                if (aliases.containsKey(key) && value.has(targetKey)) continue
                val normalizedValue = normalizeRuntimeConfig(value.opt(key))
                normalized.put(
                    targetKey,
                    if (targetKey == "network" && normalizedValue is String) {
                        normalizedValue.lowercase()
                    } else {
                        normalizedValue
                    },
                )
            }
            normalized
        }
        is JSONArray -> JSONArray().also { out ->
            for (i in 0 until value.length()) out.put(normalizeRuntimeConfig(value.opt(i)))
        }
        else -> value
    }

    private fun normalizeVlessOutbounds(configJson: JSONObject) {
        val outbounds = configJson.optJSONArray("outbounds") ?: return
        for (i in 0 until outbounds.length()) {
            val outbound = outbounds.optJSONObject(i) ?: continue
            if (outbound.optString("protocol") != "vless") continue
            val settings = outbound.optJSONObject("settings") ?: continue
            if (settings.has("vnext")) continue

            val address = settings.optString("address")
            val id = settings.optString("id")
            val port = settings.optInt("port", 0)
            if (address.isEmpty() || id.isEmpty() || port <= 0) continue

            val user = JSONObject()
                .put("id", id)
                .put("encryption", settings.optString("encryption", "none"))
                .put("flow", settings.optString("flow", ""))
                .put("level", settings.optInt("level", 8))
            val server = JSONObject()
                .put("address", address)
                .put("port", port)
                .put("users", JSONArray().put(user))
            outbound.put("settings", JSONObject().put("vnext", JSONArray().put(server)))
        }
    }

    private fun sanitizeLogPaths(configJson: JSONObject, filesDir: File) {
        val log = configJson.optJSONObject("log") ?: return
        log.remove("access")
        try {
            File(filesDir, "access.log").delete()
        } catch (_: Exception) {
        }
        if (log.optString("error").isNotEmpty()) {
            log.put("error", File(filesDir, "error.log").absolutePath)
        }
    }

    internal fun buildRuntimeConfigJson(config: XrayConfig, filesDir: File): JSONObject {
        val configJson = normalizeRuntimeConfig(JSONObject(config.V2RAY_FULL_JSON_CONFIG)) as JSONObject
        normalizeVlessOutbounds(configJson)
        sanitizeLogPaths(configJson, filesDir)

        val inbounds = configJson.optJSONArray("inbounds")
            ?: throw IllegalStateException("Secure SOCKS5 inbound is missing")
        if (inbounds.length() != 1) {
            throw IllegalStateException("Secure SOCKS5 requires exactly one inbound")
        }
        val inbound = inbounds.optJSONObject(0)
            ?: throw IllegalStateException("Secure SOCKS5 inbound is invalid")
        val settings = inbound.optJSONObject("settings")
            ?: throw IllegalStateException("Secure SOCKS5 settings are missing")
        val users = settings.optJSONArray("users")
            ?: throw IllegalStateException("Secure SOCKS5 users are missing")
        val account = users.optJSONObject(0)
            ?: throw IllegalStateException("Secure SOCKS5 account is missing")
        val port = inbound.opt("port")
        val username = account.opt("user")
        val password = account.opt("pass")
        if (inbound.optString("tag") != "revolt-secure-socks" ||
            inbound.optString("protocol") != "socks" ||
            inbound.optString("listen") != "127.0.0.1" ||
            port !is Int || port <= 1024 || port > 65535 ||
            settings.optString("auth") != "password" ||
            settings.optBoolean("udp", false).not() ||
            settings.optString("ip") != "127.0.0.1" ||
            users.length() != 1 ||
            username !is String || username.isEmpty() ||
            password !is String || password.isEmpty()
        ) {
            throw IllegalStateException("Secure SOCKS5 session is invalid")
        }
        config.LOCAL_SOCKS5_PORT = port
        config.LOCAL_HTTP_PORT = 0
        return configJson
    }

    fun startCore(context: Service, config: XrayConfig): Boolean {
        AppConfigs.RUNTIME_READY = false
        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING
        AppConfigs.V2RAY_CONFIG = config

        val filesDir = context.filesDir
        if (!removeLegacyConfig(filesDir)) {
            Log.e(TAG, "Refusing to start while legacy plaintext config cannot be removed")
            return false
        }

        val runtimeConfig = try {
            buildRuntimeConfigJson(config, filesDir).toString()
        } catch (error: Exception) {
            Log.e(TAG, "Failed to prepare Xray config", error)
            return false
        }

        val xrayExecutable = File(context.applicationInfo.nativeLibraryDir, "libxray.so")
        if (!xrayExecutable.exists()) {
            Log.e(TAG, "Xray executable not found at ${xrayExecutable.absolutePath}")
            return false
        }

        try {
            Utilities.copyAssets(context)
        } catch (error: Exception) {
            Log.e(TAG, "Failed to prepare Xray assets", error)
            return false
        }

        val process = try {
            ProcessBuilder(
                xrayExecutable.absolutePath,
                "run",
                "-config",
                "stdin:",
                "-format",
                "json",
            ).apply {
                directory(filesDir)
                redirectErrorStream(true)
                environment()["XRAY_LOCATION_ASSET"] = Utilities.getUserAssetsPath(context)
            }.start()
        } catch (error: Exception) {
            Log.e(TAG, "Failed to start Xray process", error)
            return false
        }

        try {
            CoreConfigPipe.writeAndClose(process, runtimeConfig)
        } catch (error: Exception) {
            Log.e(TAG, "Failed to deliver Xray config through stdin", error)
            try {
                process.destroy()
            } catch (_: Exception) {
            }
            AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED
            return false
        }

        if (!process.isAlive) {
            Log.e(TAG, "Xray process exited during startup")
            AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED
            return false
        }

        xrayProcess = process
        AppConfigs.RUNTIME_READY = false
        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING
        startTimer(context)
        showNotification(context, config)
        sendStatusBroadcast(context, config)

        Thread({
            try {
                process.inputStream.bufferedReader().use { reader ->
                    reader.forEachLine { _ -> }
                }
                val exitCode = process.waitFor()
                Log.e(TAG, "Xray process exited with code $exitCode")
                if (xrayProcess === process &&
                    AppConfigs.V2RAY_CONFIG?.RUNTIME_TOKEN == config.RUNTIME_TOKEN &&
                    (AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED ||
                        AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTING)
                ) {
                    xrayProcess = null
                    AppConfigs.RUNTIME_READY = false
                    AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING
                    sendStatusBroadcast(context, config)
                    if (context is XrayVPNService) {
                        context.handleXrayCoreExit(config)
                    } else {
                        stopCore(context)
                    }
                }
            } catch (_: java.io.InterruptedIOException) {
            } catch (_: InterruptedException) {
            } catch (error: Exception) {
                Log.e(TAG, "Error reading Xray output", error)
            }
        }, "revolt-xray-monitor").start()

        return true
    }

    fun stopCore(
        context: Service,
        confirmationToken: String? = AppConfigs.V2RAY_CONFIG?.RUNTIME_TOKEN,
    ) {
        try {
            xrayProcess?.destroy()
            xrayProcess = null
        } catch (error: Exception) {
            Log.e(TAG, "Failed to destroy Xray process", error)
        }
        AppConfigs.RUNTIME_READY = false
        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED
        stopTimer()
        val notificationManager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.cancel(NOTIFICATION_ID)
        sendDisconnectedBroadcast(context, confirmationToken.orEmpty())
        AppConfigs.V2RAY_CONFIG = null
    }

    fun markRuntimeConnecting(context: Context, config: XrayConfig) {
        if (AppConfigs.V2RAY_CONFIG?.RUNTIME_TOKEN != config.RUNTIME_TOKEN) return
        AppConfigs.RUNTIME_READY = false
        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING
        sendStatusBroadcast(context, config)
    }

    fun markRuntimeReady(context: Service, config: XrayConfig) {
        if (AppConfigs.V2RAY_CONFIG?.RUNTIME_TOKEN != config.RUNTIME_TOKEN) return
        AppConfigs.RUNTIME_READY = true
        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTED
        showNotification(context, config)
        sendStatusBroadcast(context, config)
    }

    fun isXrayRunning(): Boolean =
        AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED ||
            AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTING

    private fun startTimer(context: Context) {
        countDownTimer?.cancel()
        seconds = 0
        countDownTimer = object : CountDownTimer(Long.MAX_VALUE, 1000) {
            override fun onTick(millisUntilFinished: Long) {
                seconds++
                val config = AppConfigs.V2RAY_CONFIG ?: return
                sendStatusBroadcast(context, config)
            }
            override fun onFinish() = Unit
        }.start()
    }

    private fun stopTimer() {
        countDownTimer?.cancel()
        countDownTimer = null
        seconds = 0
    }

    fun sendStatusBroadcast(context: Context, config: XrayConfig) {
        val intent = Intent(AppConfigs.V2RAY_CONNECTION_INFO)
            .setPackage(context.packageName)
            .putExtra("STATE", AppConfigs.V2RAY_STATE)
            .putExtra("RUNTIME_TOKEN", config.RUNTIME_TOKEN)
            .putExtra("RUNTIME_READY", AppConfigs.RUNTIME_READY)
            .putExtra("DURATION", seconds.toString())
            .putExtra("UPLOAD_SPEED", 0L)
            .putExtra("DOWNLOAD_SPEED", 0L)
            .putExtra("UPLOAD_TRAFFIC", 0L)
            .putExtra("DOWNLOAD_TRAFFIC", 0L)
        context.sendBroadcast(intent)
    }

    private fun sendDisconnectedBroadcast(context: Context, runtimeToken: String) {
        val intent = Intent(AppConfigs.V2RAY_CONNECTION_INFO)
            .setPackage(context.packageName)
            .putExtra("STATE", AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED)
            .putExtra("RUNTIME_TOKEN", runtimeToken)
            .putExtra("RUNTIME_READY", false)
            .putExtra("DURATION", "0")
            .putExtra("UPLOAD_SPEED", 0L)
            .putExtra("DOWNLOAD_SPEED", 0L)
            .putExtra("UPLOAD_TRAFFIC", 0L)
            .putExtra("DOWNLOAD_TRAFFIC", 0L)
        context.sendBroadcast(intent)
    }

    private fun showNotification(context: Service, config: XrayConfig) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ActivityCompat.checkSelfPermission(
                context,
                android.Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        val channelId = createNotificationChannel(context, config.APPLICATION_NAME)
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        launchIntent?.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or
            Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_NEW_TASK
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val contentPendingIntent = PendingIntent.getActivity(context, 0, launchIntent, flags)
        val stopIntent = Intent(context, XrayVPNService::class.java)
            .putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)
            .putExtra("RUNTIME_TOKEN", config.RUNTIME_TOKEN)
        val stopPendingIntent = PendingIntent.getService(context, 0, stopIntent, flags)
        val smallIcon = if (config.APPLICATION_ICON != 0) {
            config.APPLICATION_ICON
        } else {
            android.R.drawable.ic_dialog_info
        }

        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(smallIcon)
            .setContentTitle(config.REMARK)
            .setContentText(if (AppConfigs.RUNTIME_READY) "Connected" else "Connecting")
            .addAction(0, config.NOTIFICATION_DISCONNECT_BUTTON_NAME, stopPendingIntent)
            .setContentIntent(contentPendingIntent)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOngoing(true)
            .setShowWhen(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .build()
        context.startForeground(NOTIFICATION_ID, notification)
    }

    private fun createNotificationChannel(context: Context, appName: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channelId = "REVOLT_VPN_SERVICE"
            val channel = NotificationChannel(
                channelId,
                "$appName Background Service",
                NotificationManager.IMPORTANCE_LOW,
            )
            channel.lightColor = Color.BLUE
            channel.lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
            return channelId
        }
        return ""
    }
}
