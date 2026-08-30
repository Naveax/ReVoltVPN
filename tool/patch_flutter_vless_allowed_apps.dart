import 'dart:convert';
import 'dart:io';

const String packageName = 'flutter_vless_android';
const String expectedVersionFragment = 'flutter_vless_android-1.1.5';

Never _fail(String message) {
  stderr.writeln('[flutter_vless patch] $message');
  exit(1);
}

Directory _packageRoot() {
  final configFile = File('.dart_tool/package_config.json');
  if (!configFile.existsSync()) {
    _fail('.dart_tool/package_config.json is missing; run flutter pub get first');
  }

  final decoded = jsonDecode(configFile.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    _fail('package_config.json has an invalid root object');
  }

  final packages = decoded['packages'];
  if (packages is! List) {
    _fail('package_config.json has no packages list');
  }

  Map<String, dynamic>? package;
  for (final item in packages) {
    if (item is Map && item['name'] == packageName) {
      package = Map<String, dynamic>.from(item);
      break;
    }
  }
  if (package == null) {
    _fail('$packageName was not found in package_config.json');
  }

  final rootUriValue = package['rootUri'];
  if (rootUriValue is! String || rootUriValue.isEmpty) {
    _fail('$packageName has no rootUri');
  }

  final rootUri = Uri.parse(rootUriValue);
  final resolvedUri = rootUri.hasScheme
      ? rootUri
      : configFile.parent.absolute.uri.resolveUri(rootUri);
  if (resolvedUri.scheme != 'file') {
    _fail('unsupported package root URI: $resolvedUri');
  }

  final root = Directory.fromUri(resolvedUri);
  final normalized = root.absolute.path.replaceAll('\\', '/');
  if (!normalized.contains(expectedVersionFragment)) {
    _fail('expected flutter_vless_android 1.1.5, got ${root.path}');
  }
  if (!root.existsSync()) {
    _fail('package root does not exist: ${root.path}');
  }
  return root;
}

void _replaceOnce(
  File file,
  String oldValue,
  String newValue,
  String marker,
) {
  if (!file.existsSync()) {
    _fail('missing upstream source: ${file.path}');
  }

  final text = file.readAsStringSync();
  if (text.contains(marker)) {
    stdout.writeln('[flutter_vless patch] already patched: ${file.path}');
    return;
  }
  if (!text.contains(oldValue)) {
    _fail('upstream source changed; expected block not found in ${file.path}');
  }

  file.writeAsStringSync(text.replaceFirst(oldValue, newValue));
  stdout.writeln('[flutter_vless patch] patched: ${file.path}');
}

void main() {
  final root = _packageRoot();
  final kotlin = Directory(
    '${root.path}/android/src/main/kotlin/com/github/tfox/flutter_vless',
  );

  final configFile = File('${kotlin.path}/xray/dto/XrayConfig.kt');
  _replaceOnce(
    configFile,
    '''    /** List of app package names to exclude from VPN. */
    var BLOCKED_APPS: ArrayList<String> = ArrayList(),
''',
    '''    /** List of app package names to exclude from VPN. */
    var BLOCKED_APPS: ArrayList<String> = ArrayList(),

    /** List of app package names that are exclusively allowed into VPN. */
    var ALLOWED_APPS: ArrayList<String> = ArrayList(),
''',
    'var ALLOWED_APPS:',
  );

  final pluginFile = File('${kotlin.path}/FlutterVlessPlugin.kt');
  _replaceOnce(
    pluginFile,
    '''    private lateinit var context: Context
''',
    '''    private lateinit var context: Context
    private var allowedApps: ArrayList<String> = ArrayList()
''',
    'private var allowedApps:',
  );
  _replaceOnce(
    pluginFile,
    '''        when (call.method) {
            "startVless" -> {
''',
    '''        when (call.method) {
            "setAllowedApps" -> {
                val requested = call.argument<ArrayList<String>>("allowed_apps") ?: ArrayList()
                allowedApps = ArrayList(
                    requested
                        .map { it.trim() }
                        .filter { it.isNotEmpty() && it != context.packageName }
                        .distinct()
                        .sorted()
                )
                result.success(null)
            }
            "startVless" -> {
''',
    '"setAllowedApps" ->',
  );
  _replaceOnce(
    pluginFile,
    '''                config.BLOCKED_APPS = call.argument<ArrayList<String>>("blocked_apps") ?: ArrayList()
                config.BYPASS_SUBNETS = call.argument<ArrayList<String>>("bypass_subnets") ?: ArrayList()
''',
    '''                config.BLOCKED_APPS = call.argument<ArrayList<String>>("blocked_apps") ?: ArrayList()
                config.ALLOWED_APPS = ArrayList(allowedApps)
                config.BYPASS_SUBNETS = call.argument<ArrayList<String>>("bypass_subnets") ?: ArrayList()
''',
    'config.ALLOWED_APPS = ArrayList(allowedApps)',
  );

  final serviceFile = File('${kotlin.path}/xray/service/XrayVPNService.kt');
  _replaceOnce(
    serviceFile,
    '''            if (config != null) {
                // Ensure clean state before starting
                cleanup()
''',
    '''            if (config != null) {
                // Ensure a stale Xray process cannot keep 10807/10808 occupied
                // across a fast reconnect or service restart.
                if (XrayCoreManager.isXrayRunning()) {
                    Log.w(TAG, "Stopping stale Xray core before restart")
                    XrayCoreManager.stopCore(this)
                }
                cleanup()
''',
    'Stopping stale Xray core before restart',
  );

  const oldPolicy = '''          try {
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
  const newPolicy = '''            if (config.ALLOWED_APPS.isNotEmpty() && config.BLOCKED_APPS.isNotEmpty()) {
                throw IllegalStateException("Allowed and blocked app policies cannot be mixed")
            }

            if (config.ALLOWED_APPS.isNotEmpty()) {
                var allowedCount = 0
                for (pkg in config.ALLOWED_APPS) {
                    try {
                        builder.addAllowedApplication(pkg)
                        allowedCount++
                        Log.d(TAG, "Allowed into VPN: $pkg")
                    } catch (e: Exception) {
                        throw IllegalStateException("Failed to allow selected app $pkg", e)
                    }
                }
                if (allowedCount == 0) {
                    throw IllegalStateException("Selected-only routing has no valid applications")
                }
            } else {
                try {
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
            }
''';
  _replaceOnce(
    serviceFile,
    oldPolicy,
    newPolicy,
    'builder.addAllowedApplication(pkg)',
  );

  stdout.writeln('[flutter_vless patch] allowed-app routing patch is ready');
}
