from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one marker, found {count}: {old[:120]!r}")
    p.write_text(text.replace(old, new, 1))

base = 'local_packages/flutter_vless_android-1.1.5/android/src/main/kotlin/com/github/tfox/flutter_vless'

path = f'{base}/xray/dto/XrayConfig.kt'
replace_once(
    path,
    '    /** Routing domain strategy. */\n    var ROUTING_DOMAIN_STRATEGY: String = ""\n',
    '    /** Routing domain strategy. */\n    var ROUTING_DOMAIN_STRATEGY: String = "",\n\n'
    '    /** Unique generation token used to reject stale native runtime events. */\n'
    '    var RUNTIME_TOKEN: String = ""\n',
)

path = f'{base}/xray/utils/AppConfigs.kt'
replace_once(path, '        START_SERVICE, STOP_SERVICE, RESTART_SERVICE\n', '        START_SERVICE, STOP_SERVICE, RESTART_SERVICE, UPDATE_SESSION_DEADLINE\n')
replace_once(path, '    var V2RAY_STATE: V2RAY_STATES = V2RAY_STATES.V2RAY_DISCONNECTED\n', '    var V2RAY_STATE: V2RAY_STATES = V2RAY_STATES.V2RAY_DISCONNECTED\n    @Volatile var RUNTIME_READY: Boolean = false\n')

