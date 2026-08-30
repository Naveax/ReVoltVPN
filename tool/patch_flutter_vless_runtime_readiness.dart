import 'dart:convert';
import 'dart:io';

const packageName = 'flutter_vless_android';
const expectedVersionFragment = 'flutter_vless_android-1.1.5';

Never fail(String message) {
  stderr.writeln('[runtime readiness patch] $message');
  exit(1);
}

Directory packageRoot() {
  final configFile = File('.dart_tool/package_config.json');
  if (!configFile.existsSync()) fail('run flutter pub get first');
  final decoded = jsonDecode(configFile.readAsStringSync());
  final packages = (decoded as Map<String, dynamic>)['packages'] as List;
  final item = packages.cast<Map>().firstWhere((p) => p['name'] == packageName);
  final rootUri = Uri.parse(item['rootUri'] as String);
  final resolved = rootUri.hasScheme
      ? rootUri
      : configFile.parent.absolute.uri.resolveUri(rootUri);
  final root = Directory.fromUri(resolved);
  final normalized = root.absolute.path.replaceAll('\\', '/');
  if (!normalized.contains(expectedVersionFragment)) {
    fail('expected flutter_vless_android 1.1.5, got ${root.path}');
  }
  return root;
}

void replaceOnce(File file, String oldValue, String newValue, String marker) {
  final text = file.readAsStringSync();
  if (text.contains(marker)) {
    stdout.writeln('[runtime readiness patch] already current: ${file.path}');
    return;
  }
  if (!text.contains(oldValue)) {
    fail('expected upstream block not found in ${file.path}: $marker');
  }
  file.writeAsStringSync(text.replaceFirst(oldValue, newValue));
  stdout.writeln('[runtime readiness patch] patched: ${file.path}');
}

