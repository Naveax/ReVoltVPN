import 'dart:convert';
import 'dart:io';

const packageName = 'flutter_vless_android';
const expectedVersionFragment = 'flutter_vless_android-1.1.5';

Never fail(String message) {
  stderr.writeln('[surface hardening patch] $message');
  exit(1);
}

Directory packageRoot() {
  final configFile = File('.dart_tool/package_config.json');
  if (!configFile.existsSync()) fail('run flutter pub get first');
  final decoded = jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
  final packages = decoded['packages'] as List;
  final item = packages.cast<Map>().firstWhere((p) => p['name'] == packageName);
  final uri = Uri.parse(item['rootUri'] as String);
  final resolved = uri.hasScheme ? uri : configFile.parent.absolute.uri.resolveUri(uri);
  final root = Directory.fromUri(resolved);
  if (!root.absolute.path.replaceAll('\\', '/').contains(expectedVersionFragment)) {
    fail('expected flutter_vless_android 1.1.5, got ${root.path}');
  }
  return root;
}

void replaceOnce(File file, String oldValue, String newValue, String marker) {
  final text = file.readAsStringSync();
  if (text.contains(marker)) return;
  if (!text.contains(oldValue)) fail('expected block missing in ${file.path}: $marker');
  file.writeAsStringSync(text.replaceFirst(oldValue, newValue));
}

void removeBetween(File file, String start, String end, String marker) {
  var text = file.readAsStringSync();
  if (text.contains(marker)) return;
  final s = text.indexOf(start);
  final e = text.indexOf(end, s < 0 ? 0 : s);
  if (s < 0 || e < 0 || e <= s) fail('removal block missing in ${file.path}');
  text = text.replaceRange(s, e, '        // ReVolt does not expose an HTTP proxy inbound.\n');
  file.writeAsStringSync(text);
}

void main() {
  final root = packageRoot();
  final kotlin = Directory('${root.path}/android/src/main/kotlin/com/github/tfox/flutter_vless');
  final core = File('${kotlin.path}/xray/core/XrayCoreManager.kt');
  final plugin = File('${kotlin.path}/FlutterVlessPlugin.kt');

  replaceOnce(
    core,
    '''            if (usedPorts.contains(config.LOCAL_SOCKS5_PORT)) {
                config.LOCAL_SOCKS5_PORT = nextFreePort(config.LOCAL_SOCKS5_PORT, usedPorts)
            }
''',
    '''            if (usedPorts.contains(config.LOCAL_SOCKS5_PORT)) {
                throw IllegalStateException("Local SOCKS5 port collision on ${config.LOCAL_SOCKS5_PORT}")
            }
''',
    'Local SOCKS5 port collision on',
  );

  removeBetween(
    core,
    '        if (!hasHttpOnLocalPort) {\n',
    '        if (usedPorts.contains(config.LOCAL_API_PORT)) {\n',
    'ReVolt does not expose an HTTP proxy inbound.',
  );

  replaceOnce(
    plugin,
    '''    private lateinit var context: Context
    private var allowedApps: ArrayList<String> = ArrayList()
''',
    '''    private lateinit var context: Context
    private var allowedApps: ArrayList<String> = ArrayList()
    private var tunnelReadySeen = false
''',
    'private var tunnelReadySeen = false',
  );

  replaceOnce(
    plugin,
    '''            "stopVless" -> {
                val intent = Intent(context, XrayVPNService::class.java)
''',
    '''            "stopVless" -> {
                tunnelReadySeen = false
                val intent = Intent(context, XrayVPNService::class.java)
''',
    '"stopVless" -> {\n                tunnelReadySeen = false',
  );

  replaceOnce(
    plugin,
    '''            "getConnectedServerDelay" -> {
                // Measures delay through the CURRENTLY active connection
''',
    '''            "getConnectedServerDelay" -> {
                // Never use an Xray-only probe to restore a secure UI state.
                // This app process must first observe a post-TUN CONNECTED broadcast.
                if (!tunnelReadySeen) {
                    result.success(-1)
                    return
                }
                // Measures delay through the CURRENTLY active connection
''',
    'This app process must first observe a post-TUN CONNECTED broadcast.',
  );

  replaceOnce(
    plugin,
    '''                    val state = intent.getSerializableExtra("STATE") as? AppConfigs.V2RAY_STATES
                    val duration = intent.getStringExtra("DURATION")
''',
    '''                    val state = intent.getSerializableExtra("STATE") as? AppConfigs.V2RAY_STATES
                    tunnelReadySeen = state == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED
                    val duration = intent.getStringExtra("DURATION")
''',
    'tunnelReadySeen = state == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED',
  );

  stdout.writeln('[surface hardening patch] local surface/startup hardening ready');
}
