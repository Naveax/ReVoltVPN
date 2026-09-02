import 'dart:convert';
import 'dart:io';

const packageName = 'flutter_vless_android';
const expectedVersionFragment = 'flutter_vless_android-1.1.5';

Never fail(String message) {
  stderr.writeln('[secure-socks patch] $message');
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
    stdout.writeln('[secure-socks patch] already current: ${file.path}');
    return;
  }
  file.writeAsStringSync(after);
  stdout.writeln('[secure-socks patch] patched: ${file.path}');
}

void patchCore(File file) {
  final before = file.readAsStringSync();
  var text = before;

  const secureValidation = r'''        var secureSocksEnabled = false
        for (i in 0 until inbounds.length()) {
            val inbound = inbounds.optJSONObject(i) ?: continue
            if (inbound.optString("tag") != "revolt-secure-socks") continue

            val settings = inbound.optJSONObject("settings")
                ?: throw IllegalStateException("Secure SOCKS5 settings are missing")
            val users = settings.optJSONArray("users")
                ?: throw IllegalStateException("Secure SOCKS5 users are missing")
            val account = users.optJSONObject(0)
                ?: throw IllegalStateException("Secure SOCKS5 account is missing")
            val port = inbound.optInt("port", -1)

            if (inbound.optString("protocol") != "socks" ||
                inbound.optString("listen") != "127.0.0.1" ||
                port <= 1024 || port > 65535 ||
                settings.optString("auth") != "password" ||
                account.optString("user").isEmpty() ||
                account.optString("pass").isEmpty()
            ) {
                throw IllegalStateException("Secure SOCKS5 session is invalid")
            }

            config.LOCAL_SOCKS5_PORT = port
            config.LOCAL_HTTP_PORT = 0
            secureSocksEnabled = true
            break
        }

''';

  if (!text.contains('var secureSocksEnabled = false')) {
    text = replaceOnce(
      text,
      '        val usedPorts = mutableSetOf<Int>()\n',
      '$secureValidation        val usedPorts = mutableSetOf<Int>()\n',
      'secure SOCKS validation insertion',
    );
  }

  text = replaceOnce(
    text,
    '        if (!hasHttpOnLocalPort) {\n',
    '        if (!secureSocksEnabled && !hasHttpOnLocalPort) {\n',
    'disable unauthenticated HTTP proxy in secure mode',
  );

  if (!text.contains('val process = pb.start()')) {
    text = replaceOnce(
      text,
      '            xrayProcess = pb.start()\n',
      '            val process = pb.start()\n            xrayProcess = process\n',
      'capture Xray process identity',
    );
    text = replaceOnce(
      text,
      '            if (xrayProcess?.isAlive != true) {\n',
      '            if (!process.isAlive) {\n',
      'Xray startup liveness',
    );
    text = replaceOnce(
      text,
      '                val output = xrayProcess?.inputStream?.bufferedReader()?.readText().orEmpty()\n',
      '                val output = process.inputStream.bufferedReader().readText()\n',
      'Xray startup output',
    );
  }

  if (!text.contains('Could not delete ephemeral Xray config')) {
    const connectedLine =
        '            AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTED\n';
    const deleteConfig = r'''            // config.json contains per-session SOCKS credentials. Xray has
            // consumed it after the startup liveness check, so remove it now.
            try {
                val ephemeralConfig = File(configFilesDir, "config.json")
                if (ephemeralConfig.exists() && !ephemeralConfig.delete()) {
                    Log.w(TAG, "Could not delete ephemeral Xray config")
                }
            } catch (e: Exception) {
                Log.w(TAG, "Could not delete ephemeral Xray config", e)
            }

''';
    text = replaceOnce(
      text,
      connectedLine,
      '$deleteConfig$connectedLine',
      'ephemeral config deletion',
    );
  }

  if (!text.contains('context.handleXrayCoreExit(config)')) {
    text = replaceOnce(
      text,
      '                    xrayProcess?.inputStream?.bufferedReader()?.use { reader ->\n',
      '                    process.inputStream.bufferedReader().use { reader ->\n',
      'Xray monitor process stream',
    );
    text = replaceOnce(
      text,
      '                    val exitCode = xrayProcess?.waitFor()\n',
      '                    val exitCode = process.waitFor()\n',
      'Xray monitor process wait',
    );

    const oldExit = r'''                    if (AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED) {
                        // Unexpected exit
                        stopCore(context)
                    }
''';
    const newExit = r'''                    if (xrayProcess === process &&
                        AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED
                    ) {
                        // Hold the Android TUN while the core is recovered. Killing
                        // the VPN service here would allow direct-network fallback.
                        xrayProcess = null
                        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING
                        if (context is XrayVPNService) {
                            context.handleXrayCoreExit(config)
                        } else {
                            stopCore(context)
                        }
                    }
''';
    text = replaceOnce(text, oldExit, newExit, 'Xray fail-closed recovery');
  }

  writeIfChanged(file, before, text);
}