path = f'{base}/FlutterVlessPlugin.kt'
replace_once(path, 'import android.os.Build\n', 'import android.os.Build\nimport android.os.Handler\nimport android.os.Looper\n')
replace_once(path, 'import java.util.ArrayList\n', 'import java.util.ArrayList\nimport java.util.UUID\n')
replace_once(
    path,
    '    private lateinit var context: Context\n',
    '''    private lateinit var context: Context
    private var expectedRuntimeToken: String? = null
    private var pendingStopResult: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val stopTimeoutRunnable = Runnable {
        val pending = pendingStopResult ?: return@Runnable
        pendingStopResult = null
        pending.error("STOP_TIMEOUT", "VPN service did not confirm shutdown", null)
    }
''',
)
replace_once(
    path,
    '''            "startVless" -> {
                // 1. Parse configuration from Flutter
                val config = XrayConfig()
                config.REMARK = call.argument("remark") ?: ""
''',
    '''            "startVless" -> {
                if (pendingStopResult != null) {
                    result.error("STOP_IN_PROGRESS", "VPN shutdown is still in progress", null)
                    return
                }

                // 1. Parse configuration from Flutter and assign a fresh generation token.
                val config = XrayConfig()
                val runtimeToken = UUID.randomUUID().toString()
                expectedRuntimeToken = runtimeToken
                config.RUNTIME_TOKEN = runtimeToken
                config.REMARK = call.argument("remark") ?: ""
''',
)
replace_once(
    path,
    '''                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                result.success(null)
            }
            "stopVless" -> {
                val intent = Intent(context, XrayVPNService::class.java)
                intent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)
                context.startService(intent)
                result.success(null)
            }
''',
    '''                try {
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
            "stopVless" -> {
                if (pendingStopResult != null) {
                    result.error("STOP_IN_PROGRESS", "VPN shutdown is already in progress", null)
                    return
                }

                val token = expectedRuntimeToken
                val intent = Intent(context, XrayVPNService::class.java)
                intent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)
                if (token != null) intent.putExtra("RUNTIME_TOKEN", token)

                try {
                    context.startService(intent)
                    if (token == null) {
                        result.success(null)
                    } else {
                        pendingStopResult = result
                        mainHandler.removeCallbacks(stopTimeoutRunnable)
                        mainHandler.postDelayed(stopTimeoutRunnable, 6_000L)
                    }
                } catch (e: Exception) {
                    pendingStopResult = null
                    mainHandler.removeCallbacks(stopTimeoutRunnable)
                    result.error("STOP_FAILED", e.message ?: "Could not stop VPN service", null)
                }
            }
            "setSessionDeadline" -> {
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

                val intent = Intent(context, XrayVPNService::class.java)
                intent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.UPDATE_SESSION_DEADLINE)
                intent.putExtra("RUNTIME_TOKEN", token)
                intent.putExtra("REMAINING_SECONDS", remainingSeconds)
                try {
                    context.startService(intent)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("DEADLINE_FAILED", e.message ?: "Could not update session deadline", null)
                }
            }
''',
)
old_receiver = '''                    val state = intent.getSerializableExtra("STATE") as? AppConfigs.V2RAY_STATES
                    val duration = intent.getStringExtra("DURATION")
                    val uploadSpeed = intent.getLongExtra("UPLOAD_SPEED", 0)
                    val downloadSpeed = intent.getLongExtra("DOWNLOAD_SPEED", 0)
                    val uploadTraffic = intent.getLongExtra("UPLOAD_TRAFFIC", 0)
                    val downloadTraffic = intent.getLongExtra("DOWNLOAD_TRAFFIC", 0)

                    val stateName = when (state) {
                        AppConfigs.V2RAY_STATES.V2RAY_CONNECTED -> "CONNECTED"
                        AppConfigs.V2RAY_STATES.V2RAY_CONNECTING -> "CONNECTING"
                        else -> "DISCONNECTED"
                    }

                    val data = ArrayList<String>()
                    data.add(duration ?: "0")
                    data.add(uploadSpeed.toString())
                    data.add(downloadSpeed.toString())
                    data.add(uploadTraffic.toString())
                    data.add(downloadTraffic.toString())
                    data.add(stateName)

                    vpnStatusSink?.success(data)
'''
new_receiver = '''                    val state = intent.getSerializableExtra("STATE") as? AppConfigs.V2RAY_STATES
                    val runtimeToken = intent.getStringExtra("RUNTIME_TOKEN").orEmpty()
                    val runtimeReady = intent.getBooleanExtra("RUNTIME_READY", false)
                    val duration = intent.getStringExtra("DURATION")
                    val uploadSpeed = intent.getLongExtra("UPLOAD_SPEED", 0)
                    val downloadSpeed = intent.getLongExtra("DOWNLOAD_SPEED", 0)
                    val uploadTraffic = intent.getLongExtra("UPLOAD_TRAFFIC", 0)
                    val downloadTraffic = intent.getLongExtra("DOWNLOAD_TRAFFIC", 0)

                    val currentToken = expectedRuntimeToken
                    if (currentToken == null) {
                        if (runtimeToken.isNotEmpty() &&
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
                        AppConfigs.V2RAY_STATES.V2RAY_CONNECTED -> if (runtimeReady) "CONNECTED" else "CONNECTING"
                        AppConfigs.V2RAY_STATES.V2RAY_CONNECTING -> "CONNECTING"
                        else -> "DISCONNECTED"
                    }

                    val data = ArrayList<String>()
                    data.add(duration ?: "0")
                    data.add(uploadSpeed.toString())
                    data.add(downloadSpeed.toString())
                    data.add(uploadTraffic.toString())
                    data.add(downloadTraffic.toString())
                    data.add(stateName)

                    if (state == AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED &&
                        runtimeToken.isNotEmpty() && runtimeToken == expectedRuntimeToken
                    ) {
                        expectedRuntimeToken = null
                        mainHandler.removeCallbacks(stopTimeoutRunnable)
                        pendingStopResult?.success(null)
                        pendingStopResult = null
                    }

                    vpnStatusSink?.success(data)
'''
replace_once(path, old_receiver, new_receiver)
replace_once(path, '    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {\n        unregisterReceiver()\n', '    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {\n        mainHandler.removeCallbacks(stopTimeoutRunnable)\n        pendingStopResult?.error("ENGINE_DETACHED", "Flutter engine detached during VPN shutdown", null)\n        pendingStopResult = null\n        unregisterReceiver()\n')

