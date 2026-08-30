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
import androidx.core.app.ActivityCompat
import com.github.tfox.flutter_vless.xray.core.XrayCoreManager
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
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.util.ArrayList
import java.util.concurrent.Executors

class FlutterVlessPlugin : FlutterPlugin, ActivityAware,
    PluginRegistry.ActivityResultListener, MethodChannel.MethodCallHandler {

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var vpnControlMethod: MethodChannel
    private lateinit var vpnStatusEvent: EventChannel
    private var vpnStatusSink: EventChannel.EventSink? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var xrayReceiver: BroadcastReceiver? = null
    private var receiverRegistered = false
    private var pendingResult: MethodChannel.Result? = null
    private lateinit var context: Context

    @Volatile private var lastState = "DISCONNECTED"
    @Volatile private var lastTunEstablished = false
    @Volatile private var lastFdDelivered = false
    @Volatile private var lastSocksReady = false
    @Volatile private var lastSocksPort = 0
    @Volatile private var lastSocksUser = ""
    @Volatile private var lastSocksPass = ""
    @Volatile private var lastGeneration = 0L
    @Volatile private var lastError = ""
    @Volatile private var pendingAllowedApps = ArrayList<String>()

    companion object {
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
            "stopVless" -> {
                val intent = Intent(context, XrayVPNService::class.java)
                    .putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)
                context.startService(intent)
                result.success(null)
            }
            "restartCurrentRuntime" -> {
                val intent = Intent(context, XrayVPNService::class.java)
                    .putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.RESTART_SERVICE)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
                else context.startService(intent)
                result.success(true)
            }
            "getTunnelState" -> result.success(tunnelStateMap())
            "setAllowedApps" -> {
                val packages = call.argument<List<String>>("packages") ?: emptyList()
                pendingAllowedApps = ArrayList(packages.filter { it.isNotBlank() }.distinct())
                result.success(true)
            }
            "initializeVless" -> {
                AppConfigs.NOTIFICATION_ICON_RESOURCE_NAME = call.argument<String>("notificationIconResourceName") ?: ""
                AppConfigs.NOTIFICATION_ICON_RESOURCE_TYPE = call.argument<String>("notificationIconResourceType") ?: ""
                result.success(null)
            }
            "getServerDelay" -> {
                val configJson = call.argument<String>("config")
                val url = call.argument<String>("url") ?: "https://www.google.com"
                if (configJson == null) {
                    result.error("INVALID_CONFIG", "Config is null", null)
                    return
                }
                executor.execute {
                    val delay = XrayCoreManager.getServerDelay(context, configJson, url)
                    mainHandler.post { result.success(delay) }
                }
            }
            "getConnectedServerDelay" -> {
                val url = call.argument<String>("url") ?: "https://www.google.com"
                executor.execute {
                    val delay = if (
                        lastState == "CONNECTED" &&
                        lastTunEstablished &&
                        lastFdDelivered &&
                        lastSocksReady
                    ) {
                        XrayCoreManager.measureSocksDelay(lastSocksPort, lastSocksUser, lastSocksPass, url)
                    } else -1L
                    mainHandler.post { result.success(delay) }
                }
            }
            "getCoreVersion" -> executor.execute {
                val version = try {
                    val executable = File(context.applicationInfo.nativeLibraryDir, "libxray.so")
                    if (!executable.exists()) "Xray not found"
                    else {
                        val p = Runtime.getRuntime().exec(arrayOf(executable.absolutePath, "-version"))
                        BufferedReader(InputStreamReader(p.inputStream)).use { it.readLine() ?: "Unknown" }
                    }
                } catch (e: Exception) {
                    "Error: ${e.message}"
                }
                mainHandler.post { result.success(version) }
            }
            "requestPermission" -> requestPermission(result)
            else -> result.notImplemented()
        }
    }

    private fun startVless(call: MethodCall, result: MethodChannel.Result) {
        val config = XrayConfig()
        config.REMARK = call.argument("remark") ?: ""
        config.V2RAY_FULL_JSON_CONFIG = call.argument("config") ?: ""
        config.BLOCKED_APPS = call.argument<ArrayList<String>>("blocked_apps") ?: ArrayList()
        config.ALLOWED_APPS = ArrayList(pendingAllowedApps)
        config.BYPASS_SUBNETS = call.argument<ArrayList<String>>("bypass_subnets") ?: ArrayList()
        config.NOTIFICATION_DISCONNECT_BUTTON_NAME = call.argument("notificationDisconnectButtonName") ?: "Disconnect"

        if (config.ALLOWED_APPS.isNotEmpty() && config.BLOCKED_APPS.isNotEmpty()) {
            result.error("INVALID_ROUTING", "Allowed and blocked app routing cannot be combined", null)
            return
        }

        if (AppConfigs.NOTIFICATION_ICON_RESOURCE_NAME.isNotEmpty() && AppConfigs.NOTIFICATION_ICON_RESOURCE_TYPE.isNotEmpty()) {
            config.NOTIFICATION_ICON_RESOURCE_NAME = AppConfigs.NOTIFICATION_ICON_RESOURCE_NAME
            config.NOTIFICATION_ICON_RESOURCE_TYPE = AppConfigs.NOTIFICATION_ICON_RESOURCE_TYPE
            config.APPLICATION_ICON = context.resources.getIdentifier(
                AppConfigs.NOTIFICATION_ICON_RESOURCE_NAME,
                AppConfigs.NOTIFICATION_ICON_RESOURCE_TYPE,
                context.packageName
            )
        }

        val proxyOnly = call.argument<Boolean>("proxy_only") == true
        AppConfigs.V2RAY_CONNECTION_MODE = if (proxyOnly) {
            AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY
        } else AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN

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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
        else context.startService(intent)
        result.success(null)
    }

    private fun requestPermission(result: MethodChannel.Result) {
        val currentActivity = activity
        if (currentActivity == null) {
            result.error("NO_ACTIVITY", "Activity is null", null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ActivityCompat.checkSelfPermission(currentActivity, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                currentActivity,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQUEST_CODE_POST_NOTIFICATIONS
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

    private fun tunnelStateMap(): Map<String, Any> = mapOf(
        "state" to lastState,
        "tunEstablished" to lastTunEstablished,
        "fdDelivered" to lastFdDelivered,
        "socksReady" to lastSocksReady,
        "socksPort" to lastSocksPort,
        "socksUser" to lastSocksUser,
        "socksPass" to lastSocksPass,
        "generation" to lastGeneration,
        "error" to lastError
    )

    private fun registerReceiver() {
        if (receiverRegistered) return
        if (xrayReceiver == null) {
            xrayReceiver = object : BroadcastReceiver() {
                override fun onReceive(ctx: Context?, intent: Intent?) {
                    if (intent == null) return
                    val state = if (Build.VERSION.SDK_INT >= 33) {
                        intent.getSerializableExtra("STATE", AppConfigs.V2RAY_STATES::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getSerializableExtra("STATE") as? AppConfigs.V2RAY_STATES
                    }
                    lastState = when (state) {
                        AppConfigs.V2RAY_STATES.V2RAY_CONNECTED -> "CONNECTED"
                        AppConfigs.V2RAY_STATES.V2RAY_CONNECTING -> "CONNECTING"
                        else -> "DISCONNECTED"
                    }
                    lastTunEstablished = intent.getBooleanExtra("TUN_ESTABLISHED", false)
                    lastFdDelivered = intent.getBooleanExtra("FD_DELIVERED", false)
                    lastSocksReady = intent.getBooleanExtra("SOCKS_READY", false)
                    lastGeneration = intent.getLongExtra("RUNTIME_GENERATION", 0L)
                    lastError = intent.getStringExtra("LAST_ERROR").orEmpty()
                    if (lastState == "DISCONNECTED") {
                        lastSocksPort = 0
                        lastSocksUser = ""
                        lastSocksPass = ""
                    } else {
                        lastSocksPort = intent.getIntExtra("SOCKS_PORT", 0)
                        lastSocksUser = intent.getStringExtra("SOCKS_USER").orEmpty()
                        lastSocksPass = intent.getStringExtra("SOCKS_PASS").orEmpty()
                    }

                    val data = arrayListOf(
                        intent.getStringExtra("DURATION") ?: "0",
                        intent.getLongExtra("UPLOAD_SPEED", 0).toString(),
                        intent.getLongExtra("DOWNLOAD_SPEED", 0).toString(),
                        intent.getLongExtra("UPLOAD_TRAFFIC", 0).toString(),
                        intent.getLongExtra("DOWNLOAD_TRAFFIC", 0).toString(),
                        lastState
                    )
                    vpnStatusSink?.success(data)
                }
            }
        }
        val filter = IntentFilter(AppConfigs.V2RAY_CONNECTION_INFO)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(
                xrayReceiver,
                filter,
                AppConfigs.INTERNAL_STATUS_PERMISSION,
                null,
                Context.RECEIVER_NOT_EXPORTED
            )
        } else {
            @Suppress("DEPRECATION")
            context.registerReceiver(xrayReceiver, filter, AppConfigs.INTERNAL_STATUS_PERMISSION, null)
        }
        receiverRegistered = true
    }

    private fun unregisterReceiver() {
        if (!receiverRegistered || xrayReceiver == null) return
        try { context.unregisterReceiver(xrayReceiver) } catch (_: Exception) {}
        receiverRegistered = false
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        unregisterReceiver()
        vpnControlMethod.setMethodCallHandler(null)
        vpnStatusEvent.setStreamHandler(null)
        executor.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE_VPN_PERMISSION) return false
        pendingResult?.success(resultCode == Activity.RESULT_OK)
        pendingResult = null
        return true
    }
}