void patchService(File file) {
  final before = file.readAsStringSync();
  var text = before;

  if (!text.contains('private var recoveringXray = false')) {
    text = replaceOnce(
      text,
      '    private var isRunning = false\n',
      '    @Volatile private var isRunning = false\n'
          '    @Volatile private var recoveringXray = false\n'
          '    private var currentConfig: XrayConfig? = null\n',
      'service recovery fields',
    );
  }

  if (!text.contains('private data class PersistedSession(')) {
    const persistenceHelpers = r'''    private data class PersistedSession(
        val proxyOnly: Boolean,
        val config: XrayConfig,
        val sessionExpiresAtMs: Long,
    ) : java.io.Serializable

    private var proxyOnlyMode = false
    private var sessionExpiresAtMs = 0L

    private val expiryHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val expiryRunnable = Runnable {
        if (sessionExpiresAtMs > 0 && System.currentTimeMillis() >= sessionExpiresAtMs) {
            Log.w(TAG, "Session expired; tearing down VPN")
            sessionExpiresAtMs = 0L
            cancelExpiryAlarm()
            postSessionExpiredNotification()
            deletePersistedSession()
            stopAll()
        }
    }

    private fun scheduleExpiryCheck() {
        expiryHandler.removeCallbacks(expiryRunnable)
        if (sessionExpiresAtMs > 0) {
            val delay = (sessionExpiresAtMs - System.currentTimeMillis()).coerceAtLeast(0)
            expiryHandler.postDelayed(expiryRunnable, delay)
        }
        scheduleExpiryAlarm()
    }

    private fun scheduleExpiryAlarm() {
        cancelExpiryAlarm()
        if (sessionExpiresAtMs <= 0) return
        try {
            val alarmManager = getSystemService(android.content.Context.ALARM_SERVICE) as android.app.AlarmManager
            try {
                alarmManager.setExactAndAllowWhileIdle(
                    android.app.AlarmManager.RTC_WAKEUP,
                    sessionExpiresAtMs,
                    sessionExpiredPendingIntent(),
                )
            } catch (e: SecurityException) {
                alarmManager.setAndAllowWhileIdle(
                    android.app.AlarmManager.RTC_WAKEUP,
                    sessionExpiresAtMs,
                    sessionExpiredPendingIntent(),
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to schedule expiry alarm", e)
        }
    }

    private fun cancelExpiryAlarm() {
        try {
            val alarmManager = getSystemService(android.content.Context.ALARM_SERVICE) as android.app.AlarmManager
            alarmManager.cancel(sessionExpiredPendingIntent())
        } catch (e: Exception) {
        }
    }

    private fun sessionExpiredPendingIntent(): android.app.PendingIntent {
        val intent = Intent(this, XrayVPNService::class.java)
        intent.putExtra("SESSION_EXPIRED", true)
        val flags = android.app.PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                android.app.PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        return android.app.PendingIntent.getService(this, 1001, intent, flags)
    }

    private fun persistSession() {
        val config = currentConfig ?: return
        try {
            java.io.ObjectOutputStream(
                java.io.FileOutputStream(File(filesDir, "active_session.bin")),
            ).use { it.writeObject(PersistedSession(proxyOnlyMode, config, sessionExpiresAtMs)) }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to persist active session", e)
        }
    }

    private fun loadPersistedSession(): PersistedSession? {
        return try {
            val file = File(filesDir, "active_session.bin")
            if (!file.exists()) return null
            java.io.ObjectInputStream(java.io.FileInputStream(file)).use {
                it.readObject() as? PersistedSession
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to restore persisted session", e)
            null
        }
    }

    private fun deletePersistedSession() {
        try {
            File(filesDir, "active_session.bin").delete()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to delete persisted session", e)
        }
    }

    private fun postSessionExpiredNotification() {
        try {
            createNotificationChannel()
            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT
            } else {
                android.app.PendingIntent.FLAG_UPDATE_CURRENT
            }
            val contentIntent = if (launchIntent != null) {
                android.app.PendingIntent.getActivity(this, 0, launchIntent, flags)
            } else {
                null
            }
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                android.app.Notification.Builder(this, "vpn_service_channel")
            } else {
                @Suppress("DEPRECATION")
                android.app.Notification.Builder(this)
            }
            builder
                .setContentTitle("Revolt VPN")
                .setContentText("Session expired. Reconnect to continue.")
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setAutoCancel(true)
            if (contentIntent != null) {
                builder.setContentIntent(contentIntent)
            }
            val manager = getSystemService(android.app.NotificationManager::class.java)
            manager?.notify(2, builder.build())
        } catch (e: Exception) {
            Log.w(TAG, "Failed to post session expired notification", e)
        }
    }
''';
    text = replaceOnce(
      text,
      '    override fun onCreate() {\n        super.onCreate()\n    }\n',
      '    override fun onCreate() {\n        super.onCreate()\n    }\n\n$persistenceHelpers',
      'session persistence helpers',
    );
  }

  // Snapshot the running config so a START_STICKY restart can re-establish it.
  if (!text.contains('                currentConfig = config\n')) {
    text = replaceOnce(
      text,
      '                cleanup()\n',
      '                cleanup()\n                currentConfig = config\n',
      'runtime config snapshot',
    );
  }

  text = replaceOnce(
    text,
    '                val proxyOnly = intent.getBooleanExtra("PROXY_ONLY", false)\n',
    '                val proxyOnly = intent.getBooleanExtra("PROXY_ONLY", false)\n                proxyOnlyMode = proxyOnly\n                persistSession()\n',
    'persist session snapshot',
  );

  text = replaceOnce(
    text,
    '        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE) {\n            stopAll()\n            return START_NOT_STICKY\n        }\n',
    '        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE) {\n            deletePersistedSession()\n            stopAll()\n            return START_NOT_STICKY\n        }\n',
    'delete session on explicit stop',
  );

  const oldNullIntent = r'''        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
''';
  const newNullIntent = r'''        if (intent == null) {
            if (isRunning && currentConfig != null) return START_STICKY
            val persisted = loadPersistedSession()
            if (persisted != null) {
                Log.w(TAG, "Re-establishing VPN from persisted session")
                createNotificationChannel()
                val notification = createNotification("VPN Service Running")
                try {
                    if (Build.VERSION.SDK_INT >= 34) {
                        startForeground(1, notification, FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
                    } else {
                        startForeground(1, notification)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to start foreground", e)
                }
                if (XrayCoreManager.isXrayRunning()) {
                    Log.w(TAG, "Stopping stale Xray core before restart")
                    XrayCoreManager.stopCore(this)
                }
                cleanup()
                currentConfig = persisted.config
                proxyOnlyMode = persisted.proxyOnly
                sessionExpiresAtMs = persisted.sessionExpiresAtMs
                if (XrayCoreManager.startCore(this, persisted.config)) {
                    if (!persisted.proxyOnly) {
                        setupVpn(persisted.config)
                    } else {
                        isRunning = true
                    }
                    scheduleExpiryCheck()
                } else {
                    stopSelf()
                    return START_NOT_STICKY
                }
                return START_STICKY
            }
            stopSelf()
            return START_NOT_STICKY
        }
''';
  text = replaceOnce(
    text,
    oldNullIntent,
    newNullIntent,
    'null intent lifecycle',
  );

  text = replaceOnce(
    text,
    '        val command = if (Build.VERSION.SDK_INT >= 33) {\n',
    '        if (intent.getBooleanExtra("SESSION_EXPIRED", false)) {\n            Log.w(TAG, "Session-expiry alarm fired; tearing down VPN")\n            sessionExpiresAtMs = 0L\n            cancelExpiryAlarm()\n            deletePersistedSession()\n            postSessionExpiredNotification()\n            stopAll()\n            return START_NOT_STICKY\n        }\n\n        if (intent.hasExtra("SESSION_EXPIRES_AT_MS")) {\n            sessionExpiresAtMs = intent.getLongExtra("SESSION_EXPIRES_AT_MS", 0L)\n            scheduleExpiryCheck()\n            persistSession()\n            return if (isRunning && currentConfig != null) START_STICKY else START_NOT_STICKY\n        }\n\n        val command = if (Build.VERSION.SDK_INT >= 33) {\n',
    'session expiry update',
  );


  if (!text.contains('private data class SecureSocksCredentials(')) {
    const credentialsHelper = r'''    private data class SecureSocksCredentials(
        val port: Int,
        val username: String,
        val password: String,
    )

    private fun secureSocksCredentials(config: XrayConfig): SecureSocksCredentials? {
        val inbounds = try {
            JSONObject(config.V2RAY_FULL_JSON_CONFIG).optJSONArray("inbounds")
        } catch (_: Exception) {
            null
        } ?: return null

        for (i in 0 until inbounds.length()) {
            val inbound = inbounds.optJSONObject(i) ?: continue
            if (inbound.optString("tag") != "revolt-secure-socks") continue
            if (inbound.optString("protocol") != "socks" ||
                inbound.optString("listen") != "127.0.0.1"
            ) return null

            val settings = inbound.optJSONObject("settings") ?: return null
            if (settings.optString("auth") != "password") return null
            val user = settings.optJSONArray("users")?.optJSONObject(0) ?: return null
            val port = inbound.optInt("port", -1)
            val username = user.optString("user")
            val password = user.optString("pass")
            if (port <= 1024 || port > 65535 || username.isEmpty() || password.isEmpty()) {
                return null
            }
            return SecureSocksCredentials(port, username, password)
        }
        return null
    }

''';
    const runComment = r'''    /**
     * Starts the tun2socks process and initiates the FD transfer.
     */
    private fun runTun2socks(config: XrayConfig) {
''';
    text = replaceOnce(
      text,
      runComment,
      '$credentialsHelper$runComment',
      'secure credentials helper',
    );
  }

  if (!text.contains('Authenticated ReVolt SOCKS5 inbound missing')) {
    const commandComment = r'''        // Command to start tun2socks. 
        // Note: We pass -sock-path to tell it where to listen for the FD.
''';
    const securePrelude = r'''        val secure = secureSocksCredentials(config)
            ?: throw IllegalStateException("Authenticated ReVolt SOCKS5 inbound missing")
        config.LOCAL_SOCKS5_PORT = secure.port

''';
    text = replaceOnce(
      text,
      commandComment,
      '$securePrelude$commandComment',
      'secure tun2socks credentials',
    );
    text = replaceOnce(
      text,
      r'''            "-proxy", "socks5://127.0.0.1:${config.LOCAL_SOCKS5_PORT}",
''',
      r'''            "-proxy", "socks5://${secure.username}:${secure.password}@127.0.0.1:${secure.port}",
''',
      'authenticated tun2socks URL',
    );
    text = replaceOnce(
      text,
      r'''        Log.d(TAG, "tun2socks command: ${cmd.joinToString(" ")}")
''',
      '        Log.d(TAG, "Starting tun2socks with authenticated loopback SOCKS5")\n',
      'credential-safe logging',
    );
  }

  if (!text.contains('val process = pb.start()\n            tun2socksProcess = process')) {
    text = replaceOnce(
      text,
      '            tun2socksProcess = pb.start()\n',
      '            val process = pb.start()\n            tun2socksProcess = process\n',
      'capture tun2socks process identity',
    );
    text = replaceOnce(
      text,
      '                    tun2socksProcess?.inputStream?.bufferedReader()?.use { reader ->\n',
      '                    process.inputStream.bufferedReader().use { reader ->\n',
      'tun2socks monitor stream',
    );
    text = replaceOnce(
      text,
      '                    tun2socksProcess?.waitFor()\n',
      '                    process.waitFor()\n',
      'tun2socks monitor wait',
    );

    const oldRestart = r'''                    if (isRunning) {
                        // Restart if crashed and still supposed to be running
                        Log.e(TAG, "tun2socks exited unexpectedly, restarting...")
                        runTun2socks(config)
                    }
''';
    const newRestart = r'''                    if (isRunning && tun2socksProcess === process && currentConfig === config) {
                        Log.e(TAG, "tun2socks exited unexpectedly, recycling without dropping TUN")
                        Thread.sleep(350)
                        if (isRunning && currentConfig === config) runTun2socks(config)
                    }
''';
    text = replaceOnce(
      text,
      oldRestart,
      newRestart,
      'tun2socks crash recovery',
    );
    text = replaceOnce(
      text,
      '            sendFd()\n',
      '            sendFd(process)\n',
      'FD handoff process identity',
    );
  }

  const oldStartFailure = r'''        } catch (e: Exception) {
            Log.e(TAG, "Failed to start tun2socks", e)
            stopAll()
        }
''';
  const newStartFailure = r'''        } catch (e: Exception) {
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
  text = replaceOnce(
    text,
    oldStartFailure,
    newStartFailure,
    'tun2socks start failure recovery',
  );

  if (!text.contains('FD handoff failed; recycling tun2socks without dropping TUN')) {
    const oldSendFd = r'''    private fun sendFd() {
        val fd = mInterface?.fileDescriptor ?: return
        val sockFile = File(filesDir, "sock_path").absolutePath

        Thread {
            var tries = 0
            while (tries < 10) {
                try {
                    Thread.sleep(500)
                    val localSocket = LocalSocket()
                    localSocket.connect(LocalSocketAddress(sockFile, LocalSocketAddress.Namespace.FILESYSTEM))
                    val out = localSocket.outputStream
                    // This magic call attaches the FD to the socket message
                    localSocket.setFileDescriptorsForSend(arrayOf(fd))
                    out.write(32) // Send a dummy byte to trigger the transfer
                    localSocket.setFileDescriptorsForSend(null)
                    localSocket.shutdownOutput()
                    localSocket.close()
                    break
                } catch (e: Exception) {
                    tries++
                }
            }
        }.start()
    }
''';
    const newSendFd = r'''    private fun sendFd(process: Process) {
        val fd = mInterface?.fileDescriptor ?: return
        val sockFile = File(filesDir, "sock_path").absolutePath

        Thread {
            var tries = 0
            while (tries < 10 && isRunning && tun2socksProcess === process && process.isAlive) {
                var localSocket: LocalSocket? = null
                try {
                    Thread.sleep(500)
                    localSocket = LocalSocket()
                    localSocket.connect(LocalSocketAddress(sockFile, LocalSocketAddress.Namespace.FILESYSTEM))
                    val out = localSocket.outputStream
                    localSocket.setFileDescriptorsForSend(arrayOf(fd))
                    out.write(32)
                    out.flush()
                    localSocket.setFileDescriptorsForSend(null)
                    localSocket.shutdownOutput()
                    localSocket.close()
                    return@Thread
                } catch (_: Exception) {
                    tries++
                    try { localSocket?.close() } catch (_: Exception) {}
                }
            }

            if (isRunning && tun2socksProcess === process) {
                Log.e(TAG, "FD handoff failed; recycling tun2socks without dropping TUN")
                try { process.destroy() } catch (_: Exception) {}
            }
        }.start()
    }
''';
    text = replaceOnce(text, oldSendFd, newSendFd, 'bounded FD recovery');
  }

  if (!text.contains('fun handleXrayCoreExit(config: XrayConfig)')) {
    const cleanupComment = r'''    /**
     * Cleans up resources (tun2socks process, VPN interface) without stopping the service completely.
     * Used when restarting or switching configurations.
     */
''';
    const recovery = r'''    fun handleXrayCoreExit(config: XrayConfig) {
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
    text = replaceOnce(
      text,
      cleanupComment,
      '$recovery$cleanupComment',
      'Xray recovery loop',
    );
  }

  if (!text.contains('        cancelExpiryAlarm()\n        tun2socksProcess?.destroy()')) {
    text = replaceOnce(
      text,
      '        isRunning = false\n        tun2socksProcess?.destroy()\n',
      '        isRunning = false\n        recoveringXray = false\n        expiryHandler.removeCallbacks(expiryRunnable)\n        cancelExpiryAlarm()\n        tun2socksProcess?.destroy()\n',
      'cancel recovery and expiry on cleanup',
    );
  }

  if (!text.contains('        currentConfig = null\n        XrayCoreManager.stopCore(this)')) {
    text = replaceOnce(
      text,
      '        cleanup()\n        XrayCoreManager.stopCore(this)\n',
      '        cleanup()\n        currentConfig = null\n        XrayCoreManager.stopCore(this)\n',
      'clear config on explicit stop',
    );
  }

  writeIfChanged(file, before, text);
}

void main() {
  final root = packageRoot();
  final kotlin = Directory(
    '${root.path}/android/src/main/kotlin/com/github/tfox/flutter_vless',
  );
  final core = File('${kotlin.path}/xray/core/XrayCoreManager.kt');
  final service = File('${kotlin.path}/xray/service/XrayVPNService.kt');
  if (!core.existsSync() || !service.existsSync()) {
    fail('pinned Android runtime sources are missing');
  }

  patchCore(core);
  patchService(service);
  stdout.writeln('[secure-socks patch] stable-core security patch is ready');
}
