import 'dart:convert';
import 'dart:io';

const packageName = 'flutter_vless_android';
const expectedVersionFragment = 'flutter_vless_android-1.1.5';

Never fail(String message) {
  stderr.writeln('[runtime followup patch] $message');
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

void patchPlugin(File plugin) {
  final before = plugin.readAsStringSync();
  var text = before;

  // Context.RECEIVER_NOT_EXPORTED exists only on newer Android. ContextCompat
  // provides the same non-exported guarantee on legacy releases, where the old
  // registerReceiver(receiver, filter) path otherwise accepts spoofed status
  // broadcasts from unrelated apps.
  const oldReceiver = r'''        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity?.registerReceiver(xrayReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            activity?.registerReceiver(xrayReceiver, filter)
        }
''';
  const hardenedReceiver = r'''        activity?.let { currentActivity ->
            androidx.core.content.ContextCompat.registerReceiver(
                currentActivity,
                xrayReceiver,
                filter,
                androidx.core.content.ContextCompat.RECEIVER_NOT_EXPORTED,
            )
        }
''';
  text = replaceOnce(
    text,
    oldReceiver,
    hardenedReceiver,
    'non-exported status receiver on all supported Android versions',
  );

  if (before != text) {
    plugin.writeAsStringSync(text);
    stdout.writeln('[runtime followup patch] legacy status receiver hardened');
  }
}

void patchService(File service) {
  final before = service.readAsStringSync();
  var text = before;

  text = replaceOnce(
    text,
    r'''        } catch (e: Exception) {
            Log.e(TAG, "Failed to start foreground", e)
        }

        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE) {
''',
    r'''        } catch (e: Exception) {
            // Without a foreground service Android is free to terminate the
            // runtime immediately. Continuing here can expose a false CONNECTED
            // state, so startup fails closed instead.
            Log.e(TAG, "Failed to start foreground; refusing VPN startup", e)
            stopSelf()
            return START_NOT_STICKY
        }

        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE) {
''',
    'fail closed after foreground-service startup failure',
  );

  // The VPN app UID is already excluded with addDisallowedApplication(packageName),
  // which is what lets Xray reach the server without routing into its own TUN.
  // Leaving the server IP out of the global route therefore only gives every
  // other app a direct-network bypass to that address.
  const oldServerRoute = r'''            // Add routes to exclude the server IP (to prevent routing loop)
            val serverIp = config.CONNECTED_V2RAY_SERVER_ADDRESS
            if (serverIp.isIpv4Literal()) {
                try {
                    Log.d(TAG, "Excluding server IP: $serverIp")
                    val excludedRoutes = excludeIp(serverIp)
                    for (route in excludedRoutes) {
                        val parts = route.split("/")
                        builder.addRoute(parts[0], parts[1].toInt())
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to exclude server IP, falling back to 0.0.0.0/0", e)
                    builder.addRoute("0.0.0.0", 0)
                }
            } else {
                builder.addRoute("0.0.0.0", 0)
            }
''';
  const fullRoute = r'''            // Route every IPv4 destination into the TUN. The ReVolt UID itself
            // is excluded above, so the Xray outbound still reaches the server
            // directly without exposing a server-IP bypass to other apps.
            builder.addRoute("0.0.0.0", 0)
''';
  text = replaceOnce(text, oldServerRoute, fullRoute, 'remove global server-IP bypass');

  text = replaceOnce(
    text,
    r'''            // Establish the VPN interface
            mInterface = builder.establish()
            isRunning = true
''',
    r'''            // Establish must return a live descriptor. A null interface is a
            // fatal TUN start, not a state that recovery can fix by respawning
            // tun2socks forever.
            val established = builder.establish()
                ?: throw IllegalStateException("Android VPN interface was not established")
            mInterface = established
            isRunning = true
''',
    'fail closed when Builder.establish returns null',
  );

  text = replaceOnce(
    text,
    r'''                val xrayAlive = XrayCoreManager.isXrayProcessAlive()
                val tunAlive = proxyOnly || tun2socksProcess?.isAlive == true
                val fdReady = proxyOnly || tunFdReady
                val outboundReady = xrayAlive && probeSecureSocks(config)
                val healthy = xrayAlive && tunAlive && fdReady && outboundReady
''',
    r'''                val xrayAlive = XrayCoreManager.isXrayProcessAlive()
                val tunInterfaceAlive = proxyOnly ||
                    (mInterface?.fileDescriptor?.valid() == true)
                val tunAlive = proxyOnly || tun2socksProcess?.isAlive == true
                val fdReady = proxyOnly || (tunFdReady && tunInterfaceAlive)
                val outboundReady = xrayAlive && probeSecureSocks(config)
                val healthy = xrayAlive && tunInterfaceAlive && tunAlive &&
                    fdReady && outboundReady
''',
    'include actual TUN descriptor in runtime health',
  );

  text = replaceOnce(
    text,
    r'''                    if (XrayCoreManager.startCore(this, config)) {
                        Log.w(TAG, "Xray core process restarted; awaiting end-to-end health")
                        return@Thread
                    }
''',
    r'''                    if (XrayCoreManager.startCore(this, config)) {
                        // startCore marks the child CONNECTED after process startup.
                        // Keep UI/state in recovery until the independent SOCKS/TUN
                        // health monitor proves packets can actually flow again.
                        AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING
                        Log.w(TAG, "Xray core process restarted; awaiting end-to-end health")
                        return@Thread
                    }
''',
    'keep recovered Xray gated on end-to-end health',
  );

  if (!text.contains('override fun onRevoke()')) {
    const marker = r'''    override fun onDestroy() {
        stopAll()
        super.onDestroy()
    }
''';
    const replacement = r'''    override fun onRevoke() {
        // Android revokes this VpnService when another VPN takes ownership or
        // the user revokes permission. Do not leave Xray/notification state
        // behind pretending ReVolt still owns a TUN.
        Log.w(TAG, "VPN permission/interface revoked by Android")
        stopAll()
        super.onRevoke()
    }

    override fun onDestroy() {
        stopAll()
        super.onDestroy()
    }
''';
    text = replaceOnce(text, marker, replacement, 'stop cleanly on VpnService revoke');
  }

  if (before != text) {
    service.writeAsStringSync(text);
    stdout.writeln('[runtime followup patch] TUN revoke and route hardening ready');
  }
}

void main() {
  final root = packageRoot();
  final kotlin =
      '${root.path}/android/src/main/kotlin/com/github/tfox/flutter_vless';
  final plugin = File('$kotlin/FlutterVlessPlugin.kt');
  final service = File('$kotlin/xray/service/XrayVPNService.kt');
  if (!plugin.existsSync()) fail('FlutterVlessPlugin.kt is missing');
  if (!service.existsSync()) fail('XrayVPNService.kt is missing');

  patchPlugin(plugin);
  patchService(service);
  stdout.writeln('[runtime followup patch] runtime followup hardening ready');
}