void main() {
  final root = packageRoot();
  final kotlin = Directory('${root.path}/android/src/main/kotlin/com/github/tfox/flutter_vless');
  final service = File('${kotlin.path}/xray/service/XrayVPNService.kt');
  final core = File('${kotlin.path}/xray/core/XrayCoreManager.kt');
  final plugin = File('${kotlin.path}/FlutterVlessPlugin.kt');

  replaceOnce(
    core,
    '''            AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTED
            lastProxyUplink = 0L
            lastProxyDownlink = 0L
            startTimer(context)
            showNotification(context, config)
''',
    '''            // Xray being alive is not proof that the Android VPN datapath
            // exists. Stay CONNECTING until XrayVPNService confirms TUN + FD handoff.
            lastProxyUplink = 0L
            lastProxyDownlink = 0L
''',
    'Stay CONNECTING until XrayVPNService confirms TUN + FD handoff',
  );

  replaceOnce(
    core,
    '''    /**
     * Stops the Xray Core process and cleans up notifications.
     */
    fun stopCore(context: Service) {
''',
    '''    /** Mark the runtime connected only after the VPN service proves that
     * Builder.establish succeeded and the TUN FD reached tun2socks. */
    fun markTunnelReady(context: Service, config: XrayConfig) {
        if (xrayProcess?.isAlive != true) {
            throw IllegalStateException("Xray exited before tunnel readiness")
        }
        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTED
        startTimer(context)
        showNotification(context, config)
    }

    /**
     * Stops the Xray Core process and cleans up notifications.
     */
    fun stopCore(context: Service) {
''',
    'fun markTunnelReady(context: Service, config: XrayConfig)',
  );

  replaceOnce(
    core,
    '''                    if (AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED) {
                        // Unexpected exit
                        stopCore(context)
                    }
''',
    '''                    if (AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED ||
                        AppConfigs.V2RAY_STATE == AppConfigs.V2RAY_STATES.V2RAY_CONNECTING) {
                        // Let the owning VpnService perform one atomic cleanup path.
                        context.stopSelf()
                    }
''',
    'Let the owning VpnService perform one atomic cleanup path',
  );

  replaceOnce(
    service,
    '''            // Establish the VPN interface
            mInterface = builder.establish()
            isRunning = true
            
            // Start tun2socks to handle the traffic
            runTun2socks(config)
''',
    '''            // Establish the VPN interface. Android explicitly allows null
            // here when VPN preparation was revoked/raced; that must fail closed.
            val established = builder.establish()
                ?: throw IllegalStateException("VpnService.Builder.establish returned null")
            mInterface = established

            // The connection is not ready until tun2socks has accepted the TUN FD.
            if (!runTun2socks(config)) {
                throw IllegalStateException("tun2socks failed to accept the TUN file descriptor")
            }
            isRunning = true
            XrayCoreManager.markTunnelReady(this, config)
''',
    'VpnService.Builder.establish returned null',
  );

  replaceOnce(
    service,
    '''    private fun runTun2socks(config: XrayConfig) {
''',
    '''    private fun runTun2socks(config: XrayConfig): Boolean {
''',
    'private fun runTun2socks(config: XrayConfig): Boolean',
  );

  replaceOnce(
    service,
    '''            "-loglevel", "debug"
''',
    '''            "-loglevel", "warning"
''',
    '"-loglevel", "warning"',
  );

  replaceOnce(
    service,
    '''                    tun2socksProcess?.waitFor()
                    if (isRunning) {
                        // Restart if crashed and still supposed to be running
                        Log.e(TAG, "tun2socks exited unexpectedly, restarting...")
                        runTun2socks(config)
                    }
''',
    '''                    tun2socksProcess?.waitFor()
                    if (isRunning) {
                        // Fail closed. Dart/Extreme recovery may start a fresh generation.
                        Log.e(TAG, "tun2socks exited unexpectedly; stopping VPN")
                        stopAll()
                    }
''',
    'tun2socks exited unexpectedly; stopping VPN',
  );

  replaceOnce(
    service,
    '''            // Send the TUN file descriptor to tun2socks via socket
            sendFd()

        } catch (e: Exception) {
            Log.e(TAG, "Failed to start tun2socks", e)
            stopAll()
        }
    }
''',
    '''            // Send the TUN file descriptor to tun2socks via socket.
            if (!sendFd()) {
                Log.e(TAG, "Failed to hand TUN FD to tun2socks")
                tun2socksProcess?.destroy()
                tun2socksProcess = null
                return false
            }
            return true

        } catch (e: Exception) {
            Log.e(TAG, "Failed to start tun2socks", e)
            tun2socksProcess?.destroy()
            tun2socksProcess = null
            return false
        }
    }
''',
    'Failed to hand TUN FD to tun2socks',
  );

  replaceOnce(
    service,
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
    '''    private fun sendFd(): Boolean {
        val fd = mInterface?.fileDescriptor ?: return false
        val sockFile = File(filesDir, "sock_path").absolutePath
        repeat(10) { attempt ->
            try {
                Thread.sleep(250)
                val localSocket = LocalSocket()
                try {
                    localSocket.connect(LocalSocketAddress(sockFile, LocalSocketAddress.Namespace.FILESYSTEM))
                    localSocket.setFileDescriptorsForSend(arrayOf(fd))
                    localSocket.outputStream.write(32)
                    localSocket.outputStream.flush()
                    localSocket.setFileDescriptorsForSend(null)
                    localSocket.shutdownOutput()
                    return true
                } finally {
                    try { localSocket.close() } catch (_: Exception) {}
                }
            } catch (e: Exception) {
                Log.w(TAG, "TUN FD handoff attempt ${attempt + 1}/10 failed", e)
            }
        }
        return false
    }
''',
    'TUN FD handoff attempt ${attempt + 1}/10 failed',
  );

  replaceOnce(
    service,
    '''    override fun onDestroy() {
        stopAll()
        super.onDestroy()
    }
''',
    '''    override fun onRevoke() {
        Log.w(TAG, "VPN permission revoked; failing closed")
        stopAll()
        super.onRevoke()
    }

    override fun onDestroy() {
        cleanup()
        XrayCoreManager.stopCore(this)
        stopForeground(true)
        super.onDestroy()
    }
''',
    'VPN permission revoked; failing closed',
  );

  replaceOnce(
    service,
    '''        try {
            mInterface?.close()
            mInterface = null
        } catch (e: Exception) {}
    }
''',
    '''        try {
            mInterface?.close()
            mInterface = null
        } catch (e: Exception) {}
        try {
            val socketFile = File(filesDir, "sock_path")
            if (socketFile.exists()) socketFile.delete()
        } catch (_: Exception) {}
    }
''',
    'if (socketFile.exists()) socketFile.delete()',
  );

  replaceOnce(
    plugin,
    '''            activity?.registerReceiver(xrayReceiver, filter, Context.RECEIVER_EXPORTED)
''',
    '''            activity?.registerReceiver(xrayReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
''',
    'Context.RECEIVER_NOT_EXPORTED',
  );

  replaceOnce(
    plugin,
    '''    override fun onDetachedFromActivityForConfigChanges() {}
''',
    '''    override fun onDetachedFromActivityForConfigChanges() {
        unregisterReceiver()
        activity = null
    }
''',
    'onDetachedFromActivityForConfigChanges() {\n        unregisterReceiver()',
  );

  stdout.writeln('[runtime readiness patch] fail-closed VPN readiness hardening ready');
}