path = f'{base}/xray/core/XrayCoreManager.kt'
replace_once(path, '    fun startCore(context: Service, config: XrayConfig): Boolean {\n        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING\n        AppConfigs.V2RAY_CONFIG = config\n', '    fun startCore(context: Service, config: XrayConfig): Boolean {\n        AppConfigs.RUNTIME_READY = false\n        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING\n        AppConfigs.V2RAY_CONFIG = config\n')
replace_once(path, '            AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTED\n            startTimer(context)\n            showNotification(context, config)\n', '            AppConfigs.RUNTIME_READY = false\n            AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING\n            startTimer(context)\n            showNotification(context, config)\n            sendStatusBroadcast(context, config)\n')
replace_once(path, '                    if (xrayProcess === process &&\n                        AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED\n                    ) {\n', '                    if (xrayProcess === process &&\n                        AppConfigs.V2RAY_CONFIG?.RUNTIME_TOKEN == config.RUNTIME_TOKEN &&\n                        (AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED ||\n                         AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTING)\n                    ) {\n')
replace_once(path, '                        xrayProcess = null\n                        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING\n                        if (context is XrayVPNService) {\n', '                        xrayProcess = null\n                        AppConfigs.RUNTIME_READY = false\n                        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING\n                        sendStatusBroadcast(context, config)\n                        if (context is XrayVPNService) {\n')
replace_once(
    path,
    '''    fun stopCore(context: Service) {
        try {
            xrayProcess?.destroy()
            xrayProcess = null
        } catch (e: Exception) {
            Log.e(TAG, "Failed to destroy Xray process", e)
        }

        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED
        stopTimer()
        
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.cancel(NOTIFICATION_ID)
        
        sendDisconnectedBroadcast(context)
    }
''',
    '''    fun stopCore(context: Service, confirmationToken: String? = AppConfigs.V2RAY_CONFIG?.RUNTIME_TOKEN) {
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
''',
)
replace_once(path, '                intent.putExtra("STATE", AppConfigs.V2RAY_STATE)\n                intent.putExtra("DURATION", seconds.toString())\n', '                intent.putExtra("STATE", AppConfigs.V2RAY_STATE)\n                intent.putExtra("RUNTIME_TOKEN", AppConfigs.V2RAY_CONFIG?.RUNTIME_TOKEN.orEmpty())\n                intent.putExtra("RUNTIME_READY", AppConfigs.RUNTIME_READY)\n                intent.putExtra("DURATION", seconds.toString())\n')
replace_once(
    path,
    '''    private fun sendDisconnectedBroadcast(context: Context) {
        val intent = Intent(AppConfigs.V2RAY_CONNECTION_INFO).setPackage(context.packageName)
        intent.putExtra("STATE", AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED)
        intent.putExtra("DURATION", "0")
        intent.putExtra("UPLOAD_SPEED", 0L)
        intent.putExtra("DOWNLOAD_SPEED", 0L)
        intent.putExtra("UPLOAD_TRAFFIC", 0L)
        intent.putExtra("DOWNLOAD_TRAFFIC", 0L)
        context.sendBroadcast(intent)
    }
''',
    '''    fun sendStatusBroadcast(context: Context, config: XrayConfig) {
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
''',
)
replace_once(path, '        stopIntent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)\n', '        stopIntent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)\n        stopIntent.putExtra("RUNTIME_TOKEN", config.RUNTIME_TOKEN)\n')
replace_once(path, '.setContentText("Connected")\n', '.setContentText(if (AppConfigs.RUNTIME_READY) "Connected" else "Connecting")\n')

