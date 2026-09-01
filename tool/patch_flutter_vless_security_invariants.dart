import 'dart:convert';
import 'dart:io';

const packageName = 'flutter_vless_android';
const expectedVersionFragment = 'flutter_vless_android-1.1.5';

Never fail(String message) {
  stderr.writeln('[security invariants] $message');
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

String replaceOnce(String text, String oldValue, String newValue, String label) {
  if (text.contains(newValue)) return text;
  if (!text.contains(oldValue)) fail('missing expected source block: $label');
  return text.replaceFirst(oldValue, newValue);
}

void writeIfChanged(File file, String before, String after) {
  if (before == after) {
    stdout.writeln('[security invariants] already current: ${file.path}');
    return;
  }
  file.writeAsStringSync(after);
  stdout.writeln('[security invariants] patched: ${file.path}');
}

void patchManifest(File file) {
  final before = file.readAsStringSync();
  var text = before;
  text = replaceOnce(
    text,
    '                android:value="true" />\n        </service>',
    '                android:value="false" />\n        </service>',
    'disable unsupported Always-on VPN',
  );
  writeIfChanged(file, before, text);
}

void patchPlugin(File file) {
  final before = file.readAsStringSync();
  var text = before;

  if (!text.contains('import androidx.core.content.ContextCompat')) {
    text = replaceOnce(
      text,
      'import androidx.core.app.ActivityCompat\n',
      'import androidx.core.app.ActivityCompat\nimport androidx.core.content.ContextCompat\n',
      'ContextCompat import',
    );
  }

  const oldReceiver = r'''        val filter = IntentFilter(AppConfigs.V2RAY_CONNECTION_INFO)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity?.registerReceiver(xrayReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            activity?.registerReceiver(xrayReceiver, filter)
        }
''';
  const privateReceiver = r'''        val filter = IntentFilter(AppConfigs.V2RAY_CONNECTION_INFO)
        val currentActivity = activity ?: return
        ContextCompat.registerReceiver(
            currentActivity,
            xrayReceiver,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
''';
  text = replaceOnce(
    text,
    oldReceiver,
    privateReceiver,
    'private in-app status receiver',
  );

  text = replaceOnce(
    text,
    '    override fun onDetachedFromActivityForConfigChanges() {}\n',
    '''    override fun onDetachedFromActivityForConfigChanges() {
        unregisterReceiver()
        activity = null
    }
''',
    'config-change receiver cleanup',
  );

  if (!text.contains('        unregisterReceiver()\n        vpnControlMethod.setMethodCallHandler(null)')) {
    text = replaceOnce(
      text,
      '    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {\n        vpnControlMethod.setMethodCallHandler(null)\n',
      '    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {\n        unregisterReceiver()\n        vpnControlMethod.setMethodCallHandler(null)\n',
      'engine detach receiver cleanup',
    );
  }

  writeIfChanged(file, before, text);
}

void patchCore(File file) {
  final before = file.readAsStringSync();
  var text = before;

  // Preserve the scope correction required by the secure-SOCKS patch.
  const directCapture =
      '            val process = pb.start()\n            xrayProcess = process\n';
  const scopedCapture =
      '            val process = xrayProcess ?: return false\n            // Monitor process in a separate thread to detect crash\n';
  const monitorMarker =
      '            // Monitor process in a separate thread to detect crash\n';
  if (!text.contains(directCapture) && !text.contains(scopedCapture)) {
    if (!text.contains('process.inputStream.bufferedReader().use { reader ->') ||
        !text.contains('val exitCode = process.waitFor()') ||
        !text.contains('xrayProcess === process') ||
        !text.contains(monitorMarker)) {
      fail('secure Xray monitor patch is not in the expected state');
    }
    text = text.replaceFirst(monitorMarker, scopedCapture);
  }

  // ReVolt does not use Xray's local Stats API. Do not expose an unauthenticated
  // localhost control surface or spawn a native statsquery process every second.
  const runtimeSurfaceStart =
      '        // Android needs local control surfaces that may not exist in imported\n';
  const inboundStart =
      '        val inbounds = configJson.optJSONArray("inbounds") ?: JSONArray()\n';
  final surfaceIndex = text.indexOf(runtimeSurfaceStart);
  if (surfaceIndex >= 0) {
    final inboundIndex = text.indexOf(inboundStart, surfaceIndex);
    if (inboundIndex < 0) fail('runtime inbound anchor missing');
    text = text.replaceRange(
      surfaceIndex,
      inboundIndex,
      '        // ReVolt needs only its authenticated local SOCKS ingress.\n',
    );
  }

  const apiInboundStart =
      '        if (usedPorts.contains(config.LOCAL_API_PORT)) {\n';
  const returnConfig = '        return configJson\n';
  final apiIndex = text.indexOf(apiInboundStart);
  if (apiIndex >= 0) {
    final returnIndex = text.indexOf(returnConfig, apiIndex);
    if (returnIndex < 0) fail('runtime config return anchor missing');
    text = text.replaceRange(apiIndex, returnIndex, '');
  }

  const trafficBlock = r'''                val traffic = getV2rayTraffic(context)
                intent.putExtra("UPLOAD_SPEED", traffic[0])
                intent.putExtra("DOWNLOAD_SPEED", traffic[1])
                intent.putExtra("UPLOAD_TRAFFIC", traffic[2])
                intent.putExtra("DOWNLOAD_TRAFFIC", traffic[3])
''';
  const cheapHeartbeat = r'''                intent.putExtra("UPLOAD_SPEED", 0L)
                intent.putExtra("DOWNLOAD_SPEED", 0L)
                intent.putExtra("UPLOAD_TRAFFIC", 0L)
                intent.putExtra("DOWNLOAD_TRAFFIC", 0L)
''';
  text = replaceOnce(
    text,
    trafficBlock,
    cheapHeartbeat,
    'remove per-second native stats query',
  );

  // With the polling call gone, remove the dead native stats helper and state.
  text = text.replaceAll(
    '    private var lastProxyUplink = 0L\n    private var lastProxyDownlink = 0L\n',
    '',
  );
  text = text.replaceAll(
    '            lastProxyUplink = 0L\n            lastProxyDownlink = 0L\n',
    '',
  );
  text = text.replaceAll(
    '        lastProxyUplink = 0L\n        lastProxyDownlink = 0L\n',
    '',
  );

  const trafficHelperStart = r'''    /**
     * Queries Xray's stats API for traffic sent through the application proxy.
''';
  const stopTimerStart = '    private fun stopTimer() {\n';
  final trafficHelperIndex = text.indexOf(trafficHelperStart);
  if (trafficHelperIndex >= 0) {
    final stopTimerIndex = text.indexOf(stopTimerStart, trafficHelperIndex);
    if (stopTimerIndex < 0) fail('stats helper end anchor missing');
    text = text.replaceRange(trafficHelperIndex, stopTimerIndex, '');
  }

  const broadcastCtor =
      'val intent = Intent(AppConfigs.V2RAY_CONNECTION_INFO)';
  if (text.contains(broadcastCtor) &&
      !text.contains(
        'val intent = Intent(AppConfigs.V2RAY_CONNECTION_INFO).setPackage(context.packageName)',
      )) {
    text = text.replaceAll(
      broadcastCtor,
      '$broadcastCtor.setPackage(context.packageName)',
    );
  }

  const oldSanitizer = r'''    private fun sanitizeLogPaths(configJson: JSONObject, filesDir: File) {
        val log = configJson.optJSONObject("log") ?: return
        val accessPath = log.optString("access")
        val errorPath = log.optString("error")

        if (accessPath.isNotEmpty()) {
            log.put("access", File(filesDir, "access.log").absolutePath)
        }
        if (errorPath.isNotEmpty()) {
            log.put("error", File(filesDir, "error.log").absolutePath)
        }
    }
''';
  const privateLogs = r'''    private fun sanitizeLogPaths(configJson: JSONObject, filesDir: File) {
        val log = configJson.optJSONObject("log") ?: return

        // The VPN client never needs destination/access logs. A server-provided
        // config must not silently enable browsing metadata collection locally.
        log.remove("access")
        try { File(filesDir, "access.log").delete() } catch (_: Exception) {}

        val errorPath = log.optString("error")
        if (errorPath.isNotEmpty()) {
            log.put("error", File(filesDir, "error.log").absolutePath)
        }
    }
''';
  text = replaceOnce(text, oldSanitizer, privateLogs, 'disable access logging');

  // A notification channel keeps its original importance once created. ReVolt
  // owns a single quiet foreground channel, so the core must create it LOW too.
  text = replaceOnce(
    text,
    '            val channel = NotificationChannel(channelId, channelName, NotificationManager.IMPORTANCE_DEFAULT)\n',
    '            val channel = NotificationChannel(channelId, channelName, NotificationManager.IMPORTANCE_LOW)\n',
    'quiet Xray notification channel',
  );

  // No code handles this action; the launcher PendingIntent only needs its flags.
  text = text.replaceAll(
    '        launchIntent?.action = "FROM_DISCONNECT_BTN"\n',
    '',
  );

  writeIfChanged(file, before, text);
}

void patchService(File file) {
  final before = file.readAsStringSync();
  var text = before;

  const oldForegroundFailure = r'''        } catch (e: Exception) {
            Log.e(TAG, "Failed to start foreground", e)
        }

        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE) {
''';
  const closedForegroundFailure = r'''        } catch (e: Exception) {
            Log.e(TAG, "Failed to start foreground", e)
            stopSelf()
            return START_NOT_STICKY
        }

        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE) {
''';
  text = replaceOnce(
    text,
    oldForegroundFailure,
    closedForegroundFailure,
    'foreground-service fail closed',
  );

  text = replaceOnce(
    text,
    '            builder.addAddress("26.26.26.1", 30)\n',
    '            builder.addAddress("26.26.26.1", 30)\n'
        '            builder.addAddress("fd00:26:26::1", 126)\n',
    'IPv6 TUN address',
  );

  // ReVolt is full-tunnel only. The app UID itself must stay outside the TUN so
  // Xray can reach the remote server, but no arbitrary app may bypass it.
  const stockAppPolicy = r'''          try {
    builder.addDisallowedApplication(packageName)
} catch (e: Exception) {
    Log.e(TAG, "Failed to exclude app from VPN", e)
}

for (pkg in config.BLOCKED_APPS) {
    try {
        builder.addDisallowedApplication(pkg)
        Log.d(TAG, "Excluded from VPN: $pkg")
    } catch (e: Exception) {
        Log.e(TAG, "Failed to exclude $pkg from VPN", e)
    }
}
''';
  const fullTunnelAppPolicy = r'''            if (config.BLOCKED_APPS.isNotEmpty()) {
                throw IllegalStateException("Per-app VPN bypass is disabled in ReVolt")
            }
            try {
                builder.addDisallowedApplication(packageName)
            } catch (e: Exception) {
                throw IllegalStateException("Failed to exclude ReVolt from its own VPN", e)
            }
''';
  text = replaceOnce(
    text,
    stockAppPolicy,
    fullTunnelAppPolicy,
    'full-tunnel app policy',
  );

  const routeStart =
      '            // Add routes to exclude the server IP (to prevent routing loop)\n';
  const dnsStart = '\n            // Add DNS servers\n';
  final routeIndex = text.indexOf(routeStart);
  if (routeIndex >= 0) {
    final dnsIndex = text.indexOf(dnsStart, routeIndex);
    if (dnsIndex < 0) fail('DNS route anchor missing');
    text = text.replaceRange(
      routeIndex,
      dnsIndex,
      '            // Full-tunnel routing. ReVolt itself is already outside the VPN.\n'
          '            builder.addRoute("0.0.0.0", 0)\n'
          '            builder.addRoute("::", 0)\n',
    );
  }

  text = replaceOnce(
    text,
    '            mInterface = builder.establish()\n            isRunning = true\n',
    '            mInterface = builder.establish()\n'
        '                ?: throw IllegalStateException("Android refused to establish VPN interface")\n'
        '            isRunning = true\n',
    'VPN establish fail closed',
  );

  const helperStart = r'''    /**
     * Calculates routes to exclude a specific IP address from the VPN.
''';
  const channelStart = '    private fun createNotificationChannel() {\n';
  final helperIndex = text.indexOf(helperStart);
  if (helperIndex >= 0) {
    final channelIndex = text.indexOf(channelStart, helperIndex);
    if (channelIndex < 0) fail('notification channel anchor missing');
    text = text.replaceRange(helperIndex, channelIndex, '');
  }

  // The service and core used two channel IDs. Keep one LOW channel so Android
  // does not preserve a louder DEFAULT channel created by the core first.
  text = text.replaceAll('"vpn_service_channel"', '"XRAY_SERVICE_CHANNEL"');

  if (!text.contains('override fun onRevoke()')) {
    const destroyBlock = r'''    override fun onDestroy() {
        stopAll()
        super.onDestroy()
    }

''';
    const revokeBlock = r'''    override fun onDestroy() {
        stopAll()
        super.onDestroy()
    }

    override fun onRevoke() {
        stopAll()
        super.onRevoke()
    }

''';
    text = replaceOnce(text, destroyBlock, revokeBlock, 'VPN revoke cleanup');
  }

  // Keep the active foreground notification attached to the service.
  if (!text.contains('Notification.FLAG_NO_CLEAR')) {
    const oldBlock = r'''        return builder
            .setContentTitle("VPN Service")
            .setContentText(content)
            .setSmallIcon(icon)
            .build()
''';
    const newBlock = r'''        val notification = builder
            .setContentTitle("VPN Service")
            .setContentText(content)
            .setSmallIcon(icon)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .build()

        notification.flags = notification.flags or
            android.app.Notification.FLAG_ONGOING_EVENT or
            android.app.Notification.FLAG_NO_CLEAR
        return notification
''';
    text = replaceOnce(text, oldBlock, newBlock, 'ongoing VPN notification');
  }

  writeIfChanged(file, before, text);
}

void main() {
  final root = packageRoot();
  final androidRoot = '${root.path}/android/src/main';
  final kotlin = '$androidRoot/kotlin/com/github/tfox/flutter_vless';

  final manifest = File('$androidRoot/AndroidManifest.xml');
  final plugin = File('$kotlin/FlutterVlessPlugin.kt');
  final core = File('$kotlin/xray/core/XrayCoreManager.kt');
  final service = File('$kotlin/xray/service/XrayVPNService.kt');

  for (final file in [manifest, plugin, core, service]) {
    if (!file.existsSync()) fail('missing upstream source: ${file.path}');
  }

  patchManifest(manifest);
  patchPlugin(plugin);
  patchCore(core);
  patchService(service);
  stdout.writeln('[security invariants] ReVolt Android invariants are ready');
}
