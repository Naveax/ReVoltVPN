import 'dart:convert';
import 'dart:io';

const packageName = 'flutter_vless_android';
const expectedVersionFragment = 'flutter_vless_android-1.1.5';

Never fail(String message) {
  stderr.writeln('[runtime reliability patch] $message');
  exit(1);
}

Directory packageRoot() {
  final configFile = File('.dart_tool/package_config.json');
  if (!configFile.existsSync()) {
    fail('.dart_tool/package_config.json is missing; run flutter pub get first');
  }
  final decoded = jsonDecode(configFile.readAsStringSync());
  if (decoded is! Map<String, dynamic> || decoded['packages'] is! List) {
    fail('package_config.json is invalid');
  }

  Map<String, dynamic>? package;
  for (final item in decoded['packages'] as List) {
    if (item is Map && item['name'] == packageName) {
      package = Map<String, dynamic>.from(item);
      break;
    }
  }
  if (package == null) fail('$packageName was not found');

  final rootUriValue = package['rootUri'];
  if (rootUriValue is! String || rootUriValue.isEmpty) {
    fail('$packageName has no rootUri');
  }
  final rootUri = Uri.parse(rootUriValue);
  final resolved = rootUri.hasScheme
      ? rootUri
      : configFile.parent.absolute.uri.resolveUri(rootUri);
  if (resolved.scheme != 'file') fail('unsupported package URI: $resolved');

  final root = Directory.fromUri(resolved);
  final normalized = root.absolute.path.replaceAll('\\', '/');
  if (!normalized.contains(expectedVersionFragment)) {
    fail('expected flutter_vless_android 1.1.5, got ${root.path}');
  }
  return root;
}

String replaceOnce(
  String text,
  String oldValue,
  String newValue,
  String label,
) {
  if (text.contains(newValue)) return text;
  if (!text.contains(oldValue)) fail('missing expected source block: $label');
  return text.replaceFirst(oldValue, newValue);
}

void writeIfChanged(File file, String before, String after) {
  if (before == after) {
    stdout.writeln('[runtime reliability patch] already current: ${file.path}');
    return;
  }
  file.writeAsStringSync(after);
  stdout.writeln('[runtime reliability patch] patched: ${file.path}');
}

void patchManifest(File file) {
  final before = file.readAsStringSync();
  var text = before;
  text = replaceOnce(
    text,
    '                android:value="true" />\n        </service>',
    '                android:value="false" />\n        </service>',
    'disable unsupported Android Always-on VPN',
  );
  writeIfChanged(file, before, text);
}

void patchPlugin(File file) {
  final before = file.readAsStringSync();
  var text = before;

  text = replaceOnce(
    text,
    '            activity?.registerReceiver(xrayReceiver, filter, Context.RECEIVER_EXPORTED)\n',
    '            activity?.registerReceiver(xrayReceiver, filter, Context.RECEIVER_NOT_EXPORTED)\n',
    'private in-app status receiver',
  );

  if (!text.contains('"getRuntimeHealth" -> {')) {
    const marker = r'''            "getCoreVersion" -> {
''';
    const block = r'''            "getRuntimeHealth" -> {
                val healthFile = File(context.filesDir, "vpn_runtime_health.json")
                if (!healthFile.isFile) {
                    result.success(hashMapOf<String, Any>(
                        "healthy" to false,
                        "stale" to true,
                        "proxyOnly" to false,
                        "xrayAlive" to false,
                        "tun2socksAlive" to false,
                        "fdReady" to false,
                        "outboundReady" to false,
                    ))
                    return
                }

                try {
                    val json = org.json.JSONObject(healthFile.readText())
                    val updated = json.optLong("updated_elapsed_ms", -1L)
                    val age = android.os.SystemClock.elapsedRealtime() - updated
                    val stale = updated < 0L || age < 0L || age > 15000L
                    result.success(hashMapOf<String, Any>(
                        "healthy" to (!stale && json.optBoolean("healthy", false)),
                        "stale" to stale,
                        "proxyOnly" to json.optBoolean("proxy_only", false),
                        "xrayAlive" to json.optBoolean("xray_alive", false),
                        "tun2socksAlive" to json.optBoolean("tun2socks_alive", false),
                        "fdReady" to json.optBoolean("fd_ready", false),
                        "outboundReady" to json.optBoolean("outbound_ready", false),
                    ))
                } catch (_: Exception) {
                    result.success(hashMapOf<String, Any>(
                        "healthy" to false,
                        "stale" to true,
                        "proxyOnly" to false,
                        "xrayAlive" to false,
                        "tun2socksAlive" to false,
                        "fdReady" to false,
                        "outboundReady" to false,
                    ))
                }
            }
''';
    text = replaceOnce(text, marker, '$block$marker', 'runtime health method');
  }

  writeIfChanged(file, before, text);
}

