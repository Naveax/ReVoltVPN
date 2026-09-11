// Copyright (c) 2024-2026 13FOX Studio / tfox.dev.
// SPDX-License-Identifier: MIT

package com.github.tfox.flutter_vless

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.github.tfox.flutter_vless.xray.dto.XrayConfig
import com.github.tfox.flutter_vless.xray.service.XrayVPNService
import com.github.tfox.flutter_vless.xray.utils.AppConfigs
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.util.ArrayList
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Narrow ReVolt Android bridge: start/stop, deadline, permission and status. */
class FlutterVlessPlugin :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.ActivityResultListener,
    MethodChannel.MethodCallHandler {

    private val executor = Executors.newSingleThreadExecutor()
    private lateinit var vpnControlMethod: MethodChannel
    private lateinit var vpnStatusEvent: EventChannel
    private var vpnStatusSink: EventChannel.EventSink? = null
    private var activity: Activity? = null
    private var xrayReceiver: BroadcastReceiver? = null
    private var receiverRegistered = false
    private var pendingResult: MethodChannel.Result? = null
    private lateinit var context: Context
    private var expectedRuntimeToken: String? = null
    private var pendingStopResult: MethodChannel.Result? = null
    private var pendingStopQueryId: String? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private val stopTimeoutRunnable = Runnable {
        val pending = pendingStopResult ?: return@Runnable
        pendingStopResult = null
        pendingStopQueryId = null
        pending.error("STOP_TIMEOUT", "VPN service did not confirm shutdown", null)
    }

    companion object {
        private const val TAG = "FlutterVlessPlugin"
        private const val REQUEST_CODE_VPN_PERMISSION = 24
        private const val REQUEST_CODE_POST_NOTIFICATIONS = 1
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        vpnControlMethod = MethodChannel(binding.binaryMessenger, "flutter_vless")
        vpnStatusEvent = EventChannel(binding.binaryMessenger, "flutter_vless/status")

        vpnControlMethod.setMethodCallHandler(this)
        vpnStatusEvent.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                vpnStatusSink = events
                registerReceiver()
                requestRuntimeSnapshot()
            }

            override fun onCancel(arguments: Any?) {
                vpnStatusSink = null
                unregisterReceiver()
            }
        })
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startVless" -> startVless(call, result)
            "stopVless" -> stopVless(result)
            "setSessionDeadline" -> setSessionDeadline(call, result)
            "initializeVless" -> initializeVless(call, result)
            "getCoreVersion" -> getCoreVersion(result)
            "requestPermission" -> requestPermission(result)
            else -> result.notImplemented()
        }
    }

    private fun startVless(call: MethodCall, result: MethodChannel.Result) {
        if (pendingStopResult != null) {
            result.error("STOP_IN_PROGRESS", "VPN shutdown is still in progress", null)
            return
        }

        val config = XrayConfig()
        val runtimeToken = UUID.randomUUID().toString()
        expectedRuntimeToken = runtimeToken
        config.RUNTIME_TOKEN = runtimeToken
        config.REMARK = call.argument("remark") ?: ""
        config.V2RAY_FULL_JSON_CONFIG = call.argument("config") ?: ""
        config.BLOCKED_APPS = call.argument<ArrayList<String>>("blocked_apps") ?: ArrayList()
        config.BYPASS_SUBNETS = call.argument<ArrayList<String>>("bypass_subnets") ?: ArrayList()
        config.NOTIFICATION_DISCONNECT_BUTTON_NAME =
            call.argument("notificationDisconnectButtonName") ?: "Disconnect"

        if (
            AppConfigs.NOTIFICATION_ICON_RESOURCE_NAME.isNotEmpty() &&
            AppConfigs.NOTIFICATION_ICON_RESOURCE_TYPE.isNotEmpty()
        ) {
            config.NOTIFICATION_ICON_RESOURCE_NAME = AppConfigs.NOTIFICATION_ICON_RESOURCE_NAME
            config.NOTIFICATION_ICON_RESOURCE_TYPE = AppConfigs.NOTIFICATION_ICON_RESOURCE_TYPE
            config.APPLICATION_ICON = context.resources.getIdentifier(
                AppConfigs.NOTIFICATION_ICON_RESOURCE_NAME,
                AppConfigs.NOTIFICATION_ICON_RESOURCE_TYPE,
                context.packageName,
            )
        }

        val proxyOnly = call.argument<Boolean>("proxy_only") == true
        AppConfigs.V2RAY_CONNECTION_MODE = if (proxyOnly) {
            AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY
        } else {
            AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN
        }

        try {
            val jsonConfig = org.json.JSONObject(config.V2RAY_FULL_JSON_CONFIG)
            val outbounds = jsonConfig.optJSONArray("outbounds")
            if (outbounds != null && outbounds.length() > 0) {
                val settings = outbounds.getJSONObject(0).optJSONObject("settings")
                val vnext = settings?.optJSONArray("vnext")
                if (vnext != null && vnext.length() > 0) {
                    val server = vnext.getJSONObject(0)
                    config.CONNECTED_V2RAY_SERVER_ADDRESS = server.optString("address", "")
                    config.CONNECTED_V2RAY_SERVER_PORT = server.optInt("port", 0).toString()
                } else if (settings != null) {
                    config.CONNECTED_V2RAY_SERVER_ADDRESS = settings.optString("address", "")
                    config.CONNECTED_V2RAY_SERVER_PORT = settings.optInt("port", 0).toString()
                }
            }
        } catch (_: Exception) {
            // Optional metadata only; native runtime config validation is authoritative.
        }

        val intent = Intent(context, XrayVPNService::class.java)
            .putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE)
            .putExtra("V2RAY_CONFIG", config)
            .putExtra("PROXY_ONLY", proxyOnly)

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            result.success(null)
        } catch (e: Exception) {
            if (expectedRuntimeToken == runtimeToken) expectedRuntimeToken = null
            result.error("START_FAILED", e.message ?: "Could not start VPN service", null)
        }
    }

    private fun stopVless(result: MethodChannel.Result) {
        if (pendingStopResult != null) {
            result.error("STOP_IN_PROGRESS", "VPN shutdown is already in progress", null)
            return
        }

        pendingStopResult = result
        pendingStopQueryId = null
        mainHandler.removeCallbacks(stopTimeoutRunnable)
        mainHandler.postDelayed(stopTimeoutRunnable, 6_000L)

        val token = expectedRuntimeToken
        if (token != null) {
            dispatchScopedStop(token)
            return
        }

        // A recreated Flutter engine may not yet know the service generation.
        // Ask the authoritative service instead of returning a false success or
        // issuing an unscoped STOP that could kill a newer runtime.
        val queryId = UUID.randomUUID().toString()
        pendingStopQueryId = queryId
        try {
            context.startService(
                Intent(context, XrayVPNService::class.java)
                    .putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.QUERY_RUNTIME)
                    .putExtra("QUERY_ID", queryId),
            )
        } catch (e: Exception) {
            failPendingStop("STOP_QUERY_FAILED", e.message ?: "Could not query VPN service")
        }
    }

    private fun dispatchScopedStop(token: String) {
        try {
            context.startService(
                Intent(context, XrayVPNService::class.java)
                    .putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)
                    .putExtra("RUNTIME_TOKEN", token),
            )
        } catch (e: Exception) {
            failPendingStop("STOP_FAILED", e.message ?: "Could not stop VPN service")
        }
    }

    private fun completePendingStop() {
        mainHandler.removeCallbacks(stopTimeoutRunnable)
        pendingStopQueryId = null
        pendingStopResult?.success(null)
        pendingStopResult = null
    }

    private fun failPendingStop(code: String, message: String) {
        mainHandler.removeCallbacks(stopTimeoutRunnable)
        pendingStopQueryId = null
        pendingStopResult?.error(code, message, null)
        pendingStopResult = null
    }

    private fun requestRuntimeSnapshot() {
        val queryId = "snapshot-${UUID.randomUUID()}"
        try {
            context.startService(
                Intent(context, XrayVPNService::class.java)
                    .putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.QUERY_RUNTIME)
                    .putExtra("QUERY_ID", queryId),
            )
        } catch (e: Exception) {
            Log.d(TAG, "Runtime snapshot unavailable: ${e.message}")
        }
    }

    private fun setSessionDeadline(call: MethodCall, result: MethodChannel.Result) {
        val token = expectedRuntimeToken
        val remainingSeconds = call.argument<Number>("remainingSeconds")?.toLong()
        if (token == null) {
            result.error("NO_RUNTIME", "No active runtime token", null)
            return
        }
        if (remainingSeconds == null || remainingSeconds < 0) {
            result.error("INVALID_DEADLINE", "remainingSeconds must be non-negative", null)
            return
        }

        try {
            context.startService(
                Intent(context, XrayVPNService::class.java)
                    .putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.UPDATE_SESSION_DEADLINE)
                    .putExtra("RUNTIME_TOKEN", token)
                    .putExtra("REMAINING_SECONDS", remainingSeconds),
            )
            result.success(null)
        } catch (e: Exception) {
            result.error("DEADLINE_FAILED", e.message ?: "Could not update session deadline", null)
        }
    }

    private fun initializeVless(call: MethodCall, result: MethodChannel.Result) {
        val iconResourceName = call.argument<String>("notificationIconResourceName")
        val iconResourceType = call.argument<String>("notificationIconResourceType")
        if (iconResourceName != null && iconResourceType != null) {
            AppConfigs.NOTIFICATION_ICON_RESOURCE_NAME = iconResourceName
            AppConfigs.NOTIFICATION_ICON_RESOURCE_TYPE = iconResourceType
        }
        result.success(null)
    }

    private fun getCoreVersion(result: MethodChannel.Result) {
        executor.submit {
            var process: Process? = null
            try {
                val xrayExecutable = File(context.applicationInfo.nativeLibraryDir, "libxray.so")
                if (!xrayExecutable.exists()) {
                    result.success("Xray not found")
                    return@submit
                }

                process = ProcessBuilder(xrayExecutable.absolutePath, "-version")
                    .redirectErrorStream(true)
                    .start()
                if (!process.waitFor(3, TimeUnit.SECONDS)) {
                    process.destroyForcibly()
                    result.success("Error: Xray version probe timed out")
                    return@submit
                }
                val version = process.inputStream.bufferedReader().use { it.readLine() }
                result.success(version ?: "Xray version unavailable")
            } catch (e: Exception) {
                result.success("Error: ${e.message}")
            } finally {
                process?.destroy()
            }
        }
    }

    private fun requestPermission(result: MethodChannel.Result) {
        val currentActivity = activity
        if (currentActivity == null) {
            result.error("NO_ACTIVITY", "Activity is not attached", null)
            return
        }
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ActivityCompat.checkSelfPermission(
                currentActivity,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                currentActivity,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQUEST_CODE_POST_NOTIFICATIONS,
            )
        }
        val request = VpnService.prepare(currentActivity)
        if (request != null) {
            pendingResult = result
            currentActivity.startActivityForResult(request, REQUEST_CODE_VPN_PERMISSION)
        } else {
            result.success(true)
        }
    }

    private fun registerReceiver() {
        if (receiverRegistered) return
        if (xrayReceiver == null) {
            xrayReceiver = object : BroadcastReceiver() {
                override fun onReceive(receiverContext: Context?, intent: Intent?) {
                    if (intent == null || vpnStatusSink == null) return
                    val state = if (Build.VERSION.SDK_INT >= 33) {
                        intent.getSerializableExtra("STATE", AppConfigs.V2RAY_STATES::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getSerializableExtra("STATE") as? AppConfigs.V2RAY_STATES
                    }
                    val runtimeToken = intent.getStringExtra("RUNTIME_TOKEN").orEmpty()
                    val runtimeReady = intent.getBooleanExtra("RUNTIME_READY", false)
                    val duration = intent.getStringExtra("DURATION") ?: "0"
                    val queryId = intent.getStringExtra("QUERY_ID")

                    val stopQuery = pendingStopQueryId
                    if (stopQuery != null && queryId == stopQuery) {
                        pendingStopQueryId = null
                        if (
                            runtimeToken.isEmpty() ||
                            state == AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED
                        ) {
                            expectedRuntimeToken = null
                            completePendingStop()
                        } else {
                            expectedRuntimeToken = runtimeToken
                            dispatchScopedStop(runtimeToken)
                        }
                    }

                    val currentToken = expectedRuntimeToken
                    if (currentToken == null) {
                        if (
                            runtimeToken.isNotEmpty() &&
                            (state == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED ||
                                state == AppConfigs.V2RAY_STATES.V2RAY_CONNECTING)
                        ) {
                            expectedRuntimeToken = runtimeToken
                        } else {
                            return
                        }
                    } else if (runtimeToken != currentToken) {
                        return
                    }

                    val stateName = when (state) {
                        AppConfigs.V2RAY_STATES.V2RAY_CONNECTED ->
                            if (runtimeReady) "CONNECTED" else "CONNECTING"
                        AppConfigs.V2RAY_STATES.V2RAY_CONNECTING -> "CONNECTING"
                        else -> "DISCONNECTED"
                    }

                    val data = ArrayList<String>()
                    data.add(duration)
                    // Legacy status tuple positions retained for Dart API compatibility.
                    data.add("0")
                    data.add("0")
                    data.add("0")
                    data.add("0")
                    data.add(stateName)

                    if (
                        state == AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED &&
                        runtimeToken.isNotEmpty() &&
                        runtimeToken == expectedRuntimeToken
                    ) {
                        expectedRuntimeToken = null
                        completePendingStop()
                    }

                    vpnStatusSink?.success(data)
                }
            }
        }

        ContextCompat.registerReceiver(
            context,
            xrayReceiver,
            IntentFilter(AppConfigs.V2RAY_CONNECTION_INFO),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        receiverRegistered = true
    }

    private fun unregisterReceiver() {
        val receiver = xrayReceiver ?: return
        if (receiverRegistered) {
            try {
                context.unregisterReceiver(receiver)
            } catch (e: Exception) {
                Log.w(TAG, "Receiver was already detached", e)
            }
        }
        receiverRegistered = false
        xrayReceiver = null
    }

    private fun failPendingPermission(code: String, message: String) {
        pendingResult?.error(code, message, null)
        pendingResult = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        mainHandler.removeCallbacks(stopTimeoutRunnable)
        pendingStopResult?.error(
            "ENGINE_DETACHED",
            "Flutter engine detached during VPN shutdown",
            null,
        )
        pendingStopResult = null
        pendingStopQueryId = null
        failPendingPermission(
            "ENGINE_DETACHED",
            "Flutter engine detached during VPN permission request",
        )
        unregisterReceiver()
        vpnControlMethod.setMethodCallHandler(null)
        vpnStatusEvent.setStreamHandler(null)
        executor.shutdownNow()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        failPendingPermission("NO_ACTIVITY", "Activity detached during VPN permission request")
        activity = null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == REQUEST_CODE_VPN_PERMISSION) {
            pendingResult?.success(resultCode == Activity.RESULT_OK)
            pendingResult = null
            return true
        }
        return false
    }
}
