import 'dart:convert';
import 'dart:io';

const packageName = 'flutter_vless_android';
const expectedVersionFragment = 'flutter_vless_android-1.1.5';

Never fail(String message) {
  stderr.writeln('[flutter_vless recovery patch] $message');
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
    stdout.writeln('[flutter_vless recovery patch] already current: ${file.path}');
    return;
  }
  if (!text.contains(oldValue)) {
    fail('upstream source changed; expected block not found in ${file.path}');
  }
  file.writeAsStringSync(text.replaceFirst(oldValue, newValue));
  stdout.writeln('[flutter_vless recovery patch] patched: ${file.path}');
}

void main() {
  final root = packageRoot();
  final kotlin = Directory(
    '${root.path}/android/src/main/kotlin/com/github/tfox/flutter_vless',
  );

  final serviceFile = File('${kotlin.path}/xray/service/XrayVPNService.kt');
  if (!serviceFile.existsSync()) {
    fail('pinned Android runtime service source is missing');
  }

  // A fast reconnect must not leave the previous Xray process owning the local
  // SOCKS/HTTP ports.
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

  // The tun2socks Unix socket must not survive a previous session.
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

  stdout.writeln('[flutter_vless recovery patch] runtime recovery patch is ready');
}
