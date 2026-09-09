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
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
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

class FlutterVlessPlugin : FlutterPlugin, ActivityAware,
    PluginRegistry.ActivityResultListener, MethodChannel.MethodCallHandler {

    private val executor = Executors.newSingleThreadExecutor()
    private lateinit var vpnControlMethod: MethodChannel
    private lateinit var vpnStatusEvent: EventChannel
    private var vpnStatusSink: EventChannel.EventSink? = null
    private var activity: Activity? = null
    private var xrayReceiver: BroadcastReceiver? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private lateinit var context: Context
    private var expectedRuntimeToken: String? = null
    private var pendingStartResult: MethodChannel.Result? = null
    private var pendingStopResult: MethodChannel.Result? = null
    private var pendingDeadlineResult: MethodChannel.Result? = null
    private val runtimeControlGeneration = RuntimeControlGeneration()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val stopTimeoutRunnable = Runnable {
        val pending = pendingStopResult ?: return@Runnable
        pendingStopResult = null
        pending.error("STOP_TIMEOUT", "VPN service did not confirm shutdown", null)
    }
    private val deadlineTimeoutRunnable = Runnable {
        val pending = pendingDeadlineResult ?: return@Runnable
        pendingDeadlineResult = null
        pending.error(
            "DEADLINE_TIMEOUT",
            "VPN service did not confirm the session deadline update",
            null,
        )
    }

    private data class RuntimeStateSnapshot(
        val active: Boolean,
        val runtimeToken: String,
        val runtimeReady: Boolean,
        val proxyOnly: Boolean,
        val state: String,
    ) {
        fun asMap(): Map<String, Any> = mapOf(
            "active" to active,
            "runtimeToken" to runtimeToken,
            "runtimeReady" to runtimeReady,
            "proxyOnly" to proxyOnly,
            "state" to state,
        )
    }

    companion object {
        private const val TAG = "FlutterVlessPlugin"
        private const val REQUEST_CODE_VPN_PERMISSION = 24
        private const val REQUEST_CODE_POST_NOTIFICATIONS = 1
        private const val RUNTIME_STATE_QUERY_TIMEOUT_MS = 3_000L
        private const val DEADLINE_UPDATE_TIMEOUT_MS = 3_000L
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        vpnControlMethod = MethodChannel(binding.binaryMessenger, "flutter_vless")
        vpnStatusEvent = EventChannel(binding.binaryMessenger, "flutter_vless/status")
        vpnControlMethod.setMethodCallHandler(this)
        vpnStatusEvent.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                vpnStatusSink = events
            }
            override fun onCancel(arguments: Any?) {
                vpnStatusSink = null
            }
        })
        registerReceiver()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startVless" -> startVless(call, result)
            "stopVless" -> stopVless(result)
            "queryRuntimeState" -> queryRuntimeStateForFlutter(result)
            "setSessionDeadline" -> setSessionDeadline(call, result)
            "initializeVless" -> {
                val iconResourceName = call.argument<String>("notificationIconResourceName")
                val iconResourceType = call.argument<String>("notificationIconResourceType")
                if (iconResourceName != null && iconResourceType != null) {
                    AppConfigs.NOTIFICATION_ICON_RESOURCE_NAME = iconResourceName
                    AppConfigs.NOTIFICATION_ICON_RESOURCE_TYPE = iconResourceType
                }
                result.success(null)
            }
            "getCoreVersion" -> getCoreVersion(result)
            "requestPermission" -> requestPermission(result)
            else -> result.notImplemented()
        }
    }

    private fun startVless(call: MethodCall, result: MethodChannel.Result) {
        runtimeControlGeneration.advance()
        cancelPendingDeadline(
            "DEADLINE_SUPERSEDED",
            "Session deadline update was superseded by VPN startup",
        )
        if (pendingStopResult != null) {
            result.error("STOP_IN_PROGRESS", "VPN shutdown is still in progress", null)
            return
        }
        if (pendingStartResult != null) {
            result.error("START_IN_PROGRESS", "VPN startup preflight is already in progress", null)
            return
        }

        pendingStartResult = result
        queryRuntimeState(
            onSuccess = { snapshot ->
                if (pendingStartResult !== result) return@queryRuntimeState
                when (RuntimeStartGate.decide(snapshot.active, snapshot.runtimeToken)) {
                    RuntimeStartGate.Decision.ALLOW_START -> {
                        expectedRuntimeToken = null
                        dispatchStartVless(call, result)
                    }
                    RuntimeStartGate.Decision.ADOPT_EXISTING -> {
                        expectedRuntimeToken = snapshot.runtimeToken
                        pendingStartResult = null
                        result.error(
                            "RUNTIME_ALREADY_ACTIVE",
                            "An existing VPN runtime must be adopted or stopped before starting another generation",
                            snapshot.asMap(),
                        )
                    }
                    RuntimeStartGate.Decision.INVALID_ACTIVE_STATE -> {
                        pendingStartResult = null
                        result.error(
                            "RUNTIME_STATE_INVALID",
                            "VPN service reported an active runtime without a generation token",
                            snapshot.asMap(),
                        )
                    }
                }
            },
            onError = { code, message ->
                if (pendingStartResult !== result) return@queryRuntimeState
                pendingStartResult = null
                result.error(code, message, null)
            },
        )
    }

    private fun dispatchStartVless(call: MethodCall, result: MethodChannel.Result) {
        if (pendingStartResult !== result) return
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

        if (AppConfigs.NOTIFICATION_ICON_RESOURCE_NAME.isNotEmpty() &&
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
            pendingStartResult = null
            result.success(null)
        } catch (error: Exception) {
            if (expectedRuntimeToken == runtimeToken) expectedRuntimeToken = null
            pendingStartResult = null
            result.error("START_FAILED", error.message ?: "Could not start VPN service", null)
        }
    }

    private fun queryRuntimeStateForFlutter(result: MethodChannel.Result) {
        if (pendingStartResult != null || pendingStopResult != null || pendingDeadlineResult != null) {
            result.error(
                "RUNTIME_CONTROL_IN_PROGRESS",
                "VPN runtime control operation is already in progress",
                null,
            )
            return
        }
        val controlGeneration = runtimeControlGeneration.capture()
        queryRuntimeState(
            onSuccess = { snapshot ->
                if (!runtimeControlGeneration.isCurrent(controlGeneration) ||
                    pendingStartResult != null || pendingStopResult != null ||
                    pendingDeadlineResult != null
                ) {
                    result.error(
                        "RUNTIME_STATE_SUPERSEDED",
                        "VPN runtime state query was superseded by a control operation",
                        null,
                    )
                    return@queryRuntimeState
                }
                if (snapshot.runtimeToken.isNotEmpty()) {
                    expectedRuntimeToken = snapshot.runtimeToken
                } else {
                    expectedRuntimeToken = null
                }
                result.success(snapshot.asMap())
            },
            onError = { code, message ->
                if (!runtimeControlGeneration.isCurrent(controlGeneration)) {
                    result.error(
                        "RUNTIME_STATE_SUPERSEDED",
                        "VPN runtime state query was superseded by a control operation",
                        null,
                    )
                } else {
                    result.error(code, message, null)
                }
            },
        )
    }

    private fun queryRuntimeState(
        onSuccess: (RuntimeStateSnapshot) -> Unit,
        onError: (String, String) -> Unit,
    ) {
        var completed = false
        val timeoutRunnable = Runnable {
            if (completed) return@Runnable
            completed = true
            onError(
                "RUNTIME_STATE_QUERY_TIMEOUT",
                "VPN service did not answer the runtime-state query",
            )
        }
        val receiver = object : ResultReceiver(mainHandler) {
            override fun onReceiveResult(resultCode: Int, resultData: Bundle?) {
                if (completed) return
                completed = true
                mainHandler.removeCallbacks(timeoutRunnable)
                try {
                    val active = resultData?.getBoolean("active", false) == true
                    val token = resultData?.getString("runtimeToken").orEmpty()
                    val ready = resultData?.getBoolean("runtimeReady", false) == true
                    val proxyOnly = resultData?.getBoolean("proxyOnly", false) == true
                    val state = resultData?.getString("state").orEmpty()
                    if (state.isEmpty() || (ready && !active)) {
                        throw IllegalStateException("Contradictory VPN runtime state")
                    }
                    onSuccess(
                        RuntimeStateSnapshot(
                            active = active,
                            runtimeToken = token,
                            runtimeReady = ready,
                            proxyOnly = proxyOnly,
                            state = state,
                        ),
                    )
                } catch (error: Exception) {
                    onError(
                        "RUNTIME_STATE_INVALID",
                        error.message ?: "VPN service returned malformed runtime state",
                    )
                }
            }
        }
        val query = Intent(context, XrayVPNService::class.java)
            .putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.QUERY_STATE)
            .putExtra("STATE_RECEIVER", receiver)
        mainHandler.postDelayed(timeoutRunnable, RUNTIME_STATE_QUERY_TIMEOUT_MS)
        try {
            context.startService(query)
        } catch (error: Exception) {
            if (!completed) {
                completed = true
                mainHandler.removeCallbacks(timeoutRunnable)
                onError(
                    "RUNTIME_STATE_QUERY_FAILED",
                    error.message ?: "Could not query VPN service state",
                )
            }
        }
    }

    private fun stopVless(result: MethodChannel.Result) {
        runtimeControlGeneration.advance()
        cancelPendingDeadline(
            "DEADLINE_SUPERSEDED",
            "Session deadline update was superseded by VPN shutdown",
        )
        if (pendingStopResult != null) {
            result.error("STOP_IN_PROGRESS", "VPN shutdown is already in progress", null)
            return
        }
        val pendingStart = pendingStartResult
        if (pendingStart != null) {
            pendingStartResult = null
            pendingStart.error(
                "START_CANCELLED",
                "VPN startup was cancelled because shutdown won the lifecycle race",
                null,
            )
        }
        val token = expectedRuntimeToken
        if (token != null) {
            dispatchStop(token, result)
            return
        }
        queryRuntimeThenStop(result)
    }

    private fun queryRuntimeThenStop(result: MethodChannel.Result) {
        pendingStopResult = result
        armStopTimeout()
        queryRuntimeState(
            onSuccess = { snapshot ->
                if (pendingStopResult !== result) return@queryRuntimeState
                val token = snapshot.runtimeToken
                if (token.isNotEmpty()) {
                    expectedRuntimeToken = token
                    sendStopIntent(token, result)
                    return@queryRuntimeState
                }
                if (snapshot.active) {
                    completePendingStopError(
                        "STOP_STATE_UNKNOWN",
                        "VPN service reported an active runtime without a generation token",
                    )
                    return@queryRuntimeState
                }
                expectedRuntimeToken = null
                completePendingStopSuccess()
            },
            onError = { _, message ->
                if (pendingStopResult !== result) return@queryRuntimeState
                completePendingStopError("STOP_QUERY_FAILED", message)
            },
        )
    }

    private fun dispatchStop(token: String, result: MethodChannel.Result) {
        pendingStopResult = result
        armStopTimeout()
        sendStopIntent(token, result)
    }

    private fun sendStopIntent(token: String, result: MethodChannel.Result) {
        if (pendingStopResult !== result) return
        val intent = Intent(context, XrayVPNService::class.java)
            .putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)
            .putExtra("RUNTIME_TOKEN", token)
        try {
            context.startService(intent)
        } catch (error: Exception) {
            completePendingStopError(
                "STOP_FAILED",
                error.message ?: "Could not stop VPN service",
            )
        }
    }

    private fun armStopTimeout() {
        mainHandler.removeCallbacks(stopTimeoutRunnable)
        mainHandler.postDelayed(stopTimeoutRunnable, 6_000L)
    }

    private fun completePendingStopSuccess() {
        val pending = pendingStopResult ?: return
        pendingStopResult = null
        mainHandler.removeCallbacks(stopTimeoutRunnable)
        pending.success(null)
    }

    private fun completePendingStopError(code: String, message: String) {
        val pending = pendingStopResult ?: return
        pendingStopResult = null
        mainHandler.removeCallbacks(stopTimeoutRunnable)
        pending.error(code, message, null)
    }

    private fun cancelPendingDeadline(code: String, message: String) {
        val pending = pendingDeadlineResult ?: return
        pendingDeadlineResult = null
        mainHandler.removeCallbacks(deadlineTimeoutRunnable)
        pending.error(code, message, null)
    }

    private fun setSessionDeadline(call: MethodCall, result: MethodChannel.Result) {
        if (pendingDeadlineResult != null) {
            result.error(
                "DEADLINE_IN_PROGRESS",
                "A session deadline update is already in progress",
                null,
            )
            return
        }
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

        val controlGeneration = runtimeControlGeneration.capture()
        pendingDeadlineResult = result
        val receiver = object : ResultReceiver(mainHandler) {
            override fun onReceiveResult(resultCode: Int, resultData: Bundle?) {
                if (pendingDeadlineResult !== result) return
                pendingDeadlineResult = null
                mainHandler.removeCallbacks(deadlineTimeoutRunnable)
                if (!runtimeControlGeneration.isCurrent(controlGeneration)) {
                    result.error(
                        "DEADLINE_SUPERSEDED",
                        "Session deadline update was superseded by a VPN control operation",
                        null,
                    )
                    return
                }
                if (resultCode == 0) {
                    result.success(null)
                    return
                }
                val code = resultData?.getString("code").orEmpty()
                    .ifEmpty { "DEADLINE_REJECTED" }
                val message = resultData?.getString("message").orEmpty()
                    .ifEmpty { "VPN service rejected the session deadline update" }
                result.error(code, message, null)
            }
        }
        val intent = Intent(context, XrayVPNService::class.java)
            .putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.UPDATE_SESSION_DEADLINE)
            .putExtra("RUNTIME_TOKEN", token)
            .putExtra("REMAINING_SECONDS", remainingSeconds)
            .putExtra("DEADLINE_RECEIVER", receiver)
        mainHandler.removeCallbacks(deadlineTimeoutRunnable)
        mainHandler.postDelayed(deadlineTimeoutRunnable, DEADLINE_UPDATE_TIMEOUT_MS)
        try {
            context.startService(intent)
        } catch (error: Exception) {
            if (pendingDeadlineResult === result) {
                pendingDeadlineResult = null
                mainHandler.removeCallbacks(deadlineTimeoutRunnable)
                result.error(
                    "DEADLINE_FAILED",
                    error.message ?: "Could not update session deadline",
                    null,
                )
            }
        }
    }

    private fun getCoreVersion(result: MethodChannel.Result) {
        executor.submit {
            val response = try {
                VersionProbe.query(File(context.applicationInfo.nativeLibraryDir, "libxray.so"))
            } catch (error: Exception) {
                "Error: ${error.message ?: "version probe failed"}"
            }
            mainHandler.post { result.success(response) }
        }
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (pendingPermissionResult != null) {
            result.error("PERMISSION_IN_PROGRESS", "VPN permission request is already in progress", null)
            return
        }
        val currentActivity = activity
        if (currentActivity == null) {
            result.error("NO_ACTIVITY", "Activity is not attached", null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
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
        if (request == null) {
            result.success(true)
            return
        }
        pendingPermissionResult = result
        try {
            currentActivity.startActivityForResult(request, REQUEST_CODE_VPN_PERMISSION)
        } catch (error: Exception) {
            pendingPermissionResult = null
            result.error(
                "PERMISSION_LAUNCH_FAILED",
                error.message ?: "Could not launch VPN permission activity",
                null,
            )
        }
    }

    private fun registerReceiver() {
        if (xrayReceiver != null) return
        xrayReceiver = object : BroadcastReceiver() {
            override fun onReceive(receiverContext: Context?, intent: Intent?) {
                if (intent == null) return
                val state = intent.getSerializableExtra("STATE") as? AppConfigs.V2RAY_STATES
                val runtimeToken = intent.getStringExtra("RUNTIME_TOKEN").orEmpty()
                val runtimeReady = intent.getBooleanExtra("RUNTIME_READY", false)
                val currentToken = expectedRuntimeToken
                if (currentToken == null) {
                    if (runtimeToken.isNotEmpty() &&
                        (state == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED ||
                            state == AppConfigs.V2RAY_STATES.V2RAY_CONNECTING)
                    ) {
                        expectedRuntimeToken = runtimeToken
                    } else if (state != AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED) {
                        return
                    }
                } else if (runtimeToken.isNotEmpty() && runtimeToken != currentToken) {
                    return
                }

                if (state == AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED &&
                    runtimeToken.isNotEmpty() && runtimeToken == expectedRuntimeToken
                ) {
                    expectedRuntimeToken = null
                    completePendingStopSuccess()
                }

                val stateName = when (state) {
                    AppConfigs.V2RAY_STATES.V2RAY_CONNECTED ->
                        if (runtimeReady) "CONNECTED" else "CONNECTING"
                    AppConfigs.V2RAY_STATES.V2RAY_CONNECTING -> "CONNECTING"
                    else -> "DISCONNECTED"
                }
                val data = arrayListOf(
                    intent.getStringExtra("DURATION") ?: "0",
                    intent.getLongExtra("UPLOAD_SPEED", 0).toString(),
                    intent.getLongExtra("DOWNLOAD_SPEED", 0).toString(),
                    intent.getLongExtra("UPLOAD_TRAFFIC", 0).toString(),
                    intent.getLongExtra("DOWNLOAD_TRAFFIC", 0).toString(),
                    stateName,
                )
                vpnStatusSink?.success(data)
            }
        }
        ContextCompat.registerReceiver(
            context,
            xrayReceiver,
            IntentFilter(AppConfigs.V2RAY_CONNECTION_INFO),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    private fun unregisterReceiver() {
        val receiver = xrayReceiver ?: return
        try {
            context.unregisterReceiver(receiver)
        } catch (error: Exception) {
            Log.w(TAG, "Receiver was already detached during engine cleanup", error)
        }
        xrayReceiver = null
    }

    private fun failPendingPermission(code: String, message: String) {
        pendingPermissionResult?.error(code, message, null)
        pendingPermissionResult = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        runtimeControlGeneration.advance()
        mainHandler.removeCallbacks(stopTimeoutRunnable)
        mainHandler.removeCallbacks(deadlineTimeoutRunnable)
        pendingStartResult?.error(
            "ENGINE_DETACHED",
            "Flutter engine detached during VPN startup preflight",
            null,
        )
        pendingStartResult = null
        pendingStopResult?.error(
            "ENGINE_DETACHED",
            "Flutter engine detached during VPN shutdown",
            null,
        )
        pendingStopResult = null
        pendingDeadlineResult?.error(
            "ENGINE_DETACHED",
            "Flutter engine detached during session deadline update",
            null,
        )
        pendingDeadlineResult = null
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
        if (requestCode != REQUEST_CODE_VPN_PERMISSION) return false
        val pending = pendingPermissionResult ?: return true
        pendingPermissionResult = null
        pending.success(resultCode == Activity.RESULT_OK)
        return true
    }
}
