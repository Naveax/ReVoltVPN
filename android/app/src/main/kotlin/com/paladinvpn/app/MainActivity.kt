package com.paladinvpn.app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val installerChannel = "com.revoltvpn.app/installer"
    private val hapticsChannel = "com.revoltvpn.app/haptics"
    private val appsChannel = "com.revoltvpn.app/apps"

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
