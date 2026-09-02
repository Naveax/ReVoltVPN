package com.paladinvpn.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.ActivityManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.github.tfox.flutter_vless.xray.service.XrayVPNService
import com.github.tfox.flutter_vless.xray.utils.AppConfigs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val installerChannel = "com.revoltvpn.app/installer"
    private val notificationChannel = "com.revoltvpn.app/notification"
    private val hapticsChannel = "com.revoltvpn.app/haptics"
    private val networkChannel = "com.revoltvpn.app/network"
    private val powerChannel = "com.revoltvpn.app/power"

    private var notificationChannelReady = false
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var networkEvents: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, installerChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "getInstallerPackage") {
                    result.success(installerPackage())
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, powerChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Doze and App Standby stop background services of apps that
                    // are not exempt. A VPN has to be exempt to survive the screen
                    // going off, so surface the real state rather than guessing.
                    "isIgnoringBatteryOptimizations" ->
                        result.success(isIgnoringBatteryOptimizations())
                    "requestIgnoreBatteryOptimizations" ->
                        result.success(requestIgnoreBatteryOptimizations())
                    "setSessionExpiry" -> {
                        val expiresAtMs = call.argument<Number>("expiresAtMs")?.toLong() ?: 0L
                        if (expiresAtMs > 0) {
                            sendSessionExpiryToDaemon(expiresAtMs)
                        }
                        result.success(null)
                    }
                    // Is our VPN runtime actually alive? The service lives in
                    // :RunSoLibXrayDaemon, a separate process, so its statics are
                    // NOT visible here -- this is the only honest check.
                    "isVpnRuntimeAlive" -> result.success(isVpnRuntimeAlive())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, notificationChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "updateNotificationText") {
                    val text = call.argument<String>("text") ?: ""
                    val title = call.argument<String>("title") ?: "Revolt VPN"
                    val action = call.argument<String>("disconnectLabel") ?: "Disconnect"
                    updateVpnNotification(title, text, action)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, hapticsChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "impact") {
                    val kind = call.argument<String>("kind") ?: "tap"
                    result.success(performHaptic(kind))
                } else {
                    result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, networkChannel)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    networkEvents = events
                    startNetworkMonitor()
                }

                override fun onCancel(arguments: Any?) {
                    networkEvents = null
                    stopNetworkMonitor()
                }
            })
    }

    override fun onDestroy() {
        stopNetworkMonitor()
        super.onDestroy()
    }

    /** True when the OS has exempted us from Doze / App Standby. */
    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            pm.isIgnoringBatteryOptimizations(packageName)
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Opens the system exemption prompt. Android shows this as a single dialog;
     * it cannot be granted silently, so the caller must treat a false return as
     * "ask again later" rather than a denial.
     */
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        if (isIgnoringBatteryOptimizations()) return true
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName"),
                ),
            )
            true
        } catch (_: Exception) {
            // Some OEM builds hide the direct intent; fall back to the list.
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                true
            } catch (_: Exception) {
                false
            }
        }
    }

    /** Pushes the session-expiry deadline to the VPN service process. */
    private fun sendSessionExpiryToDaemon(expiresAtMs: Long) {
        try {
            val intent = Intent(this, XrayVPNService::class.java)
            intent.putExtra("SESSION_EXPIRES_AT_MS", expiresAtMs)
            startService(intent)
        } catch (_: Exception) {
            // Daemon not reachable; its persisted expiry still applies.
        }
    }

    /**
     * Whether the VPN runtime is genuinely alive.
     *
     * The Xray service runs in :RunSoLibXrayDaemon, a separate process, so its
     * statics (AppConfigs.V2RAY_CONFIG, V2RAY_STATE) are NOT visible from here --
     * reading them yields a fresh, empty copy. getRunningAppProcesses still
     * returns our *own* processes, which makes it the one reliable signal.
     */
    private fun isVpnRuntimeAlive(): Map<String, Any> {
        var processAlive = false
        try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            processAlive = am.runningAppProcesses
                ?.any { it.processName.endsWith(VPN_PROCESS_SUFFIX) } == true
        } catch (_: Exception) {
        }

        var vpnTransport = false
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            vpnTransport = cm.allNetworks.any { network ->
                cm.getNetworkCapabilities(network)
                    ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
            }
        } catch (_: Exception) {
        }

        return mapOf(
            "processAlive" to processAlive,
            "vpnTransport" to vpnTransport,
        )
    }

    /** Removes a notification left behind by a runtime that is no longer alive. */
    private fun cancelVpnNotification() {
        try {
            NotificationManagerCompat.from(this).cancel(NOTIFICATION_ID)
        } catch (_: Exception) {
        }
    }

    private fun updateVpnNotification(title: String, text: String, actionLabel: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        // The foreground notification (id 1) is owned by XrayVPNService via
        // startForeground. Posting to it from this process while the service is
        // gone leaves a frozen countdown nothing will ever update again.
        val alive = isVpnRuntimeAlive()["processAlive"] == true
        if (!alive) {
            cancelVpnNotification()
            return
        }

        ensureNotificationChannel()

        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        launchIntent?.action = "FROM_DISCONNECT_BTN"
        launchIntent?.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or
            Intent.FLAG_ACTIVITY_CLEAR_TOP or
            Intent.FLAG_ACTIVITY_NEW_TASK

        val stopIntent = Intent(this, XrayVPNService::class.java)
        stopIntent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)
        val stopPendingIntent = PendingIntent.getService(this, 0, stopIntent, flags)

        // Public lock-screen preview: keep the VPN status visible but hide the
        // session countdown/speed so usage metadata never reaches the lock screen.
        val publicVersion = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.drawable.notification_status_icon)
            .setContentTitle("Revolt VPN")
            .setContentText("VPN is active")
            .build()

        val builder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.drawable.notification_status_icon)
            .setContentTitle(title)
            .setContentText(text)
            .addAction(0, actionLabel, stopPendingIntent)
            .setColorized(true)
            .setColor(0xFF0D1117.toInt())
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion)

        if (launchIntent != null) {
            builder.setContentIntent(PendingIntent.getActivity(this, 0, launchIntent, flags))
        }

        try {
            val notification = builder.build()
            notification.flags = notification.flags or
                Notification.FLAG_ONGOING_EVENT or Notification.FLAG_NO_CLEAR
            NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, notification)
        } catch (_: Exception) {
            // The native foreground notification may not be ready yet.
        }
    }

    private fun ensureNotificationChannel() {
        if (notificationChannelReady) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Revolt VPN Background Service",
                NotificationManager.IMPORTANCE_LOW,
            )
            channel.setShowBadge(false)
            manager.createNotificationChannel(channel)
        }
        notificationChannelReady = true
    }

    private fun startNetworkMonitor() {
        if (networkCallback != null) return

        val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                emitBestPhysicalNetwork(manager, "available")
            }

            override fun onLost(network: Network) {
                emitBestPhysicalNetwork(manager, "lost")
            }

            override fun onCapabilitiesChanged(
                network: Network,
                capabilities: NetworkCapabilities,
            ) {
                emitBestPhysicalNetwork(manager, "changed")
            }
        }

        try {
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
            manager.registerNetworkCallback(request, callback)
            networkCallback = callback
            emitBestPhysicalNetwork(manager, "initial")
        } catch (e: Exception) {
            networkEvents?.error("NETWORK_MONITOR", e.message, null)
        }
    }

    private fun stopNetworkMonitor() {
        val callback = networkCallback ?: return
        val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        try {
            manager.unregisterNetworkCallback(callback)
        } catch (_: Exception) {
        }
        networkCallback = null
    }

    private fun emitBestPhysicalNetwork(
        manager: ConnectivityManager,
        reason: String,
    ) {
        val best = manager.allNetworks
            .mapNotNull { network ->
                val capabilities = manager.getNetworkCapabilities(network)
                    ?: return@mapNotNull null
                if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                    return@mapNotNull null
                }
                if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) ||
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
                ) {
                    return@mapNotNull null
                }
                Triple(network, capabilities, physicalNetworkScore(capabilities))
            }
            .maxByOrNull { it.third }

        if (best == null) {
            emitNetworkPayload(
                mapOf<String, Any>(
                    "reason" to reason,
                    "transport" to "none",
                    "connected" to false,
                    "validated" to false,
                    "metered" to false,
                    "timestamp" to System.currentTimeMillis(),
                ),
            )
            return
        }

        emitNetworkState(best.first, best.second, reason)
    }

    private fun physicalNetworkScore(capabilities: NetworkCapabilities): Int {
        var score = 0
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        ) {
            score += 100
        }
        score += when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 40
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 30
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 20
            else -> 10
        }
        return score
    }

    private fun emitNetworkState(
        network: Network,
        capabilities: NetworkCapabilities,
        reason: String,
    ) {
        val transport = when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            else -> "other"
        }
        val validated = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        val metered = !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)

        emitNetworkPayload(
            mapOf<String, Any>(
                "reason" to reason,
                "transport" to transport,
                "connected" to true,
                "validated" to validated,
                "metered" to metered,
                "timestamp" to System.currentTimeMillis(),
            ),
        )
    }

    private fun emitNetworkPayload(payload: Map<String, Any>) {
        runOnUiThread { networkEvents?.success(payload) }
    }

    private fun installerPackage(): String? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            packageManager.getInstallSourceInfo(packageName).installingPackageName
        } else {
            @Suppress("DEPRECATION")
            packageManager.getInstallerPackageName(packageName)
        }
    } catch (_: Exception) {
        null
    }

    private fun performHaptic(kind: String): Boolean {
        return try {
            val vibrator: Vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val manager =
                    getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                manager.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }

            if (!vibrator.hasVibrator()) {
                false
            } else {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val effect = when (kind) {
                        "selection" -> VibrationEffect.EFFECT_TICK
                        "success" -> VibrationEffect.EFFECT_HEAVY_CLICK
                        else -> VibrationEffect.EFFECT_CLICK
                    }
                    vibrator.vibrate(VibrationEffect.createPredefined(effect))
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val durationMs = if (kind == "success") 24L else 14L
                    val amplitude = if (kind == "success") 110 else 70
                    vibrator.vibrate(VibrationEffect.createOneShot(durationMs, amplitude))
                } else {
                    @Suppress("DEPRECATION")
                    vibrator.vibrate(if (kind == "success") 24L else 14L)
                }
                true
            }
        } catch (_: Exception) {
            false
        }
    }

    companion object {
        private const val NOTIFICATION_ID = 1
        private const val VPN_PROCESS_SUFFIX = ":RunSoLibXrayDaemon"
        private const val NOTIFICATION_CHANNEL_ID = "XRAY_SERVICE_CHANNEL"
    }
}
