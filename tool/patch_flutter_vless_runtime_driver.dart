import 'dart:convert';
import 'dart:io';

const packageName = 'flutter_vless_android';
const expectedVersionFragment = 'flutter_vless_android-1.1.5';

Never fail(String message) {
  stderr.writeln('[runtime patch driver] $message');
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

bool containsAll(File file, Iterable<String> markers) {
  if (!file.existsSync()) return false;
  final text = file.readAsStringSync();
  return markers.every(text.contains);
}

void runPatch(String path) {
  final script = File(path);
  if (!script.existsSync()) fail('patch script is missing: $path');

  stdout.writeln('[runtime patch driver] running $path');
  final result = Process.runSync(
    Platform.resolvedExecutable,
    <String>['run', script.absolute.path],
    workingDirectory: Directory.current.path,
  );
  if (result.stdout.toString().isNotEmpty) stdout.write(result.stdout);
  if (result.stderr.toString().isNotEmpty) stderr.write(result.stderr);
  if (result.exitCode != 0) {
    fail('$path exited with code ${result.exitCode}');
  }
}

void ensureRuntimeAnchorCompatibility(File service) {
  var text = service.readAsStringSync();
  const functionStart = '    private fun runTun2socks(config: XrayConfig) {\n';
  const fdReset = '        tunFdReady = false\n';
  const securePrelude = '''        val secure = secureSocksCredentials(config)
            ?: throw IllegalStateException("Authenticated ReVolt SOCKS5 inbound missing")
        config.LOCAL_SOCKS5_PORT = secure.port

''';

  if (!text.contains(functionStart)) {
    fail('tun2socks function is missing from pinned runtime');
  }

  final oldExpected = functionStart + securePrelude;
  final finalExpected = functionStart + fdReset + securePrelude;
  if (text.contains(oldExpected) || text.contains(finalExpected)) return;

  if (!text.contains(securePrelude)) {
    fail('secure SOCKS credential prelude is missing from pinned runtime');
  }

  // The secure-SOCKS patch historically inserted its credential lookup next to
  // command construction, while the reliability patch deliberately anchors it
  // at function entry. Normalize that intermediate shape once. This preserves
  // behavior while making cold, resumed and warm-cache builds deterministic.
  text = text.replaceFirst(securePrelude, '');
  final currentStart = text.contains(functionStart + fdReset)
      ? functionStart + fdReset
      : functionStart;
  text = text.replaceFirst(currentStart, currentStart + securePrelude);
  service.writeAsStringSync(text);
  stdout.writeln(
    '[runtime patch driver] normalized secure SOCKS reliability anchor',
  );
}

void main() {
  final root = packageRoot();
  final android = Directory('${root.path}/android');
  final kotlin = Directory(
    '${android.path}/src/main/kotlin/com/github/tfox/flutter_vless',
  );
  final manifest = File('${android.path}/src/main/AndroidManifest.xml');
  final plugin = File('${kotlin.path}/FlutterVlessPlugin.kt');
  final config = File('${kotlin.path}/xray/dto/XrayConfig.kt');
  final core = File('${kotlin.path}/xray/core/XrayCoreManager.kt');
  final service = File('${kotlin.path}/xray/service/XrayVPNService.kt');

  for (final file in <File>[manifest, plugin, config, core, service]) {
    if (!file.existsSync()) fail('missing pinned runtime source: ${file.path}');
  }

  final finalState =
      containsAll(manifest, <String>[
        'android.net.VpnService.SUPPORTS_ALWAYS_ON',
        'android:value="false"',
      ]) &&
      containsAll(config, <String>['var ALLOWED_APPS:']) &&
      containsAll(plugin, <String>[
        '"getRuntimeHealth" -> {',
        'androidx.core.content.ContextCompat.RECEIVER_NOT_EXPORTED',
      ]) &&
      containsAll(core, <String>[
        'fun isXrayProcessAlive(): Boolean',
        'Could not delete ephemeral Xray config',
        'lightweight state heartbeat',
      ]) &&
      containsAll(service, <String>[
        'Authenticated ReVolt SOCKS5 inbound missing',
        'Allowed and blocked app policies cannot be mixed',
        'startRuntimeHealthMonitor(config, false)',
        'val tunInterfaceAlive = proxyOnly ||',
        'override fun onRevoke()',
        'Failed to start foreground; refusing VPN startup',
      ]);

  if (finalState) {
    stdout.writeln(
      '[runtime patch driver] final ReVolt runtime patch already present; skipping mutation',
    );
    return;
  }

  // Follow-up can only start after the main reliability patch completed. If a
  // previous build was interrupted during follow-up, resume only that final
  // stage rather than feeding its final source shape back through older patchers.
  final followupStarted = containsAll(plugin, <String>[
        'androidx.core.content.ContextCompat.RECEIVER_NOT_EXPORTED',
      ]) ||
      containsAll(service, <String>['override fun onRevoke()']);
  if (followupStarted) {
    runPatch('tool/patch_flutter_vless_runtime_reliability_followup.dart');
    stdout.writeln('[runtime patch driver] resumed follow-up patch successfully');
    return;
  }

  // The main reliability patch writes manifest/plugin/core before it reaches
  // the service anchors. A killed/failed build can therefore leave pub-cache in
  // a legitimate partial state. Resume from that stage instead of replaying the
  // secure-SOCKS patch over source already transformed by later stages.
  final reliabilityStarted = containsAll(plugin, <String>[
        '"getRuntimeHealth" -> {',
      ]) ||
      containsAll(core, <String>['fun isXrayProcessAlive(): Boolean']) ||
      containsAll(service, <String>['private var runtimeHealthThread: Thread? = null']);
  if (reliabilityStarted) {
    ensureRuntimeAnchorCompatibility(service);
    runPatch('tool/patch_flutter_vless_runtime_reliability.dart');
    runPatch('tool/patch_flutter_vless_runtime_reliability_followup.dart');
    stdout.writeln('[runtime patch driver] resumed reliability patch successfully');
    return;
  }

  runPatch('tool/patch_flutter_vless_allowed_apps.dart');
  runPatch('tool/patch_flutter_vless_secure_socks_v2.dart');
  runPatch('tool/patch_flutter_vless_secure_socks_scope_fix.dart');

  ensureRuntimeAnchorCompatibility(service);
  runPatch('tool/patch_flutter_vless_runtime_reliability.dart');
  runPatch('tool/patch_flutter_vless_runtime_reliability_followup.dart');

  stdout.writeln('[runtime patch driver] full Android runtime patch is ready');
}
