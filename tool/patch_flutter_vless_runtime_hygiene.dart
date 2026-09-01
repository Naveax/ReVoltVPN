import 'dart:convert';
import 'dart:io';

const packageName = 'flutter_vless_android';
const expectedVersionFragment = 'flutter_vless_android-1.1.5';

Never fail(String message) {
  stderr.writeln('[runtime hygiene] $message');
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
    stdout.writeln('[runtime hygiene] already current: ${file.path}');
    return;
  }
  if (!text.contains(oldValue)) {
    fail('upstream source changed; expected block not found in ${file.path}');
  }
  file.writeAsStringSync(text.replaceFirst(oldValue, newValue));
  stdout.writeln('[runtime hygiene] patched: ${file.path}');
}

void writeIfChanged(File file, String before, String after) {
  if (before == after) {
    stdout.writeln('[runtime hygiene] already current: ${file.path}');
    return;
  }
  file.writeAsStringSync(after);
  stdout.writeln('[runtime hygiene] patched: ${file.path}');
}

void patchManifest(File file) {
  if (!file.existsSync()) fail('missing upstream source: ${file.path}');
  final before = file.readAsStringSync();
  var text = before;

  // VpnService does not need to mutate global network state, and ReVolt never
  // reads shared/external storage. Do not inherit legacy permissions from the
  // pinned plugin when its runtime does not use them.
  text = text.replaceAll(
    '    <uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />\n',
    '',
  );
  text = text.replaceAll(
    '    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />\n',
    '',
  );

  writeIfChanged(file, before, text);
}

void patchCore(File file) {
  if (!file.existsSync()) fail('missing upstream source: ${file.path}');
  final before = file.readAsStringSync();
  var text = before;

  // A new channel ID is intentional: Android keeps a channel's original
  // importance across app upgrades. Reusing XRAY_SERVICE_CHANNEL would leave
  // users who once received the DEFAULT channel stuck with its old importance.
  text = text.replaceAll('"XRAY_SERVICE_CHANNEL"', '"REVOLT_VPN_SERVICE"');

  const noisyXray = r'''                        reader.forEachLine { line ->
                            Log.d(TAG, "xray: $line")
                        }
''';
  const silentXray = r'''                        reader.forEachLine { _ -> }
''';
  if (text.contains(noisyXray)) {
    text = text.replaceFirst(noisyXray, silentXray);
  } else if (!text.contains(silentXray)) {
    fail('upstream Xray stdout monitor changed');
  }

  if (!text.contains('private fun deleteEphemeralConfigOnFailure')) {
    const fields = r'''    private var lastProxyUplink = 0L
    private var lastProxyDownlink = 0L
''';
    const fieldsWithCleanup = r'''    private var lastProxyUplink = 0L
    private var lastProxyDownlink = 0L

    private fun deleteEphemeralConfigOnFailure(filesDir: File) {
        try {
            val config = File(filesDir, "config.json")
            if (config.exists() && !config.delete()) {
                Log.w(TAG, "Could not delete failed ephemeral Xray config")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not delete failed ephemeral Xray config", e)
        }
    }
''';
    if (!text.contains(fields)) fail('Xray state field anchor changed');
    text = text.replaceFirst(fields, fieldsWithCleanup);
  }

  const writeFailure = r'''        } catch (e: Exception) {
            Log.e(TAG, "Failed to write config file", e)
            return false
        }
''';
  const writeFailureClean = r'''        } catch (e: Exception) {
            Log.e(TAG, "Failed to write config file", e)
            deleteEphemeralConfigOnFailure(configFilesDir)
            return false
        }
''';
  if (text.contains(writeFailure)) {
    text = text.replaceFirst(writeFailure, writeFailureClean);
  }

  const missingExecutable = r'''        if (!xrayExecutable.exists()) {
            Log.e(TAG, "Xray executable not found at ${xrayExecutable.absolutePath}")
            // Fallback or error
            return false
        }
''';
  const missingExecutableClean = r'''        if (!xrayExecutable.exists()) {
            Log.e(TAG, "Xray executable not found at ${xrayExecutable.absolutePath}")
            deleteEphemeralConfigOnFailure(configFilesDir)
            return false
        }
''';
  if (text.contains(missingExecutable)) {
    text = text.replaceFirst(missingExecutable, missingExecutableClean);
  }

  const copyAssets = '        Utilities.copyAssets(context)\n';
  const copyAssetsSafe = r'''        try {
            Utilities.copyAssets(context)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to prepare Xray assets", e)
            deleteEphemeralConfigOnFailure(configFilesDir)
            return false
        }
''';
  if (text.contains(copyAssets)) {
    text = text.replaceFirst(copyAssets, copyAssetsSafe);
  } else if (!text.contains('Failed to prepare Xray assets')) {
    fail('Xray asset preparation anchor changed');
  }

  const startupDead = r'''            if (xrayProcess?.isAlive != true) {
                val output = xrayProcess?.inputStream?.bufferedReader()?.readText().orEmpty()
                Log.e(TAG, "Xray process exited during startup. Output: $output")
                xrayProcess = null
                AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED
                return false
            }
''';
  const startupDeadClean = r'''            if (xrayProcess?.isAlive != true) {
                val output = xrayProcess?.inputStream?.bufferedReader()?.readText().orEmpty()
                Log.e(TAG, "Xray process exited during startup. Output: $output")
                xrayProcess = null
                AppConfigs.V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED
                deleteEphemeralConfigOnFailure(configFilesDir)
                return false
            }
''';
  if (text.contains(startupDead)) {
    text = text.replaceFirst(startupDead, startupDeadClean);
  } else if (!text.contains('deleteEphemeralConfigOnFailure(configFilesDir)\n                return false')) {
    fail('Xray startup failure anchor changed');
  }

  const startCatch = r'''        } catch (e: Exception) {
            Log.e(TAG, "Failed to start Xray process", e)
            return false
        }
''';
  const startCatchClean = r'''        } catch (e: Exception) {
            Log.e(TAG, "Failed to start Xray process", e)
            deleteEphemeralConfigOnFailure(configFilesDir)
            return false
        }
''';
  if (text.contains(startCatch)) {
    text = text.replaceFirst(startCatch, startCatchClean);
  }

  writeIfChanged(file, before, text);
}

