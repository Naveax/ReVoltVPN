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
import org.json.JSONObject
import org.json.JSONArray
import java.io.File

/**
 * Manages the Xray Core process (libxray.so).
 * 
 * This singleton object is responsible for:
 * 1. Validating the authenticated loopback ingress and normalizing configuration.
 * 2. Starting and monitoring the Xray process.
 * 3. Reporting runtime state and showing the foreground notification.
 */
object XrayCoreManager {

    private const val NOTIFICATION_ID = 1
    private const val TAG = "XrayCoreManager"
    private var xrayProcess: Process? = null
    private var countDownTimer: CountDownTimer? = null
    private var seconds = 0

    private fun deleteEphemeralConfigOnFailure(filesDir: File) {
        try {
            val config = File(filesDir, "config.json")
            if (config.exists() && !config.delete()) {
                Log.w(TAG, "Could not delete failed ephemeral Xray config")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not delete failed ephemeral Xray config", e)
        }
    }

    private fun normalizeRuntimeConfig(value: Any?): Any? {
        return when (value) {
            is JSONObject -> {
                val normalized = JSONObject()
                val aliases = mapOf(
                    "xHTTPSettings" to "xhttpSettings",
                    "httpUpgradeSettings" to "httpupgradeSettings",
                    "splitHTTPSettings" to "splithttpSettings"
                )
                val keys = value.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    if (key == "allowInsecure") continue

                    val targetKey = aliases[key] ?: key
                    if (aliases.containsKey(key) && value.has(targetKey)) continue

                    val normalizedValue = normalizeRuntimeConfig(value.opt(key))
                    if (targetKey == "network" && normalizedValue is String) {
                        normalized.put(targetKey, normalizedValue.lowercase())
                    } else {
                        normalized.put(targetKey, normalizedValue)
                    }
                }
                normalized
            }
            is JSONArray -> {
                val normalized = JSONArray()
                for (i in 0 until value.length()) {
                    normalized.put(normalizeRuntimeConfig(value.opt(i)))
                }
                normalized
            }
            else -> value
        }
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
            user.put("id", id)
            user.put("encryption", settings.optString("encryption", "none"))
            user.put("flow", settings.optString("flow", ""))
            user.put("level", settings.optInt("level", 8))

            val server = JSONObject()
            server.put("address", address)
            server.put("port", port)
            server.put("users", JSONArray().put(user))

            val normalizedSettings = JSONObject()
            normalizedSettings.put("vnext", JSONArray().put(server))
            outbound.put("settings", normalizedSettings)
            Log.d(TAG, "Normalized flat VLESS outbound settings for $address:$port")
        }
    }

    private fun sanitizeLogPaths(configJson: JSONObject, filesDir: File) {
        val log = configJson.optJSONObject("log") ?: return

        // The VPN client never needs destination/access logs. A server-provided
        // config must not silently enable browsing metadata collection locally.
        log.remove("access")
        try { File(filesDir, "access.log").delete() } catch (_: Exception) {}

        val errorPath = log.optString("error")
        if (errorPath.isNotEmpty()) {
            log.put("error", File(filesDir, "error.log").absolutePath)
        }
    }

    internal fun buildRuntimeConfigJson(config: XrayConfig, filesDir: File): JSONObject {
        val configJson = normalizeRuntimeConfig(
            JSONObject(config.V2RAY_FULL_JSON_CONFIG)
        ) as JSONObject
        normalizeVlessOutbounds(configJson)
        sanitizeLogPaths(configJson, filesDir)

        // This vendored runtime accepts exactly the ingress produced by
        // SecureSocksSession. Missing or additional listeners fail closed;
        // never manufacture a legacy unauthenticated proxy.
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

    /**
     * Starts the Xray Core process.
     * 
     * @param context The service context (needed for file access and notifications).
     * @param config The configuration object containing the user's settings.
     * @return true if started successfully, false otherwise.
     */
    fun startCore(context: Service, config: XrayConfig): Boolean {
        AppConfigs.RUNTIME_READY = false
        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING
        AppConfigs.V2RAY_CONFIG = config

        // 1. Prepare the configuration file
        val configFilesDir = context.filesDir
        
        try {
            val configJson = buildRuntimeConfigJson(config, configFilesDir)
            val configFile = File(context.filesDir, "config.json")
            configFile.writeText(configJson.toString())
        } catch (e: Exception) {
            Log.e(TAG, "Failed to write config file", e)
            deleteEphemeralConfigOnFailure(configFilesDir)
            return false
        }

        // 2. Find Xray executable (libxray.so)
        val nativeLibraryDir = context.applicationInfo.nativeLibraryDir
        val xrayExecutable = File(nativeLibraryDir, "libxray.so")
        if (!xrayExecutable.exists()) {
            Log.e(TAG, "Xray executable not found at ${xrayExecutable.absolutePath}")
            deleteEphemeralConfigOnFailure(configFilesDir)
            return false
        }

        // 3. Prepare assets (geoip, geosite)
        try {
            Utilities.copyAssets(context)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to prepare Xray assets", e)
            deleteEphemeralConfigOnFailure(configFilesDir)
            return false
        }

        // 4. Run Xray
        try {
            val cmd = listOf(
                xrayExecutable.absolutePath,
                "-config", File(configFilesDir, "config.json").absolutePath
            )
            val pb = ProcessBuilder(cmd)
            pb.directory(configFilesDir)
            pb.redirectErrorStream(true)
            
            // Set environment variables (XRAY_LOCATION_ASSET is crucial for finding geoip/geosite)
            val env = pb.environment()
            env["XRAY_LOCATION_ASSET"] = Utilities.getUserAssetsPath(context)

            xrayProcess = pb.start()
            Thread.sleep(300)
            if (xrayProcess?.isAlive != true) {
                Log.e(TAG, "Xray process exited during startup")
                xrayProcess = null
                AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED
                deleteEphemeralConfigOnFailure(configFilesDir)
                return false
            }
            
            // config.json contains per-session SOCKS credentials. Xray has
            // consumed it after the startup liveness check, so remove it now.
            try {
                val ephemeralConfig = File(configFilesDir, "config.json")
                if (ephemeralConfig.exists() && !ephemeralConfig.delete()) {
                    Log.w(TAG, "Could not delete ephemeral Xray config")
                }
            } catch (e: Exception) {
                Log.w(TAG, "Could not delete ephemeral Xray config", e)
            }

            AppConfigs.RUNTIME_READY = false
            AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING
            startTimer(context)
            showNotification(context, config)
            sendStatusBroadcast(context, config)
            
            val process = xrayProcess ?: return false
            // Monitor process in a separate thread to detect crash
            Thread {
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
                        // Hold the Android TUN while the core is recovered. Killing
                        // the VPN service here would allow direct-network fallback.
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
                } catch (e: java.io.InterruptedIOException) {
                    // Expected when stopping
                } catch (e: InterruptedException) {
                    // Expected when stopping
                } catch (e: Exception) {
                    Log.e(TAG, "Error reading xray output", e)
                }
            }.start()

            return true

        } catch (e: Exception) {
            Log.e(TAG, "Failed to start Xray process", e)
            deleteEphemeralConfigOnFailure(configFilesDir)
            return false
        }
    }

    /**
     * Stops the Xray Core process and cleans up notifications.
     */
    fun stopCore(context: Service, confirmationToken: String? = AppConfigs.V2RAY_CONFIG?.RUNTIME_TOKEN) {
        try {
            xrayProcess?.destroy()
            xrayProcess = null
        } catch (e: Exception) {
            Log.e(TAG, "Failed to destroy Xray process", e)
        }

        AppConfigs.RUNTIME_READY = false
        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED
        stopTimer()
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
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

    fun isXrayRunning(): Boolean {
        // Check state instead of process because VPN runs in separate service process
        return AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED ||
               AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTING
    }

    private fun startTimer(context: Context) {
        countDownTimer?.cancel()
        seconds = 0
        countDownTimer = object : CountDownTimer(Long.MAX_VALUE, 1000) {
            override fun onTick(millisUntilFinished: Long) {
                seconds++
                val intent = Intent(AppConfigs.V2RAY_CONNECTION_INFO).setPackage(context.packageName)
                intent.putExtra("STATE", AppConfigs.V2RAY_STATE)
                intent.putExtra("RUNTIME_TOKEN", AppConfigs.V2RAY_CONFIG?.RUNTIME_TOKEN.orEmpty())
                intent.putExtra("RUNTIME_READY", AppConfigs.RUNTIME_READY)
                intent.putExtra("DURATION", seconds.toString())
                
                intent.putExtra("UPLOAD_SPEED", 0L)
                intent.putExtra("DOWNLOAD_SPEED", 0L)
                intent.putExtra("UPLOAD_TRAFFIC", 0L)
                intent.putExtra("DOWNLOAD_TRAFFIC", 0L)
                
                context.sendBroadcast(intent)
            }

            override fun onFinish() {}
        }.start()
    }

    private fun stopTimer() {
        countDownTimer?.cancel()
        countDownTimer = null
        seconds = 0
    }

    fun sendStatusBroadcast(context: Context, config: XrayConfig) {
        val intent = Intent(AppConfigs.V2RAY_CONNECTION_INFO).setPackage(context.packageName)
        intent.putExtra("STATE", AppConfigs.V2RAY_STATE)
        intent.putExtra("RUNTIME_TOKEN", config.RUNTIME_TOKEN)
        intent.putExtra("RUNTIME_READY", AppConfigs.RUNTIME_READY)
        intent.putExtra("DURATION", seconds.toString())
        intent.putExtra("UPLOAD_SPEED", 0L)
        intent.putExtra("DOWNLOAD_SPEED", 0L)
        intent.putExtra("UPLOAD_TRAFFIC", 0L)
        intent.putExtra("DOWNLOAD_TRAFFIC", 0L)
        context.sendBroadcast(intent)
    }

    private fun sendDisconnectedBroadcast(context: Context, runtimeToken: String) {
        val intent = Intent(AppConfigs.V2RAY_CONNECTION_INFO).setPackage(context.packageName)
        intent.putExtra("STATE", AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED)
        intent.putExtra("RUNTIME_TOKEN", runtimeToken)
        intent.putExtra("RUNTIME_READY", false)
        intent.putExtra("DURATION", "0")
        intent.putExtra("UPLOAD_SPEED", 0L)
        intent.putExtra("DOWNLOAD_SPEED", 0L)
        intent.putExtra("UPLOAD_TRAFFIC", 0L)
        intent.putExtra("DOWNLOAD_TRAFFIC", 0L)
        context.sendBroadcast(intent)
    }

    private fun showNotification(context: Service, config: XrayConfig) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ActivityCompat.checkSelfPermission(context, android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                return
            }
        }

        val channelId = createNotificationChannel(context, config.APPLICATION_NAME)
        
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        launchIntent?.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_NEW_TASK
        
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT else PendingIntent.FLAG_UPDATE_CURRENT
        val contentPendingIntent = PendingIntent.getActivity(context, 0, launchIntent, flags)

        val stopIntent = Intent(context, XrayVPNService::class.java)
        stopIntent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)
        stopIntent.putExtra("RUNTIME_TOKEN", config.RUNTIME_TOKEN)
        val stopPendingIntent = PendingIntent.getService(context, 0, stopIntent, flags)
        val smallIcon = if (config.APPLICATION_ICON != 0) config.APPLICATION_ICON else android.R.drawable.ic_dialog_info

        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(smallIcon)
            .setContentTitle(config.REMARK)
            .setContentText(if (AppConfigs.RUNTIME_READY) "Connected" else "Connecting")
            .addAction(0, config.NOTIFICATION_DISCONNECT_BUTTON_NAME, stopPendingIntent)
            .setContentIntent(contentPendingIntent)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOngoing(true)
            .setShowWhen(true)

        context.startForeground(NOTIFICATION_ID, builder.build())
    }

    private fun createNotificationChannel(context: Context, appName: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channelId = "REVOLT_VPN_SERVICE"
            val channelName = "$appName Background Service"
            val channel = NotificationChannel(channelId, channelName, NotificationManager.IMPORTANCE_LOW)
            channel.lightColor = Color.BLUE
            channel.lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
            return channelId
        }
        return ""
    }
}