path = f'{base}/xray/service/XrayVPNService.kt'
replace_once(path, 'import android.os.ParcelFileDescriptor\n', 'import android.os.ParcelFileDescriptor\nimport android.os.Handler\nimport android.os.Looper\nimport android.os.SystemClock\n')
replace_once(path, '    private var tun2socksRecoveryAttempt = 0\n    private var currentConfig: XrayConfig? = null\n', '    private var tun2socksRecoveryAttempt = 0\n    private var currentConfig: XrayConfig? = null\n    private var currentProxyOnly = false\n    private val deadlineHandler = Handler(Looper.getMainLooper())\n    private var sessionDeadlineElapsed: Long? = null\n    private var sessionDeadlineToken: String? = null\n    private val sessionDeadlineRunnable = Runnable { enforceSessionDeadline() }\n')
replace_once(
    path,
    '''        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE) {
            stopAll()
            return START_NOT_STICKY
        }

        // Create notification channel and start foreground immediately to prevent crash.
''',
    '''        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE) {
            val requestedToken = intent.getStringExtra("RUNTIME_TOKEN")
            val activeToken = currentConfig?.RUNTIME_TOKEN.orEmpty()
            if (!requestedToken.isNullOrEmpty() && activeToken.isNotEmpty() && requestedToken != activeToken) {
                Log.w(TAG, "Ignoring stale STOP_SERVICE for a different runtime generation")
                return START_NOT_STICKY
            }
            stopAll(activeToken.ifEmpty { requestedToken.orEmpty() })
            return START_NOT_STICKY
        }

        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.UPDATE_SESSION_DEADLINE) {
            updateSessionDeadline(intent)
            return if (isRunning) START_REDELIVER_INTENT else START_NOT_STICKY
        }

        // Create notification channel and start foreground immediately to prevent crash.
''',
)
replace_once(path, '                cleanup()\n                currentConfig = config\n                \n                // Check if we should run in Proxy Only mode (no VPN interface)\n                val proxyOnly = intent.getBooleanExtra("PROXY_ONLY", false)\n', '                cleanup()\n                currentConfig = config\n\n                // Check if we should run in Proxy Only mode (no VPN interface)\n                val proxyOnly = intent.getBooleanExtra("PROXY_ONLY", false)\n                currentProxyOnly = proxyOnly\n                armSessionDeadline(config, BOOTSTRAP_SESSION_SECONDS)\n')
replace_once(path, '                    } else {\n                        // Proxy Only Mode: Just mark as running\n                        isRunning = true\n                        Log.d(TAG, "Starting in PROXY_ONLY mode")\n                    }\n', '                    } else {\n                        isRunning = true\n                        Log.d(TAG, "Starting in PROXY_ONLY mode")\n                        XrayCoreManager.markRuntimeReady(this, config)\n                    }\n')
replace_once(path, '    private fun scheduleTun2socksRecovery(config: XrayConfig, reason: String) {\n        if (!isRunning || currentConfig !== config || recoveringTun2socks) return\n        recoveringTun2socks = true\n', '    private fun scheduleTun2socksRecovery(config: XrayConfig, reason: String) {\n        if (!isRunning || currentConfig !== config || recoveringTun2socks) return\n        XrayCoreManager.markRuntimeConnecting(this, config)\n        recoveringTun2socks = true\n')
replace_once(path, '            sendFd(process)\n', '            sendFd(process, config)\n')
replace_once(path, '    private fun sendFd(process: Process) {\n', '    private fun sendFd(process: Process, config: XrayConfig) {\n')
replace_once(path, '                    localSocket.shutdownOutput()\n                    localSocket.close()\n                    return@Thread\n', '                    localSocket.shutdownOutput()\n                    localSocket.close()\n                    if (isRunning && currentConfig === config && tun2socksProcess === process) {\n                        tun2socksRecoveryAttempt = 0\n                        XrayCoreManager.markRuntimeReady(this, config)\n                    }\n                    return@Thread\n')
replace_once(path, '                    if (XrayCoreManager.startCore(this, config)) {\n                        Log.w(TAG, "Xray core recovered without dropping TUN")\n                        return@Thread\n                    }\n', '                    if (XrayCoreManager.startCore(this, config)) {\n                        Log.w(TAG, "Xray core recovered without dropping TUN")\n                        if (currentProxyOnly || (mInterface != null && tun2socksProcess?.isAlive == true)) {\n                            XrayCoreManager.markRuntimeReady(this, config)\n                        }\n                        return@Thread\n                    }\n')
replace_once(path, '    private fun cleanup() {\n        isRunning = false\n        recoveringXray = false\n', '    private fun cleanup() {\n        isRunning = false\n        clearSessionDeadline()\n        recoveringXray = false\n')
replace_once(path, '        tun2socksRecoveryAttempt = 0\n        tun2socksProcess?.destroy()\n', '        tun2socksRecoveryAttempt = 0\n        currentProxyOnly = false\n        AppConfigs.RUNTIME_READY = false\n        tun2socksProcess?.destroy()\n')
replace_once(
    path,
    '''    private fun stopAll() {
        cleanup()
        currentConfig = null
        XrayCoreManager.stopCore(this)
        stopForeground(true)
        stopSelf()
    }
''',
    '''    private fun stopAll(confirmationToken: String = currentConfig?.RUNTIME_TOKEN.orEmpty()) {
        cleanup()
        currentConfig = null
        XrayCoreManager.stopCore(this, confirmationToken)
        stopForeground(true)
        stopSelf()
    }

    private fun armSessionDeadline(config: XrayConfig, remainingSeconds: Long) {
        val boundedSeconds = remainingSeconds.coerceAtLeast(0L).coerceAtMost(Long.MAX_VALUE / 1000L)
        val delayMs = boundedSeconds * 1000L
        sessionDeadlineToken = config.RUNTIME_TOKEN
        sessionDeadlineElapsed = SystemClock.elapsedRealtime() + delayMs
        deadlineHandler.removeCallbacks(sessionDeadlineRunnable)
        if (delayMs == 0L) deadlineHandler.post(sessionDeadlineRunnable)
        else deadlineHandler.postDelayed(sessionDeadlineRunnable, delayMs)
    }

    private fun clearSessionDeadline() {
        deadlineHandler.removeCallbacks(sessionDeadlineRunnable)
        sessionDeadlineElapsed = null
        sessionDeadlineToken = null
    }

    private fun enforceSessionDeadline() {
        val token = sessionDeadlineToken ?: return
        val deadline = sessionDeadlineElapsed ?: return
        val config = currentConfig ?: return
        if (config.RUNTIME_TOKEN != token) return
        val remaining = deadline - SystemClock.elapsedRealtime()
        if (remaining > 0L) {
            deadlineHandler.postDelayed(sessionDeadlineRunnable, remaining)
            return
        }
        Log.w(TAG, "Native session deadline expired; stopping runtime fail-closed")
        stopAll(token)
    }

    private fun updateSessionDeadline(intent: Intent) {
        val config = currentConfig ?: return
        val token = intent.getStringExtra("RUNTIME_TOKEN").orEmpty()
        if (token.isEmpty() || token != config.RUNTIME_TOKEN) {
            Log.w(TAG, "Ignoring session deadline update for stale runtime generation")
            return
        }
        val remainingSeconds = intent.getLongExtra("REMAINING_SECONDS", -1L)
        if (remainingSeconds < 0L) {
            Log.w(TAG, "Ignoring invalid negative session deadline")
            return
        }
        armSessionDeadline(config, remainingSeconds)
    }
''',
)
replace_once(path, '        private const val FOREGROUND_SERVICE_TYPE_SPECIAL_USE = 0x40000000\n', '        private const val FOREGROUND_SERVICE_TYPE_SPECIAL_USE = 0x40000000\n        private const val BOOTSTRAP_SESSION_SECONDS = 120L\n')