void patchService(File file) {
  if (!file.existsSync()) fail('missing upstream source: ${file.path}');
  final before = file.readAsStringSync();
  var text = before;

  text = text.replaceAll('"vpn_service_channel"', '"REVOLT_VPN_SERVICE"');
  text = text.replaceAll('"XRAY_SERVICE_CHANNEL"', '"REVOLT_VPN_SERVICE"');

  const noisyTun = r'''                        reader.forEachLine { line ->
                            Log.d(TAG, "tun2socks: $line")
                        }
''';
  const silentTun = r'''                        reader.forEachLine { _ -> }
''';
  if (text.contains(noisyTun)) {
    text = text.replaceFirst(noisyTun, silentTun);
  } else if (!text.contains(silentTun)) {
    fail('upstream tun2socks stdout monitor changed');
  }

  // Preserve the upstream comment used by the later route-hardening stage.
  // Only the failure behavior changes here.
  const permissiveDns = r'''            // Add DNS servers
            try {
                builder.addDnsServer("8.8.8.8")
                builder.addDnsServer("1.1.1.1")
            } catch (e: Exception) {
                // ignore
            }
''';
  const failClosedDns = r'''            // Add DNS servers
            try {
                builder.addDnsServer("8.8.8.8")
                builder.addDnsServer("1.1.1.1")
            } catch (e: Exception) {
                throw IllegalStateException("Failed to configure VPN DNS", e)
            }
''';
  if (text.contains(permissiveDns)) {
    text = text.replaceFirst(permissiveDns, failClosedDns);
  } else if (!text.contains('Failed to configure VPN DNS')) {
    fail('upstream VPN DNS block changed');
  }

  writeIfChanged(file, before, text);
}

void main() {
  final root = packageRoot();
  final androidRoot = '${root.path}/android/src/main';
  final kotlin = '$androidRoot/kotlin/com/github/tfox/flutter_vless';
  final manifestFile = File('$androidRoot/AndroidManifest.xml');
  final coreFile = File('$kotlin/xray/core/XrayCoreManager.kt');
  final serviceFile = File('$kotlin/xray/service/XrayVPNService.kt');

  replaceOnce(
    serviceFile,
    '''            if (config != null) {
                // Ensure clean state before starting
                cleanup()
''',
    '''            if (config != null) {
                // A fast reconnect must not leave the previous Xray process
                // owning the local proxy port.
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

  patchManifest(manifestFile);
  patchCore(coreFile);
  patchService(serviceFile);

  stdout.writeln('[runtime hygiene] native runtime hygiene is ready');
}
