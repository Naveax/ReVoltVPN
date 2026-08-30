package com.paladinvpn.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.github.tfox.flutter_vless.xray.service.XrayVPNService
import com.github.tfox.flutter_vless.xray.utils.AppConfigs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    // Channel id only — not the application id, which is com.paladinvpn.app.
    // Must match the string in lib/logic/updater.dart.
    private val installerChannel = "com.revoltvpn.app/installer"

    // Must match lib/logic/notification_service.dart.
    private val notificationChannel = "com.revoltvpn.app/notification"

    private var notificationChannelReady = false

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
    }

    /**
     * Sets the session countdown as the VPN notification's content text.
     *
     * notify() is per-package, so re-posting flutter_vless's notification id
     * replaces it wholesale — every field the plugin set has to be rebuilt
     * here or it is dropped, the Disconnect action most of all. Keep in sync
     * with XrayCoreManager.showNotification().
     */
    private fun updateVpnNotification(title: String, text: String, actionLabel: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        ensureNotificationChannel()

        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

        // Same intent shape as the plugin, so a tap brings the running task
        // forward instead of starting a second one.
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        launchIntent?.action = "FROM_DISCONNECT_BTN"
        launchIntent?.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or
            Intent.FLAG_ACTIVITY_CLEAR_TOP or
            Intent.FLAG_ACTIVITY_NEW_TASK

        // Tapping "Disconnect" stops the tunnel without opening the app.
        val stopIntent = Intent(this, XrayVPNService::class.java)
        stopIntent.putExtra(
            "COMMAND",
            AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE
        )
        val stopPendingIntent = PendingIntent.getService(this, 0, stopIntent, flags)

        val builder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.drawable.notification_icon)
            .setContentTitle(title)
            .setContentText(text)
            .addAction(0, actionLabel, stopPendingIntent)
            .setColorized(true)
            .setColor(0xFF0D1117.toInt())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)

        if (launchIntent != null) {
            builder.setContentIntent(
                PendingIntent.getActivity(this, 0, launchIntent, flags)
            )
        }

        try {
            NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, builder.build())
        } catch (_: Exception) {
            // The foreground notification may not be up yet — the update is cosmetic.
        }
    }

    /** A binder round-trip, and the caller runs once a second — so, once per process. */
    private fun ensureNotificationChannel() {
        if (notificationChannelReady) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Revolt VPN Background Service",
                NotificationManager.IMPORTANCE_LOW
            )
            channel.setShowBadge(false)
            manager.createNotificationChannel(channel)
        }
        notificationChannelReady = true
    }

    /**
     * Package name of whatever installed us ("com.android.vending" for Play
     * Store), or null when unknown. Without this the Dart side always falls
     * back to sideload and points every user at GitHub releases.
     */
    private fun installerPackage(): String? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            packageManager.getInstallSourceInfo(packageName).installingPackageName
        } else {
            @Suppress("DEPRECATION")
            packageManager.getInstallerPackageName(packageName)
        }
    } catch (e: Exception) {
        null
    }

    companion object {
        // Must match flutter_vless's XrayCoreManager.
        private const val NOTIFICATION_ID = 1
        private const val NOTIFICATION_CHANNEL_ID = "XRAY_SERVICE_CHANNEL"
    }
}
