package com.paladinvpn.app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val installerChannel = "com.revoltvpn.app/installer"
    private val hapticsChannel = "com.revoltvpn.app/haptics"
    private val appsChannel = "com.revoltvpn.app/apps"
    private val routingChannel = "com.revoltvpn.app/app_routing"
    private val networkChannel = "com.revoltvpn.app/network"

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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, hapticsChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "impact") {
                    val kind = call.argument<String>("kind") ?: "tap"
                    result.success(performHaptic(kind))
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, appsChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "getLaunchableApps") {
                    result.success(launchableApps())
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, routingChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val requested = call.argument<List<String>>("packages").orEmpty()
                        val packages = installedPackages(requested)
                        if (packages.isEmpty()) {
                            result.error(
                                "NO_APPS",
                                "No selected applications are installed.",
                                null,
                            )
                            return@setMethodCallHandler
                        }

                        val intent = Intent(this, AppRoutingVpnService::class.java).apply {
                            action = AppRoutingVpnService.ACTION_START
                            putStringArrayListExtra(
                                AppRoutingVpnService.EXTRA_PACKAGES,
                                ArrayList(packages),
                            )
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    }

                    "stop" -> {
                        stopService(Intent(this, AppRoutingVpnService::class.java))
                        result.success(null)
                    }

                    else -> result.notImplemented()
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

    private fun startNetworkMonitor() {
        if (networkCallback != null) return

        val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                emitNetworkState(manager, network, "available")
            }

            override fun onLost(network: Network) {
                emitNetworkState(manager, null, "lost")
            }

            override fun onCapabilitiesChanged(
                network: Network,
                capabilities: NetworkCapabilities,
            ) {
                emitNetworkState(manager, network, "changed", capabilities)
            }
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                manager.registerDefaultNetworkCallback(callback)
            } else {
                val request = NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .build()
                manager.registerNetworkCallback(request, callback)
            }
            networkCallback = callback

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                emitNetworkState(manager, manager.activeNetwork, "initial")
            } else {
                emitLegacyNetworkState(manager, "initial")
            }
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

    private fun emitNetworkState(
        manager: ConnectivityManager,
        network: Network?,
        reason: String,
        providedCapabilities: NetworkCapabilities? = null,
    ) {
        val capabilities = providedCapabilities ?: network?.let { manager.getNetworkCapabilities(it) }
        val transport = when {
            capabilities == null -> "none"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
            else -> "other"
        }
        val validated = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
        } else {
            network != null && capabilities != null
        }

        emitNetworkPayload(
            mapOf<String, Any>(
                "reason" to reason,
                "transport" to transport,
                "connected" to (network != null && capabilities != null),
                "validated" to validated,
                "metered" to manager.isActiveNetworkMetered,
                "timestamp" to System.currentTimeMillis(),
            ),
        )
    }

    @Suppress("DEPRECATION")
    private fun emitLegacyNetworkState(manager: ConnectivityManager, reason: String) {
        val info = manager.activeNetworkInfo
        val connected = info?.isConnected == true
        val transport = when (info?.type) {
            ConnectivityManager.TYPE_WIFI -> "wifi"
            ConnectivityManager.TYPE_MOBILE -> "cellular"
            ConnectivityManager.TYPE_ETHERNET -> "ethernet"
            else -> if (connected) "other" else "none"
        }

        emitNetworkPayload(
            mapOf<String, Any>(
                "reason" to reason,
                "transport" to transport,
                "connected" to connected,
                "validated" to connected,
                "metered" to manager.isActiveNetworkMetered,
                "timestamp" to System.currentTimeMillis(),
            ),
        )
    }

    private fun emitNetworkPayload(payload: Map<String, Any>) {
        runOnUiThread {
            networkEvents?.success(payload)
        }
    }

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

    private fun launchableApps(): List<Map<String, Any>> {
        val intent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }

        val resolved = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.queryIntentActivities(
                intent,
                PackageManager.ResolveInfoFlags.of(0L),
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.queryIntentActivities(intent, 0)
        }

        return resolved
            .mapNotNull { info ->
                val appPackage = info.activityInfo?.packageName ?: return@mapNotNull null
                if (appPackage == packageName) return@mapNotNull null

                val item = mutableMapOf<String, Any>(
                    "packageName" to appPackage,
                    "label" to info.loadLabel(packageManager).toString(),
                )
                appIconPng(info)?.let { item["icon"] = it }
                item
            }
            .distinctBy { it["packageName"] as String }
            .sortedBy { (it["label"] as String).lowercase() }
    }

    @Suppress("DEPRECATION")
    private fun installedPackages(requested: List<String>): List<String> {
        return requested
            .map(String::trim)
            .filter(String::isNotEmpty)
            .distinct()
            .filter { appPackage ->
                if (appPackage == packageName) return@filter false
                try {
                    packageManager.getApplicationInfo(appPackage, 0)
                    true
                } catch (_: PackageManager.NameNotFoundException) {
                    false
                }
            }
    }

    private fun appIconPng(info: ResolveInfo): ByteArray? = try {
        val drawable = info.loadIcon(packageManager)
        val density = resources.displayMetrics.density
        val size = (48f * density).roundToInt().coerceIn(48, 144)
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)

        ByteArrayOutputStream().use { output ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
            output.toByteArray()
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
        } catch (e: Exception) {
            false
        }
    }
}
