import 'dart:convert';
import 'dart:io';

Never fail(String message) {
  stderr.writeln('[stop ack patch] $message');
  exit(1);
}

Directory packageRoot() {
  final configFile = File('.dart_tool/package_config.json');
  final decoded = jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
  final packages = decoded['packages'] as List;
  final item = packages.cast<Map>().firstWhere((p) => p['name'] == 'flutter_vless_android');
  final uri = Uri.parse(item['rootUri'] as String);
  final resolved = uri.hasScheme ? uri : configFile.parent.absolute.uri.resolveUri(uri);
  final root = Directory.fromUri(resolved);
  if (!root.absolute.path.replaceAll('\\', '/').contains('flutter_vless_android-1.1.5')) {
    fail('unexpected flutter_vless_android version');
  }
  return root;
}

void replaceOnce(File file, String oldValue, String newValue, String marker) {
  final text = file.readAsStringSync();
  if (text.contains(marker)) return;
  if (!text.contains(oldValue)) fail('expected block missing: $marker');
  file.writeAsStringSync(text.replaceFirst(oldValue, newValue));
}

void main() {
  final plugin = File('${packageRoot().path}/android/src/main/kotlin/com/github/tfox/flutter_vless/FlutterVlessPlugin.kt');

  replaceOnce(
    plugin,
    '''import android.os.Build
''',
    '''import android.os.Build
import android.os.Handler
import android.os.Looper
''',
    'import android.os.Handler',
  );

  replaceOnce(
    plugin,
    '''    private var localSocksPassword = ""

    private fun randomToken(size: Int = 24): String {
''',
    '''    private var localSocksPassword = ""
    private var pendingStopResult: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val stopTimeoutRunnable = Runnable {
        pendingStopResult?.error("STOP_TIMEOUT", "VPN service did not confirm shutdown", null)
        pendingStopResult = null
    }

    private fun randomToken(size: Int = 24): String {
''',
    'private val stopTimeoutRunnable = Runnable',
  );

  replaceOnce(
    plugin,
    '''                config.LOCAL_SOCKS_PASSWORD = localSocksPassword
                config.BLOCKED_APPS = call.argument<ArrayList<String>>("blocked_apps") ?: ArrayList()
''',
    '''                config.LOCAL_SOCKS_PASSWORD = localSocksPassword
                config.LOCAL_API_PORT = 40000 + secureRandom.nextInt(10000)
                config.BLOCKED_APPS = call.argument<ArrayList<String>>("blocked_apps") ?: ArrayList()
''',
    'config.LOCAL_API_PORT = 40000 + secureRandom.nextInt(10000)',
  );

  replaceOnce(
    plugin,
    '''            "stopVless" -> {
                tunnelReadySeen = false
                val intent = Intent(context, XrayVPNService::class.java)
                intent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)
                context.startService(intent)
                result.success(null)
            }
''',
    '''            "stopVless" -> {
                tunnelReadySeen = false
                if (pendingStopResult != null) {
                    result.error("STOP_IN_PROGRESS", "VPN shutdown is already in progress", null)
                    return
                }
                pendingStopResult = result
                mainHandler.removeCallbacks(stopTimeoutRunnable)
                mainHandler.postDelayed(stopTimeoutRunnable, 5000)
                try {
                    val intent = Intent(context, XrayVPNService::class.java)
                    intent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)
                    context.startService(intent)
                } catch (e: Exception) {
                    mainHandler.removeCallbacks(stopTimeoutRunnable)
                    pendingStopResult = null
                    result.error("STOP_FAILED", e.message, null)
                }
            }
''',
    '"STOP_IN_PROGRESS"',
  );

  replaceOnce(
    plugin,
    '''                    tunnelReadySeen = state == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED
                    val duration = intent.getStringExtra("DURATION")
''',
    '''                    tunnelReadySeen = state == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED
                    if (state == AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED && pendingStopResult != null) {
                        mainHandler.removeCallbacks(stopTimeoutRunnable)
                        pendingStopResult?.success(null)
                        pendingStopResult = null
                    }
                    val duration = intent.getStringExtra("DURATION")
''',
    'pendingStopResult?.success(null)',
  );

  stdout.writeln('[stop ack patch] verified shutdown acknowledgment ready');
}
