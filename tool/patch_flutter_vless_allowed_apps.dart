import 'dart:convert';
import 'dart:io';

const packageName = 'flutter_vless_android';
const expectedVersionFragment = 'flutter_vless_android-1.1.5';

Never fail(String message) {
  stderr.writeln('[flutter_vless patch] $message');
  exit(1);
}

Directory packageRoot() {
  final configFile = File('.dart_tool/package_config.json');
  if (!configFile.isFile) {
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
    stdout.writeln('[flutter_vless patch] already current: ${file.path}');
    return;
  }
  if (!text.contains(oldValue)) {
    fail('upstream source changed; expected block not found in ${file.path}');
  }
  file.writeAsStringSync(text.replaceFirst(oldValue, newValue));
  stdout.writeln('[flutter_vless patch] patched: ${file.path}');
}

void replaceOneOf(
  File file,
  Map<String, String> replacements,
  String marker,
) {
  if (!file.existsSync()) fail('missing upstream source: ${file.path}');
  var text = file.readAsStringSync();
  if (text.contains(marker)) {
    stdout.writeln('[flutter_vless patch] already current: ${file.path}');
    return;
  }
  for (final entry in replacements.entries) {
    if (!text.contains(entry.key)) continue;
    text = text.replaceFirst(entry.key, entry.value);
    file.writeAsStringSync(text);
    stdout.writeln('[flutter_vless patch] patched/upgraded: ${file.path}');
    return;
  }
  fail('upstream/legacy patch shape not recognized in ${file.path}');
}

void main() {
  final root = packageRoot();
  final kotlin = Directory(
    '${root.path}/android/src/main/kotlin/com/github/tfox/flutter_vless',
  );

  final configFile = File('${kotlin.path}/xray/dto/XrayConfig.kt');
  replaceOnce(
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
  replaceOnce(
    pluginFile,
    '''    private lateinit var context: Context
''',
    '''    private lateinit var context: Context
    private var allowedApps: ArrayList<String> = ArrayList()
''',
    'private var allowedApps:',
  );

  const currentAllowedHandler = '''            "setAllowedApps" -> {
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
''';
  const legacyAllowedHandler = '''            "setAllowedApps" -> {
                val requested = call.argument<ArrayList<String>>("allowed_apps") ?: ArrayList()
                allowedApps = ArrayList(
                    requested.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
                )
                result.success(null)
            }
''';
  replaceOneOf(
    pluginFile,
    <String, String>{
      legacyAllowedHandler: currentAllowedHandler,
      '''        when (call.method) {
            "startVless" -> {
''': '''        when (call.method) {
$currentAllowedHandler            "startVless" -> {
''',
    },
    'it.isNotEmpty() && it != context.packageName',
  );

  replaceOnce(
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
  replaceOnce(
    serviceFile,
    '''            if (config != null) {
                // Ensure clean state before starting
                cleanup()
''',
    '''            if (config != null) {
                // A fast reconnect must not leave the previous Xray process
                // owning the local SOCKS/HTTP ports.
                if (XrayCoreManager.isXrayRunning()) {
                    Log.w(TAG, "Stopping stale Xray core before restart")
                    XrayCoreManager.stopCore(this)
                }
                cleanup()
''',
    'Stopping stale Xray core before restart',
  );

  replaceOnce(
    serviceFile,
    '''        val tun2socksPath = File(applicationInfo.nativeLibraryDir, "libtun2socks.so").absolutePath
        val sockPath = File(filesDir, "sock_path").absolutePath
''',
    '''        val tun2socksPath = File(applicationInfo.nativeLibraryDir, "libtun2socks.so").absolutePath
        val socketFile = File(filesDir, "sock_path")
        if (socketFile.exists() && !socketFile.delete()) {
            Log.w(TAG, "Could not delete stale tun2socks socket")
        }
        val sockPath = socketFile.absolutePath
''',
    'Could not delete stale tun2socks socket',
  );

  const upstreamPolicy = r'''          try {
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

  const legacyPatchedPolicy = r'''            if (config.ALLOWED_APPS.isNotEmpty()) {
                for (pkg in config.ALLOWED_APPS) {
                    try {
                        builder.addAllowedApplication(pkg)
                        Log.d(TAG, "Allowed into VPN: $pkg")
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to allow $pkg into VPN", e)
                    }
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

  const hardenedPolicy = r'''            if (config.ALLOWED_APPS.isNotEmpty() && config.BLOCKED_APPS.isNotEmpty()) {
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

  // Raw Dart strings keep Kotlin's $pkg interpolation intact and require no
  // quote-unescaping. Support both pristine 1.1.5 and the earlier local patch.
  replaceOneOf(
    serviceFile,
    const <String, String>{
      legacyPatchedPolicy: hardenedPolicy,
      upstreamPolicy: hardenedPolicy,
    },
    'Allowed and blocked app policies cannot be mixed',
  );

  stdout.writeln('[flutter_vless patch] allowed-app routing patch is ready');
}
