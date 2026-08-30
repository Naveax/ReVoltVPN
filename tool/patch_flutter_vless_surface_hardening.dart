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
  final config = File('${kotlin.path}/xray/dto/XrayConfig.kt');
  final service = File('${kotlin.path}/xray/service/XrayVPNService.kt');

  replaceOnce(
    config,
    '''    /** Local port for SOCKS5 proxy (default: 10807). used by tun2socks. */
    var LOCAL_SOCKS5_PORT: Int = 10807,
    
    /** Local port for HTTP proxy (default: 10808). */
''',
    '''    /** Session-local port for SOCKS5 proxy used by tun2socks. */
    var LOCAL_SOCKS5_PORT: Int = 10807,
    var LOCAL_SOCKS_USERNAME: String = "",
    var LOCAL_SOCKS_PASSWORD: String = "",
    
    /** Local port for HTTP proxy (unused by ReVolt). */
''',
    'var LOCAL_SOCKS_USERNAME:',
  );

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

  replaceOnce(
    core,
    '''            socksInbound.put("settings", JSONObject().put("auth", "noauth").put("udp", true))
''',
    '''            if (config.LOCAL_SOCKS_USERNAME.isEmpty() || config.LOCAL_SOCKS_PASSWORD.isEmpty()) {
                throw IllegalStateException("Missing session SOCKS credentials")
            }
            val socksAccount = JSONObject()
                .put("user", config.LOCAL_SOCKS_USERNAME)
                .put("pass", config.LOCAL_SOCKS_PASSWORD)
            socksInbound.put(
                "settings",
                JSONObject()
                    .put("auth", "password")
                    .put("accounts", JSONArray().put(socksAccount))
                    .put("udp", true)
            )
''',
    'Missing session SOCKS credentials',
  );

  removeBetween(
    core,
    '        if (!hasHttpOnLocalPort) {\n',
    '        if (usedPorts.contains(config.LOCAL_API_PORT)) {\n',
    'ReVolt does not expose an HTTP proxy inbound.',
  );

  replaceOnce(
    service,
    r'''            "-proxy", "socks5://127.0.0.1:${config.LOCAL_SOCKS5_PORT}",
''',
    r'''            "-proxy", "socks5://${config.LOCAL_SOCKS_USERNAME}:${config.LOCAL_SOCKS_PASSWORD}@127.0.0.1:${config.LOCAL_SOCKS5_PORT}",
''',
    'LOCAL_SOCKS_USERNAME}:${config.LOCAL_SOCKS_PASSWORD}@127.0.0.1',
  );

  replaceOnce(
    plugin,
    '''import java.util.ArrayList
import java.util.concurrent.Executors
''',
    '''import java.util.ArrayList
import java.util.concurrent.Executors
import java.security.SecureRandom
''',
    'import java.security.SecureRandom',
  );

  replaceOnce(
    plugin,
    '''    private lateinit var context: Context
    private var allowedApps: ArrayList<String> = ArrayList()
''',
    '''    private lateinit var context: Context
    private var allowedApps: ArrayList<String> = ArrayList()
    private var tunnelReadySeen = false
    private val secureRandom = SecureRandom()
    private var localSocksPort = 10807
    private var localSocksUser = ""
    private var localSocksPassword = ""

    private fun randomToken(size: Int = 24): String {
        val data = ByteArray(size)
        secureRandom.nextBytes(data)
        return data.joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun randomSocksPort(): Int = 20000 + secureRandom.nextInt(20000)
''',
    'private fun randomSocksPort(): Int',
  );

  replaceOnce(
    plugin,
    '''        when (call.method) {
            "setAllowedApps" -> {
''',
    '''        when (call.method) {
            "getLocalProxyInfo" -> {
                result.success(mapOf(
                    "host" to "127.0.0.1",
                    "port" to localSocksPort,
                    "username" to localSocksUser,
                    "password" to localSocksPassword
                ))
            }
            "setAllowedApps" -> {
''',
    '"getLocalProxyInfo" -> {',
  );

  replaceOnce(
    plugin,
    '''                config.V2RAY_FULL_JSON_CONFIG = call.argument("config") ?: ""
                config.BLOCKED_APPS = call.argument<ArrayList<String>>("blocked_apps") ?: ArrayList()
''',
    '''                config.V2RAY_FULL_JSON_CONFIG = call.argument("config") ?: ""
                localSocksPort = randomSocksPort()
                localSocksUser = randomToken()
                localSocksPassword = randomToken()
                config.LOCAL_SOCKS5_PORT = localSocksPort
                config.LOCAL_SOCKS_USERNAME = localSocksUser
                config.LOCAL_SOCKS_PASSWORD = localSocksPassword
                config.BLOCKED_APPS = call.argument<ArrayList<String>>("blocked_apps") ?: ArrayList()
''',
    'config.LOCAL_SOCKS_USERNAME = localSocksUser',
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
    '''"stopVless" -> {
                tunnelReadySeen = false''',
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

  stdout.writeln('[surface hardening patch] authenticated local SOCKS/startup hardening ready');
}