void patchCore(File file) {
  final before = file.readAsStringSync();
  var text = before;

  if (!text.contains('fun isXrayProcessAlive(): Boolean')) {
    const marker = r'''    fun isXrayRunning(): Boolean {
        // Check state instead of process because VPN runs in separate service process
        return AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED ||
               AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTING
    }
''';
    const replacement = r'''    fun isXrayRunning(): Boolean {
        return AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED ||
               AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTING
    }

    /** Real child-process liveness. State alone is not sufficient. */
    fun isXrayProcessAlive(): Boolean = xrayProcess?.isAlive == true
''';
    text = replaceOnce(text, marker, replacement, 'real Xray process liveness');
  }

  const trafficBlock = r'''                val traffic = getV2rayTraffic(context)
                intent.putExtra("UPLOAD_SPEED", traffic[0])
                intent.putExtra("DOWNLOAD_SPEED", traffic[1])
                intent.putExtra("UPLOAD_TRAFFIC", traffic[2])
                intent.putExtra("DOWNLOAD_TRAFFIC", traffic[3])
''';
  const cheapHeartbeat = r'''                // ReVolt obtains usage/speed from Hivemind. Spawning a second
                // libxray process every second just to query local stats is expensive,
                // especially under Samsung/Android power-saving modes. Keep only the
                // lightweight state heartbeat used by Flutter.
                intent.putExtra("UPLOAD_SPEED", 0L)
                intent.putExtra("DOWNLOAD_SPEED", 0L)
                intent.putExtra("UPLOAD_TRAFFIC", 0L)
                intent.putExtra("DOWNLOAD_TRAFFIC", 0L)
''';
  text = replaceOnce(text, trafficBlock, cheapHeartbeat, 'remove one-process-per-second stats query');

  writeIfChanged(file, before, text);
}

