package com.github.tfox.flutter_vless.xray.core

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
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
import java.io.InputStream
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.util.UUID
import java.util.concurrent.TimeUnit

object XrayCoreManager {
    private const val NOTIFICATION_ID = 1
    private const val TAG = "XrayCoreManager"
    private val processLock = Any()
    private var xrayProcess: Process? = null
    private var activeGeneration = 0L
    private var countDownTimer: CountDownTimer? = null
    private var seconds = 0

    private fun normalizeRuntimeConfig(value: Any?): Any? = when (value) {
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
                normalized.put(
                    targetKey,
                    if (targetKey == "network" && normalizedValue is String) {
                        normalizedValue.lowercase()
                    } else {
                        normalizedValue
                    }
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
        if (log.optString("access").isNotEmpty()) {
            log.put("access", File(filesDir, "access.log").absolutePath)
        }
        if (log.optString("error").isNotEmpty()) {
            log.put("error", File(filesDir, "error.log").absolutePath)
        }
    }

    private fun removeInboundScopedRules(configJson: JSONObject) {
        val routing = configJson.optJSONObject("routing") ?: return
        val source = routing.optJSONArray("rules") ?: return
        val clean = JSONArray()
        for (i in 0 until source.length()) {
            val rule = source.optJSONObject(i) ?: continue
            if (rule.has("inboundTag")) continue
            clean.put(rule)
        }
        routing.put("rules", clean)
    }

    internal fun buildRuntimeConfigJson(config: XrayConfig, filesDir: File): JSONObject {
        if (config.LOCAL_SOCKS5_PORT <= 0 ||
            config.LOCAL_SOCKS5_USER.isEmpty() ||
            config.LOCAL_SOCKS5_PASS.isEmpty()
        ) {
            throw IllegalStateException("Isolated SOCKS5 credentials are required")
        }

        val configJson = normalizeRuntimeConfig(
            JSONObject(config.V2RAY_FULL_JSON_CONFIG)
        ) as JSONObject
        normalizeVlessOutbounds(configJson)
        sanitizeLogPaths(configJson, filesDir)

        // ReVolt does not expose Xray's management API. Session/account usage is
        // obtained from the backend, so a localhost StatsService listener is an
        // unnecessary cross-app attack surface.
        configJson.remove("api")
        configJson.remove("stats")
        configJson.remove("policy")

        // No inbound supplied by a remote/server config is trusted. The app owns
        // the complete client-side listener surface and creates exactly one
        // authenticated loopback SOCKS5 ingress for tun2socks and local tests.
        config.LOCAL_HTTP_PORT = 0
        config.LOCAL_API_PORT = 0
        val socksSettings = JSONObject()
            .put("auth", "password")
            .put("udp", true)
            .put(
                "accounts",
                JSONArray().put(
                    JSONObject()
                        .put("user", config.LOCAL_SOCKS5_USER)
                        .put("pass", config.LOCAL_SOCKS5_PASS)
                )
            )

        val inbounds = JSONArray().put(
            JSONObject()
                .put("tag", "revolt-socks")
                .put("port", config.LOCAL_SOCKS5_PORT)
                .put("listen", "127.0.0.1")
                .put("protocol", "socks")
                .put("settings", socksSettings)
                .put(
                    "sniffing",
                    JSONObject()
                        .put("enabled", true)
                        .put("destOverride", JSONArray().put("http").put("tls"))
                )
        )
        configJson.put("inbounds", inbounds)
        removeInboundScopedRules(configJson)
        return configJson
    }

    fun startCore(context: XrayVPNService, config: XrayConfig, generation: Long): Boolean {
        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING
        AppConfigs.V2RAY_CONFIG = config
        AppConfigs.RUNTIME_GENERATION = generation
        AppConfigs.resetReadiness()

        val configFile = File(context.filesDir, "config.json")
        try {
            configFile.writeText(buildRuntimeConfigJson(config, context.filesDir).toString())
            Utilities.copyAssets(context)
        } catch (e: Exception) {
            AppConfigs.LAST_ERROR = "Failed to prepare Xray config"
            Log.e(TAG, AppConfigs.LAST_ERROR, e)
            return false
        }

        val xrayExecutable = File(context.applicationInfo.nativeLibraryDir, "libxray.so")
        if (!xrayExecutable.exists()) {
            AppConfigs.LAST_ERROR = "Xray executable missing"
            return false
        }

        return try {
            val pb = ProcessBuilder(xrayExecutable.absolutePath, "-config", configFile.absolutePath)
            pb.directory(context.filesDir)
            pb.redirectErrorStream(true)
            pb.environment()["XRAY_LOCATION_ASSET"] = Utilities.getUserAssetsPath(context)
            val process = pb.start()
            synchronized(processLock) {
                xrayProcess = process
                activeGeneration = generation
            }
            Thread.sleep(300)
            if (!process.isAlive) {
                val output = process.inputStream.bufferedReader().readText()
                Log.e(TAG, "Xray exited during startup: $output")
                synchronized(processLock) {
                    if (xrayProcess === process) xrayProcess = null
                }
                AppConfigs.LAST_ERROR = "Xray exited during startup"
                return false
            }

            Thread {
                try {
                    process.inputStream.bufferedReader().use { reader ->
                        reader.forEachLine { }
                    }
                    val exitCode = process.waitFor()
                    var unexpected = false
                    synchronized(processLock) {
                        if (xrayProcess === process && activeGeneration == generation) {
                            xrayProcess = null
                            unexpected =
                                AppConfigs.V2RAY_STATE != AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED
                        }
                    }
                    if (unexpected) {
                        Log.e(TAG, "Xray exited unexpectedly with code $exitCode")
                        context.handleXrayCoreExit(generation)
                    }
                } catch (_: InterruptedException) {
                } catch (e: Exception) {
                    Log.e(TAG, "Xray monitor failed", e)
                }
            }.start()
            true
        } catch (e: Exception) {
            AppConfigs.LAST_ERROR = "Failed to start Xray"
            Log.e(TAG, AppConfigs.LAST_ERROR, e)
            false
        }
    }

    fun markConnected(context: XrayVPNService, config: XrayConfig, generation: Long): Boolean {
        synchronized(processLock) {
            if (activeGeneration != generation || xrayProcess?.isAlive != true) return false
        }
        if (!AppConfigs.TUN_ESTABLISHED ||
            !AppConfigs.FD_DELIVERED ||
            !AppConfigs.SOCKS_READY
        ) return false
        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTED
        AppConfigs.LAST_ERROR = ""
        startTimer(context)
        showNotification(context, config)
        sendStateBroadcast(context)
        return true
    }

    fun markProxyOnlyConnected(context: XrayVPNService, config: XrayConfig, generation: Long): Boolean {
        synchronized(processLock) {
            if (activeGeneration != generation || xrayProcess?.isAlive != true) return false
        }
        if (!AppConfigs.SOCKS_READY) return false
        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTED
        AppConfigs.LAST_ERROR = ""
        startTimer(context)
        showNotification(context, config)
        sendStateBroadcast(context)
        return true
    }

    fun stopCore(context: XrayVPNService, broadcast: Boolean = true) {
        val process = synchronized(processLock) {
            val current = xrayProcess
            xrayProcess = null
            activeGeneration = 0L
            current
        }
        try {
            process?.destroy()
            if (process != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !process.waitFor(600, TimeUnit.MILLISECONDS)
            ) {
                process.destroyForcibly()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to stop Xray cleanly", e)
        }
        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED
        stopTimer()
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .cancel(NOTIFICATION_ID)
        if (broadcast) sendStateBroadcast(context)
    }

    fun isXrayRunning(): Boolean = synchronized(processLock) {
        xrayProcess?.isAlive == true
    }

    private fun startTimer(context: Context) {
        countDownTimer?.cancel()
        seconds = 0
        countDownTimer = object : CountDownTimer(Long.MAX_VALUE, 1000) {
            override fun onTick(millisUntilFinished: Long) {
                seconds++
                sendStateBroadcast(context)
            }
            override fun onFinish() = Unit
        }.start()
    }

    private fun stopTimer() {
        countDownTimer?.cancel()
        countDownTimer = null
        seconds = 0
    }

    fun sendStateBroadcast(
        context: Context,
        traffic: LongArray = longArrayOf(0, 0, 0, 0),
    ) {
        val config = AppConfigs.V2RAY_CONFIG
        val intent = Intent(AppConfigs.V2RAY_CONNECTION_INFO)
            .setPackage(context.packageName)
            .putExtra("STATE", AppConfigs.V2RAY_STATE)
            .putExtra("DURATION", seconds.toString())
            .putExtra("UPLOAD_SPEED", traffic.getOrElse(0) { 0L })
            .putExtra("DOWNLOAD_SPEED", traffic.getOrElse(1) { 0L })
            .putExtra("UPLOAD_TRAFFIC", traffic.getOrElse(2) { 0L })
            .putExtra("DOWNLOAD_TRAFFIC", traffic.getOrElse(3) { 0L })
            .putExtra("TUN_ESTABLISHED", AppConfigs.TUN_ESTABLISHED)
            .putExtra("FD_DELIVERED", AppConfigs.FD_DELIVERED)
            .putExtra("SOCKS_READY", AppConfigs.SOCKS_READY)
            .putExtra("RUNTIME_GENERATION", AppConfigs.RUNTIME_GENERATION)
            .putExtra("SOCKS_PORT", config?.LOCAL_SOCKS5_PORT ?: 0)
            .putExtra("SOCKS_USER", config?.LOCAL_SOCKS5_USER.orEmpty())
            .putExtra("SOCKS_PASS", config?.LOCAL_SOCKS5_PASS.orEmpty())
            .putExtra("LAST_ERROR", AppConfigs.LAST_ERROR)
        context.sendBroadcast(intent, AppConfigs.INTERNAL_STATUS_PERMISSION)
    }

    fun getV2rayTraffic(context: Context): LongArray {
        @Suppress("UNUSED_VARIABLE")
        val ignored = context
        return longArrayOf(0, 0, 0, 0)
    }

    private fun readExactly(input: InputStream, count: Int): ByteArray {
        val out = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val read = input.read(out, offset, count - offset)
            if (read < 0) throw IllegalStateException("SOCKS connection closed")
            offset += read
        }
        return out
    }

    fun probeSocks(
        port: Int,
        user: String,
        pass: String,
        targetHost: String? = null,
        targetPort: Int = 443,
        timeoutMs: Int = 2000
    ): Boolean {
        if (port <= 0 || user.isEmpty() || pass.isEmpty()) return false
        var socket: Socket? = null
        return try {
            socket = Socket()
            socket.connect(java.net.InetSocketAddress("127.0.0.1", port), timeoutMs)
            socket.soTimeout = timeoutMs
            val input = socket.getInputStream()
            val output = socket.getOutputStream()

            output.write(byteArrayOf(0x05, 0x01, 0x02))
            output.flush()
            val greeting = readExactly(input, 2)
            if (greeting[0].toInt() != 0x05 || greeting[1].toInt() != 0x02) return false
            val u = user.toByteArray(Charsets.UTF_8)
            val p = pass.toByteArray(Charsets.UTF_8)
            if (u.isEmpty() || u.size > 255 || p.isEmpty() || p.size > 255) return false
            output.write(byteArrayOf(0x01, u.size.toByte()))
            output.write(u)
            output.write(byteArrayOf(p.size.toByte()))
            output.write(p)
            output.flush()
            val auth = readExactly(input, 2)
            if (auth[0].toInt() != 0x01 || auth[1].toInt() != 0x00) return false

            if (targetHost != null) {
                val host = targetHost.toByteArray(Charsets.UTF_8)
                if (host.size > 255) return false
                output.write(byteArrayOf(0x05, 0x01, 0x00, 0x03, host.size.toByte()))
                output.write(host)
                output.write(
                    byteArrayOf(
                        ((targetPort shr 8) and 0xff).toByte(),
                        (targetPort and 0xff).toByte()
                    )
                )
                output.flush()
                val reply = readExactly(input, 4)
                if (reply[0].toInt() != 0x05 || reply[1].toInt() != 0x00) return false
            }
            true
        } catch (_: Exception) {
            false
        } finally {
            try { socket?.close() } catch (_: Exception) {}
        }
    }

    fun measureSocksDelay(port: Int, user: String, pass: String, url: String): Long {
        return try {
            val parsed = URL(url)
            val targetPort = if (parsed.port > 0) {
                parsed.port
            } else if (parsed.protocol == "http") {
                80
            } else {
                443
            }
            val started = System.currentTimeMillis()
            if (!probeSocks(port, user, pass, parsed.host, targetPort, 5000)) return -1L
            System.currentTimeMillis() - started
        } catch (_: Exception) {
            -1L
        }
    }

    fun getServerDelay(context: Context, configJson: String, url: String): Long {
        var process: Process? = null
        var tempFile: File? = null
        return try {
            val socksPort = ServerSocket(0).use { it.localPort }
            val delayUser = "rv_delay"
            val delayPass = UUID.randomUUID().toString()
            val config = XrayConfig(
                V2RAY_FULL_JSON_CONFIG = configJson,
                LOCAL_SOCKS5_PORT = socksPort,
                LOCAL_SOCKS5_USER = delayUser,
                LOCAL_SOCKS5_PASS = delayPass
            )
            tempFile = File(
                context.filesDir,
                "temp_delay_config_${System.nanoTime()}.json",
            )
            tempFile.writeText(buildRuntimeConfigJson(config, context.filesDir).toString())
            Utilities.copyAssets(context)
            val executable = File(context.applicationInfo.nativeLibraryDir, "libxray.so")
            if (!executable.exists()) return -1L
            val pb = ProcessBuilder(executable.absolutePath, "-config", tempFile.absolutePath)
            pb.directory(context.filesDir)
            pb.environment()["XRAY_LOCATION_ASSET"] = Utilities.getUserAssetsPath(context)
            process = pb.start()
            Thread.sleep(500)
            if (!process.isAlive) return -1L
            measureSocksDelay(config.LOCAL_SOCKS5_PORT, delayUser, delayPass, url)
        } catch (_: Exception) {
            -1L
        } finally {
            try { process?.destroy() } catch (_: Exception) {}
            try { tempFile?.delete() } catch (_: Exception) {}
        }
    }

    private fun showNotification(context: XrayVPNService, config: XrayConfig) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ActivityCompat.checkSelfPermission(
                context,
                android.Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) return

        val channelId = createNotificationChannel(context, config.APPLICATION_NAME)
        val launchIntent = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.apply {
                action = "FROM_DISCONNECT_BTN"
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_NEW_TASK
            }
        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        val contentPendingIntent = PendingIntent.getActivity(context, 0, launchIntent, flags)
        val stopIntent = Intent(context, XrayVPNService::class.java)
            .putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)
        val stopPendingIntent = PendingIntent.getService(context, 0, stopIntent, flags)
        val smallIcon = if (config.APPLICATION_ICON != 0) {
            config.APPLICATION_ICON
        } else {
            android.R.drawable.ic_dialog_info
        }
        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(smallIcon)
            .setContentTitle(config.REMARK)
            .setContentText("Connected")
            .addAction(0, config.NOTIFICATION_DISCONNECT_BUTTON_NAME, stopPendingIntent)
            .setContentIntent(contentPendingIntent)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOngoing(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .build()
        context.startForeground(NOTIFICATION_ID, notification)
    }

    private fun createNotificationChannel(context: Context, appName: String): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return ""
        val channelId = "XRAY_SERVICE_CHANNEL"
        val channel = NotificationChannel(
            channelId,
            "$appName Background Service",
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.lightColor = Color.BLUE
        channel.lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(channel)
        return channelId
    }
}