path = 'lib/logic/vpn_connection.dart'
replace_once(path, "import 'package:flutter/foundation.dart';\n", "import 'package:flutter/foundation.dart';\nimport 'package:flutter/services.dart';\n")
replace_once(path, 'class VpnConnection extends ChangeNotifier {\n  int _connectEpoch = 0;\n', "class VpnConnection extends ChangeNotifier {\n  static const MethodChannel _nativeControl = MethodChannel('flutter_vless');\n\n  int _connectEpoch = 0;\n")
replace_once(path, '  Future<void> _stopRuntime() async {\n    try {\n      await _vless.stopVless().timeout(const Duration(seconds: 5));\n    } catch (_) {}\n  }\n', '''  Future<void> _stopRuntime() async {
    await _vless.stopVless().timeout(const Duration(seconds: 8));
  }

  Future<void> setNativeSessionDeadline(int remainingSeconds) async {
    if (kIsWeb) return;
    if (!_initialized) throw StateError('VPN native service is not initialized');
    if (remainingSeconds < 0) throw ArgumentError.value(remainingSeconds, 'remainingSeconds');
    await _nativeControl.invokeMethod<void>(
      'setSessionDeadline',
      <String, Object>{'remainingSeconds': remainingSeconds},
    );
  }
''')
replace_once(path, '      _suppressNativeConnect = true;\n      await _stopRuntime();\n      if (!_isCurrentConnect(connectEpoch)) return false;\n      _clearRuntimeSnapshot();\n', '''      _suppressNativeConnect = true;
      try {
        await _stopRuntime();
      } catch (stopError) {
        debugPrint('[VPN] Runtime cleanup failed after start error: $stopError');
        if (!_isCurrentConnect(connectEpoch)) return false;
        _errorMessage = 'VPN failed to shut down cleanly.\\nPlease restart the app.';
        _setStatus(VpnStatus.error, 'Shutdown failed');
        return false;
      }
      if (!_isCurrentConnect(connectEpoch)) return false;
      _clearRuntimeSnapshot();
''')
replace_once(path, "    if (_status == VpnStatus.disconnected) {\n      _clearRuntimeSnapshot();\n      _userDisconnecting = false;\n      return;\n    }\n\n    _setStatus(VpnStatus.disconnecting, 'Tearing down…');\n", "    // Explicit Disconnect always sends an idempotent native stop command.\n    _setStatus(VpnStatus.disconnecting, 'Tearing down…');\n")
replace_once(path, '''    bool timedOut = false;
    try {
      await _vless.stopVless().timeout(
            const Duration(seconds: 5),
            onTimeout: () => timedOut = true,
          );
    } catch (e) {
''', '''    try {
      await _vless.stopVless().timeout(const Duration(seconds: 8));
    } catch (e) {
''')
replace_once(path, '''    if (timedOut) {
      debugPrint('[VPN] stopVless() timed out after 5 s.');
      _errorMessage = 'VPN did not shut down cleanly.\\nPlease restart the app.';
      _clearRuntimeSnapshot();
      _setStatus(VpnStatus.error, 'Shutdown failed');
      _userDisconnecting = false;
      return;
    }

''', '')

