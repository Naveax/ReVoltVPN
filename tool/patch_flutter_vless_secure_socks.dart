import 'dart:convert';
import 'dart:io';

const packageName = 'flutter_vless_android';
const expectedVersionFragment = 'flutter_vless_android-1.1.5';

Never fail(String message) {
  stderr.writeln('[secure-socks native patch] $message');
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
  if (!root.existsSync()) fail('package root does not exist: ${root.path}');
  return root;
}

void replaceOnce(
  File file,
  String oldValue,
  String newValue,
  String marker,
) {
  if (!file.existsSync()) fail('missing upstream source: ${file.path}');
  final text = file.readAsStringSync();
  if (text.contains(marker)) {
    stdout.writeln('[secure-socks native patch] already current: ${file.path}');
    return;
  }
  if (!text.contains(oldValue)) {
    fail('upstream source changed; expected block not found: ${file.path}');
  }
  file.writeAsStringSync(text.replaceFirst(oldValue, newValue));
  stdout.writeln('[secure-socks native patch] patched: ${file.path}');
}

void main() {
  final root = packageRoot();
  final kotlin = Directory(
    '${root.path}/android/src/main/kotlin/com/github/tfox/flutter_vless',
  );
  final serviceFile = File('${kotlin.path}/xray/service/XrayVPNService.kt');
  final coreFile = File('${kotlin.path}/xray/core/XrayCoreManager.kt');

  replaceOnce(
    coreFile,
    '''        val inbounds = configJson.optJSONArray("inbounds") ?: JSONArray()
        val usedPorts = mutableSetOf<Int>()
        var hasSocksOnLocalPort = false
        var hasHttpOnLocalPort = false
        for (i in 0 until inbounds.length()) {
            val inbound = inbounds.getJSONObject(i)
            val protocol = inbound.optString("protocol")
            val port = inbound.optInt("port", -1)
            if (port > 0) usedPorts.add(port)
            if (protocol == "socks" && port == config.LOCAL_SOCKS5_PORT) hasSocksOnLocalPort = true
            if (protocol == "http" && port == config.LOCAL_HTTP_PORT) hasHttpOnLocalPort = true
        }
''',
    '''        val inbounds = configJson.optJSONArray("inbounds") ?: JSONArray()
        val usedPorts = mutableSetOf<Int>()
        var hasSocksOnLocalPort = false
        var hasHttpOnLocalPort = false
        var secureSocksEnabled = false

        // ReVolt's secure SOCKS session is constructed in app memory for every
        // connection. Validate it here rather than silently falling back to a
        // no-auth local proxy if the handoff ever becomes malformed.
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

        val usedPorts = mutableSetOf<Int>()
        for (i in 0 until inbounds.length()) {
            val inbound = inbounds.getJSONObject(i)
            val protocol = inbound.optString("protocol")
            val port = inbound.optInt("port", -1)
            if (port > 0) usedPorts.add(port)
            if (protocol == "socks" && port == config.LOCAL_SOCKS5_PORT) hasSocksOnLocalPort = true
            if (protocol == "http" && port == config.LOCAL_HTTP_PORT) hasHttpOnLocalPort = true
        }
''',
    'var secureSocksEnabled = false',
  );

  replaceOnce(
    coreFile,
    '''        if (!hasHttpOnLocalPort) {
''',
    '''        // Do not expose the stock unauthenticated HTTP ingress beside the
        // authenticated SOCKS listener.
        if (!secureSocksEnabled && !hasHttpOnLocalPort) {
''',
    '!secureSocksEnabled && !hasHttpOnLocalPort',
  );

  replaceOnce(
    coreFile,
    '''            xrayProcess = pb.start()
            Thread.sleep(300)
            if (xrayProcess?.isAlive != true) {
                val output = xrayProcess?.inputStream?.bufferedReader()?.readText().orEmpty()
                Log.e(TAG, "Xray process exited during startup. Output: $output")
                xrayProcess = null
                AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED
                return false
            }
            
            AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTED
''',
    '''            val process = pb.start()
            xrayProcess = process
            Thread.sleep(300)
            if (!process.isAlive) {
                val output = process.inputStream.bufferedReader().readText()
                Log.e(TAG, "Xray process exited during startup. Output: $output")
                if (xrayProcess === process) xrayProcess = null
                AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED
                return false
            }

            // The generated config contains per-session SOCKS credentials. Xray
            // has already read it at this point, so remove the file immediately
            // instead of leaving credentials at rest for the full VPN session.
            try {
                val ephemeralConfig = File(configFilesDir, "config.json")
                if (ephemeralConfig.exists() && !ephemeralConfig.delete()) {
                    Log.w(TAG, "Could not delete ephemeral Xray config")
                }
            } catch (e: Exception) {
                Log.w(TAG, "Could not delete ephemeral Xray config", e)
            }

            AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTED
''',
    'Could not delete ephemeral Xray config',
  );

  replaceOnce(
    coreFile,
    '''            Thread {
                try {
                    xrayProcess?.inputStream?.bufferedReader()?.use { reader ->
                        reader.forEachLine { line ->
                            Log.d(TAG, "xray: $line")
                        }
                    }
                    
                    val exitCode = xrayProcess?.waitFor()
                    Log.e(TAG, "Xray process exited with code $exitCode")
                    if (AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED) {
                        // Unexpected exit
                        stopCore(context)
                    }
                } catch (e: java.io.InterruptedIOException) {
                    // Expected when stopping
                } catch (e: InterruptedException) {
                    // Expected when stopping
                } catch (e: Exception) {
                    Log.e(TAG, "Error reading xray output", e)
                }
            }.start()
''',
    '''            Thread {
                try {
                    process.inputStream.bufferedReader().use { reader ->
                        reader.forEachLine { line ->
                            Log.d(TAG, "xray: $line")
                        }
                    }

                    val exitCode = process.waitFor()
                    Log.e(TAG, "Xray process exited with code $exitCode")
                    if (xrayProcess === process &&
                        AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED
                    ) {
                        // Keep the Android TUN alive. A direct service teardown
                        // here would let traffic fall back outside the VPN.
                        xrayProcess = null
                        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING
                        if (context is XrayVPNService) {
                            context.handleXrayCoreExit(config)
                        } else {
                            stopCore(context)
                        }
                    }
                } catch (e: java.io.InterruptedIOException) {
                    // Expected when stopping
                } catch (e: InterruptedException) {
                    // Expected when stopping
                } catch (e: Exception) {
                    Log.e(TAG, "Error reading xray output", e)
                }
            }.start()
''',
    'context.handleXrayCoreExit(config)',
  );

  replaceOnce(
    serviceFile,
    '''    private var mInterface: ParcelFileDescriptor? = null
    private var tun2socksProcess: Process? = null
    private var isRunning = false
''',
    '''    private var mInterface: ParcelFileDescriptor? = null
    private var tun2socksProcess: Process? = null
    @Volatile private var isRunning = false
    @Volatile private var recoveringXray = false
    private var currentConfig: XrayConfig? = null
''',
    'private var recoveringXray = false',
  );

  replaceOnce(
    serviceFile,
    '''        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
''',
    '''        if (intent == null) {
            // START_REDELIVER_INTENT should normally restore the START command.
            // Do not tear down an already-live TUN merely because Android sent
            // a transient null intent to the existing service instance.
            if (isRunning && currentConfig != null) return START_REDELIVER_INTENT
            stopSelf()
            return START_NOT_STICKY
        }
''',
    'if (isRunning && currentConfig != null) return START_REDELIVER_INTENT',
  );

  replaceOnce(
    serviceFile,
    '''                cleanup()
                
                // Check if we should run in Proxy Only mode (no VPN interface)
''',
    '''                cleanup()
                currentConfig = config

                // Check if we should run in Proxy Only mode (no VPN interface)
''',
    'currentConfig = config',
  );

  replaceOnce(
    serviceFile,
    '''        return START_STICKY
''',
    '''        return START_REDELIVER_INTENT
''',
    'return START_REDELIVER_INTENT',
  );

  replaceOnce(
    serviceFile,
    '''    /**
     * Starts the tun2socks process and initiates the FD transfer.
     */
    private fun runTun2socks(config: XrayConfig) {
''',
    '''    private data class SecureSocksCredentials(
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

    /**
     * Starts the tun2socks process and initiates the FD transfer.
     */
    private fun runTun2socks(config: XrayConfig) {
''',
    'private data class SecureSocksCredentials(',
  );

  replaceOnce(
    serviceFile,
    '''        // Command to start tun2socks. 
        // Note: We pass -sock-path to tell it where to listen for the FD.
        val cmd = arrayListOf(
            tun2socksPath,
            "-sock-path", sockPath,
            "-proxy", "socks5://127.0.0.1:${config.LOCAL_SOCKS5_PORT}",
            "-mtu", "1500",
            "-loglevel", "debug"
        )

        Log.d(TAG, "tun2socks command: ${cmd.joinToString(" ")}")

        try {
            val pb = ProcessBuilder(cmd)
            pb.redirectErrorStream(true)
            pb.directory(filesDir)
            tun2socksProcess = pb.start()

            // Read tun2socks output in a separate thread
            Thread {
                try {
                    tun2socksProcess?.inputStream?.bufferedReader()?.use { reader ->
                        reader.forEachLine { line ->
                            Log.d(TAG, "tun2socks: $line")
                        }
                    }
                    
                    tun2socksProcess?.waitFor()
                    if (isRunning) {
                        // Restart if crashed and still supposed to be running
                        Log.e(TAG, "tun2socks exited unexpectedly, restarting...")
                        runTun2socks(config)
                    }
                } catch (e: java.io.InterruptedIOException) {
                    // Expected when stopping
                } catch (e: InterruptedException) {
                } catch (e: Exception) {
                    Log.e(TAG, "Error reading tun2socks output", e)
                }
            }.start()

            // Send the TUN file descriptor to tun2socks via socket
            sendFd()

        } catch (e: Exception) {
            Log.e(TAG, "Failed to start tun2socks", e)
            stopAll()
        }
''',
    '''        val secure = secureSocksCredentials(config)
            ?: throw IllegalStateException("Authenticated ReVolt SOCKS5 inbound missing")
        config.LOCAL_SOCKS5_PORT = secure.port

        // Do not log this command: it contains per-session SOCKS credentials.
        val cmd = arrayListOf(
            tun2socksPath,
            "-sock-path", sockPath,
            "-proxy", "socks5://${secure.username}:${secure.password}@127.0.0.1:${secure.port}",
            "-mtu", "1500",
            "-loglevel", "warning"
        )

        Log.d(TAG, "Starting tun2socks with authenticated loopback SOCKS5")

        try {
            val pb = ProcessBuilder(cmd)
            pb.redirectErrorStream(true)
            pb.directory(filesDir)
            val process = pb.start()
            tun2socksProcess = process

            Thread {
                try {
                    process.inputStream.bufferedReader().use { reader ->
                        reader.forEachLine { line ->
                            Log.d(TAG, "tun2socks: $line")
                        }
                    }
                    process.waitFor()
                    if (isRunning && tun2socksProcess === process && currentConfig === config) {
                        Log.e(TAG, "tun2socks exited unexpectedly, recycling without dropping TUN")
                        Thread.sleep(350)
                        if (isRunning && currentConfig === config) runTun2socks(config)
                    }
                } catch (e: java.io.InterruptedIOException) {
                    // Expected when stopping
                } catch (e: InterruptedException) {
                } catch (e: Exception) {
                    Log.e(TAG, "Error reading tun2socks output", e)
                    if (isRunning && tun2socksProcess === process && currentConfig === config) {
                        Thread.sleep(500)
                        if (isRunning && currentConfig === config) runTun2socks(config)
                    }
                }
            }.start()

            sendFd(process)

        } catch (e: Exception) {
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
''',
    'Authenticated ReVolt SOCKS5 inbound missing',
  );

  replaceOnce(
    serviceFile,
    '''    private fun sendFd() {
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
''',
    '''    private fun sendFd(process: Process) {
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
''',
    'FD handoff failed; recycling tun2socks without dropping TUN',
  );

  replaceOnce(
    serviceFile,
    '''    /**
     * Cleans up resources (tun2socks process, VPN interface) without stopping the service completely.
     * Used when restarting or switching configurations.
     */
    private fun cleanup() {
''',
    '''    fun handleXrayCoreExit(config: XrayConfig) {
        if (!isRunning || currentConfig !== config || recoveringXray) return
        recoveringXray = true

        Thread {
            var attempt = 0
            try {
                while (isRunning && currentConfig === config) {
                    attempt++
                    Thread.sleep((400L * attempt.coerceAtMost(5)))
                    if (!isRunning || currentConfig !== config) break

                    Log.w(TAG, "Recovering Xray core attempt $attempt")
                    if (XrayCoreManager.startCore(this, config)) {
                        Log.w(TAG, "Xray core recovered without dropping TUN")
                        return@Thread
                    }

                    // Continue fail-closed with the TUN held. After the first
                    // few quick attempts, back off before trying again.
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

    /**
     * Cleans up resources (tun2socks process, VPN interface) without stopping the service completely.
     * Used when restarting or switching configurations.
     */
    private fun cleanup() {
''',
    'fun handleXrayCoreExit(config: XrayConfig)',
  );

  replaceOnce(
    serviceFile,
    '''    private fun cleanup() {
        isRunning = false
        tun2socksProcess?.destroy()
''',
    '''    private fun cleanup() {
        isRunning = false
        recoveringXray = false
        tun2socksProcess?.destroy()
''',
    'recoveringXray = false\n        tun2socksProcess?.destroy()',
  );

  replaceOnce(
    serviceFile,
    '''    private fun stopAll() {
        cleanup()
        XrayCoreManager.stopCore(this)
''',
    '''    private fun stopAll() {
        cleanup()
        currentConfig = null
        XrayCoreManager.stopCore(this)
''',
    'currentConfig = null\n        XrayCoreManager.stopCore(this)',
  );

  stdout.writeln('[secure-socks native patch] authenticated stable-core patch is ready');
}
