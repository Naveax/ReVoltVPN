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