void patchService(File file) {
  final before = file.readAsStringSync();
  var text = before;

  if (!text.contains('private var runtimeHealthThread: Thread? = null')) {
    text = replaceOnce(
      text,
      '    private var currentConfig: XrayConfig? = null\n',
      '    private var currentConfig: XrayConfig? = null\n'
          '    @Volatile private var proxyOnlyMode = false\n'
          '    @Volatile private var tunFdReady = false\n'
          '    @Volatile private var tunRecoveryActive = false\n'
          '    @Volatile private var runtimeHealthRunning = false\n'
          '    private var runtimeHealthThread: Thread? = null\n'
          '    private var powerWakeLock: android.os.PowerManager.WakeLock? = null\n'
          '    private var powerReceiver: android.content.BroadcastReceiver? = null\n',
      'runtime reliability fields',
    );
  }

  if (!text.contains('private fun startRuntimeHealthMonitor(')) {
    const marker = r'''    private data class SecureSocksCredentials(
''';
    const helpers = r'''    private fun readExact(input: java.io.InputStream, count: Int): ByteArray {
        val result = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val read = input.read(result, offset, count - offset)
            if (read <= 0) throw java.io.EOFException("SOCKS5 probe ended early")
            offset += read
        }
        return result
    }

    /** Authenticate to the exact per-session SOCKS5 listener and perform an
     * outbound CONNECT. A live process and a VPN key do not prove packets flow. */
    private fun probeSecureSocks(config: XrayConfig): Boolean {
        val secure = secureSocksCredentials(config) ?: return false
        var socket: java.net.Socket? = null
        return try {
            socket = java.net.Socket()
            socket.soTimeout = 1500
            socket.connect(java.net.InetSocketAddress("127.0.0.1", secure.port), 1500)
            val input = socket.getInputStream()
            val output = socket.getOutputStream()

            output.write(byteArrayOf(0x05, 0x01, 0x02))
            output.flush()
            val greeting = readExact(input, 2)
            if (greeting[0].toInt() != 0x05 || greeting[1].toInt() != 0x02) return false

            val user = secure.username.toByteArray(Charsets.UTF_8)
            val pass = secure.password.toByteArray(Charsets.UTF_8)
            if (user.isEmpty() || pass.isEmpty() || user.size > 255 || pass.size > 255) return false
            output.write(byteArrayOf(0x01, user.size.toByte(), *user, pass.size.toByte(), *pass))
            output.flush()
            val auth = readExact(input, 2)
            if (auth[0].toInt() != 0x01 || auth[1].toInt() != 0x00) return false

            // 1.1.1.1:443 is used only as a TCP reachability target. No HTTP/TLS
            // payload is sent; a successful SOCKS CONNECT proves the Xray outbound.
            output.write(byteArrayOf(
                0x05, 0x01, 0x00, 0x01,
                0x01, 0x01, 0x01, 0x01,
                0x01, 0xBB.toByte(),
            ))
            output.flush()
            val head = readExact(input, 4)
            if (head[0].toInt() != 0x05 || head[1].toInt() != 0x00) return false
            when (head[3].toInt() and 0xFF) {
                0x01 -> readExact(input, 4)
                0x03 -> readExact(input, readExact(input, 1)[0].toInt() and 0xFF)
                0x04 -> readExact(input, 16)
                else -> return false
            }
            readExact(input, 2)
            true
        } catch (_: Exception) {
            false
        } finally {
            try { socket?.close() } catch (_: Exception) {}
        }
    }

    private fun writeRuntimeHealth(
        healthy: Boolean,
        xrayAlive: Boolean,
        tunAlive: Boolean,
        fdReady: Boolean,
        outboundReady: Boolean,
    ) {
        try {
            val json = JSONObject()
                .put("updated_elapsed_ms", android.os.SystemClock.elapsedRealtime())
                .put("healthy", healthy)
                .put("proxy_only", proxyOnlyMode)
                .put("xray_alive", xrayAlive)
                .put("tun2socks_alive", tunAlive)
                .put("fd_ready", fdReady)
                .put("outbound_ready", outboundReady)
            val target = File(filesDir, "vpn_runtime_health.json")
            val temp = File(filesDir, "vpn_runtime_health.tmp")
            temp.writeText(json.toString())
            if (!temp.renameTo(target)) {
                target.writeText(json.toString())
                temp.delete()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not persist runtime health", e)
        }
    }

    private fun updatePowerWakeLock() {
        try {
            val pm = getSystemService(android.content.Context.POWER_SERVICE) as android.os.PowerManager
            val constrained = isRunning && (
                pm.isPowerSaveMode ||
                    (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && pm.isDeviceIdleMode)
                )
            if (constrained) {
                if (powerWakeLock?.isHeld != true) {
                    powerWakeLock = pm.newWakeLock(
                        android.os.PowerManager.PARTIAL_WAKE_LOCK,
                        "ReVoltVPN:Runtime",
                    ).apply {
                        setReferenceCounted(false)
                        acquire()
                    }
                }
            } else if (powerWakeLock?.isHeld == true) {
                powerWakeLock?.release()
                powerWakeLock = null
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not update VPN power lock", e)
        }
    }

    private fun ensurePowerReceiver() {
        if (powerReceiver != null) {
            updatePowerWakeLock()
            return
        }
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: android.content.Context?, intent: Intent?) {
                updatePowerWakeLock()
            }
        }
        val filter = android.content.IntentFilter().apply {
            addAction(android.os.PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
            addAction(android.os.PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(receiver, filter, android.content.Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                registerReceiver(receiver, filter)
            }
            powerReceiver = receiver
        } catch (e: Exception) {
            Log.w(TAG, "Could not register power-state receiver", e)
        }
        updatePowerWakeLock()
    }

    private fun stopRuntimeHealthMonitor() {
        runtimeHealthRunning = false
        runtimeHealthThread?.interrupt()
        runtimeHealthThread = null
        try { File(filesDir, "vpn_runtime_health.json").delete() } catch (_: Exception) {}
        try { File(filesDir, "vpn_runtime_health.tmp").delete() } catch (_: Exception) {}
        val receiver = powerReceiver
        powerReceiver = null
        if (receiver != null) {
            try { unregisterReceiver(receiver) } catch (_: Exception) {}
        }
        if (powerWakeLock?.isHeld == true) {
            try { powerWakeLock?.release() } catch (_: Exception) {}
        }
        powerWakeLock = null
    }

    private fun startRuntimeHealthMonitor(config: XrayConfig, proxyOnly: Boolean) {
        stopRuntimeHealthMonitor()
        proxyOnlyMode = proxyOnly
        runtimeHealthRunning = true
        ensurePowerReceiver()

        runtimeHealthThread = Thread {
            while (runtimeHealthRunning && isRunning && currentConfig === config) {
                val xrayAlive = XrayCoreManager.isXrayProcessAlive()
                val tunAlive = proxyOnly || tun2socksProcess?.isAlive == true
                val fdReady = proxyOnly || tunFdReady
                val outboundReady = xrayAlive && probeSecureSocks(config)
                val healthy = xrayAlive && tunAlive && fdReady && outboundReady

                if (healthy) {
                    if (AppConfigs.V2RAY_STATE != AppConfigs.V2RAY_STATES.V2RAY_CONNECTED) {
                        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTED
                    }
                } else if (AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED) {
                    AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING
                }

                writeRuntimeHealth(healthy, xrayAlive, tunAlive, fdReady, outboundReady)
                updatePowerWakeLock()
                try {
                    Thread.sleep(if (healthy) 5000L else 1500L)
                } catch (_: InterruptedException) {
                    break
                }
            }
        }.apply {
            name = "ReVolt-runtime-health"
            isDaemon = true
            start()
        }
    }

    private fun scheduleTun2socksRecovery(config: XrayConfig, reason: String) {
        if (!isRunning || currentConfig !== config || tunRecoveryActive) return
        tunRecoveryActive = true
        tunFdReady = false
        Log.w(TAG, "Scheduling tun2socks recovery: $reason")
        Thread {
            val delays = longArrayOf(500L, 1000L, 2000L, 4000L, 8000L, 15000L, 30000L)
            var attempt = 0
            try {
                while (isRunning && currentConfig === config) {
                    Thread.sleep(delays[attempt.coerceAtMost(delays.lastIndex)])
                    if (!isRunning || currentConfig !== config) break
                    if (tun2socksProcess?.isAlive == true && tunFdReady) break
                    Log.w(TAG, "Recovering tun2socks attempt ${attempt + 1}")
                    runTun2socks(config)
                    Thread.sleep(1000L)
                    if (tun2socksProcess?.isAlive == true && tunFdReady) break
                    attempt++
                }
            } catch (_: InterruptedException) {
            } finally {
                tunRecoveryActive = false
            }
        }.apply {
            name = "ReVolt-tun2socks-recovery"
            isDaemon = true
            start()
        }
    }

''';
    text = replaceOnce(text, marker, '$helpers$marker', 'runtime health helpers');
  }

  text = replaceOnce(
    text,
    '                if (XrayCoreManager.startCore(this, config)) {\n',
    '                if (XrayCoreManager.startCore(this, config)) {\n'
        '                    // Xray being alive is not enough. Stay CONNECTING until\n'
        '                    // the secure SOCKS outbound and (for TUN) FD path verify.\n'
        '                    AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING\n',
    'gate CONNECTED on end-to-end runtime health',
  );

  text = replaceOnce(
    text,
    '                        Log.d(TAG, "Starting in PROXY_ONLY mode")\n',
    '                        Log.d(TAG, "Starting in PROXY_ONLY mode")\n'
        '                        startRuntimeHealthMonitor(config, true)\n',
    'proxy health monitor start',
  );

  text = replaceOnce(
    text,
    '            builder.addAddress("26.26.26.1", 30)\n',
    '            builder.addAddress("26.26.26.1", 30)\n'
        '            // Capture IPv6 too. If the native forwarder cannot carry it,\n'
        '            // traffic fails inside the TUN instead of leaking via the ISP.\n'
        '            builder.addAddress("fd00:26:26::1", 126)\n'
        '            builder.addRoute("::", 0)\n',
    'IPv6 fail-closed route',
  );

  text = replaceOnce(
    text,
    '            runTun2socks(config)\n',
    '            runTun2socks(config)\n            startRuntimeHealthMonitor(config, false)\n',
    'TUN health monitor start',
  );

  text = replaceOnce(
    text,
    '    private fun runTun2socks(config: XrayConfig) {\n        val secure = secureSocksCredentials(config)\n',
    '    private fun runTun2socks(config: XrayConfig) {\n'
        '        tunFdReady = false\n'
        '        val secure = secureSocksCredentials(config)\n',
    'reset FD readiness before tun2socks start',
  );

  const oldCrashRecovery = r'''                    if (isRunning && tun2socksProcess === process && currentConfig === config) {
                        Log.e(TAG, "tun2socks exited unexpectedly, recycling without dropping TUN")
                        Thread.sleep(350)
                        if (isRunning && currentConfig === config) runTun2socks(config)
                    }
''';
  const newCrashRecovery = r'''                    if (isRunning && tun2socksProcess === process && currentConfig === config) {
                        tunFdReady = false
                        scheduleTun2socksRecovery(config, "process exited")
                    }
''';
  text = replaceOnce(text, oldCrashRecovery, newCrashRecovery, 'single tun2socks recovery worker');

  const oldStartFailure = r'''        } catch (e: Exception) {
            Log.e(TAG, "Failed to start tun2socks; retrying with TUN held", e)
            if (isRunning && currentConfig === config) {
                Thread {
                    try {
                        Thread.sleep(600)
                        if (isRunning && currentConfig === config) runTun2socks(config)
                    } catch (_: InterruptedException) {}
                }.start()
            }
        }
''';
  const newStartFailure = r'''        } catch (e: Exception) {
            Log.e(TAG, "Failed to start tun2socks; keeping TUN fail-closed", e)
            tunFdReady = false
            scheduleTun2socksRecovery(config, "start failure")
        }
''';
  text = replaceOnce(text, oldStartFailure, newStartFailure, 'bounded tun2socks start recovery');

  text = replaceOnce(
    text,
    '                    localSocket.close()\n                    return@Thread\n',
    '                    localSocket.close()\n                    tunFdReady = true\n                    return@Thread\n',
    'mark successful TUN FD handoff',
  );

  const oldXrayRecovery = r'''    fun handleXrayCoreExit(config: XrayConfig) {
        if (!isRunning || currentConfig !== config || recoveringXray) return
        recoveringXray = true

        Thread {
            var attempt = 0
            try {
                while (isRunning && currentConfig === config) {
                    attempt++
                    Thread.sleep(400L * attempt.coerceAtMost(5))
                    if (!isRunning || currentConfig !== config) break

                    Log.w(TAG, "Recovering Xray core attempt $attempt")
                    if (XrayCoreManager.startCore(this, config)) {
                        Log.w(TAG, "Xray core recovered without dropping TUN")
                        return@Thread
                    }

                    if (attempt >= 3) {
                        attempt = 0
                        Thread.sleep(3000)
                    }
                }
            } catch (_: InterruptedException) {
            } finally {
                recoveringXray = false
            }
        }.start()
    }
''';
  const newXrayRecovery = r'''    fun handleXrayCoreExit(config: XrayConfig) {
        if (!isRunning || currentConfig !== config || recoveringXray) return
        recoveringXray = true
        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING

        Thread {
            val delays = longArrayOf(500L, 1000L, 2000L, 4000L, 8000L, 15000L, 30000L)
            var attempt = 0
            try {
                while (isRunning && currentConfig === config) {
                    Thread.sleep(delays[attempt.coerceAtMost(delays.lastIndex)])
                    if (!isRunning || currentConfig !== config) break

                    Log.w(TAG, "Recovering Xray core attempt ${attempt + 1}")
                    if (XrayCoreManager.startCore(this, config)) {
                        Log.w(TAG, "Xray core process restarted; awaiting end-to-end health")
                        return@Thread
                    }
                    attempt++
                }
            } catch (_: InterruptedException) {
            } finally {
                recoveringXray = false
            }
        }.apply {
            name = "ReVolt-xray-recovery"
            isDaemon = true
            start()
        }
    }
''';
  text = replaceOnce(text, oldXrayRecovery, newXrayRecovery, 'backed-off Xray recovery');

  text = replaceOnce(
    text,
    '        isRunning = false\n        recoveringXray = false\n        tun2socksProcess?.destroy()\n',
    '        isRunning = false\n'
        '        stopRuntimeHealthMonitor()\n'
        '        recoveringXray = false\n'
        '        tunRecoveryActive = false\n'
        '        tunFdReady = false\n'
        '        tun2socksProcess?.destroy()\n',
    'cleanup runtime health and recovery workers',
  );

  writeIfChanged(file, before, text);
}

void main() {
  final root = packageRoot();
  final android = Directory('${root.path}/android');
  final kotlin = Directory(
    '${android.path}/src/main/kotlin/com/github/tfox/flutter_vless',
  );

  final manifest = File('${android.path}/src/main/AndroidManifest.xml');
  final plugin = File('${kotlin.path}/FlutterVlessPlugin.kt');
  final core = File('${kotlin.path}/xray/core/XrayCoreManager.kt');
  final service = File('${kotlin.path}/xray/service/XrayVPNService.kt');

  for (final file in [manifest, plugin, core, service]) {
    if (!file.existsSync()) fail('missing pinned runtime source: ${file.path}');
  }

  patchManifest(manifest);
  patchPlugin(plugin);
  patchCore(core);
  patchService(service);
  stdout.writeln('[runtime reliability patch] Android runtime hardening ready');
}