path = 'lib/logic/session_timer.dart'
replace_once(path, '''        if (data['cap_exhausted'] == true) {
          await _doDisconnect('Data cap reached');
          return;
        }

        if (epoch != _sessionEpoch || _isDisconnecting) return;
        _consecutiveFailures = 0;
''', '''        if (data['cap_exhausted'] == true) {
          await _doDisconnect('Data cap reached');
          return;
        }

        if (epoch != _sessionEpoch || _isDisconnecting) return;
        try {
          await vpnConnection.setNativeSessionDeadline(_remainingAtLastSync);
        } catch (e) {
          debugPrint('[Timer] Failed to arm native session deadline: $e');
          await _doDisconnect('Native session deadline unavailable');
          return;
        }
        if (epoch != _sessionEpoch || _isDisconnecting) return;
        _consecutiveFailures = 0;
''')

Path('test/native_runtime_state_regression_test.dart').write_text(r'''import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native runtime is generation-scoped, readiness-gated and deadline-bound', () {
    final root = 'local_packages/flutter_vless_android-1.1.5/android/src/main/kotlin/com/github/tfox/flutter_vless';
    final plugin = File('$root/FlutterVlessPlugin.kt').readAsStringSync();
    final config = File('$root/xray/dto/XrayConfig.kt').readAsStringSync();
    final service = File('$root/xray/service/XrayVPNService.kt').readAsStringSync();
    final core = File('$root/xray/core/XrayCoreManager.kt').readAsStringSync();
    final timer = File('lib/logic/session_timer.dart').readAsStringSync();
    final vpn = File('lib/logic/vpn_connection.dart').readAsStringSync();

    expect(config, contains('var RUNTIME_TOKEN: String = ""'));
    expect(plugin, contains('expectedRuntimeToken'));
    expect(plugin, contains('runtimeToken != currentToken'));
    expect(plugin, contains('runtimeReady'));
    expect(plugin, contains('STOP_TIMEOUT'));
    expect(plugin, contains('setSessionDeadline'));
    expect(service, contains('BOOTSTRAP_SESSION_SECONDS = 120L'));
    expect(service, contains('UPDATE_SESSION_DEADLINE'));
    expect(service, contains('SystemClock.elapsedRealtime()'));
    expect(service, contains('markRuntimeReady(this, config)'));
    expect(core, contains('AppConfigs.RUNTIME_READY = false'));
    expect(core, contains('fun markRuntimeReady'));
    expect(timer, contains('setNativeSessionDeadline(_remainingAtLastSync)'));
    expect(vpn, contains("MethodChannel('flutter_vless')"));
    expect(vpn, isNot(contains('catch (_) {}')));
  });
}
''')

for temporary in [
    '.github/workflows/apply-runtime-state-hardening.yml',
    'tool/apply_runtime_state_hardening.py',
]:
    p = Path(temporary)
    if p.exists():
        p.unlink()

print('runtime-state hardening applied')
