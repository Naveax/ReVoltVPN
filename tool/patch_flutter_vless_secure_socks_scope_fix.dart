import 'dart:convert';
import 'dart:io';

const packageName = 'flutter_vless_android';
const expectedVersionFragment = 'flutter_vless_android-1.1.5';

Never fail(String message) {
  stderr.writeln('[secure-socks scope fix] $message');
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

void patchCoreScope(File core) {
  final before = core.readAsStringSync();

  // The primary secure patcher used a file-wide check for
  // `val process = pb.start()`. Stock 1.1.5 already contains that exact line
  // in getV2rayTraffic(), so the startCore() capture could be skipped while
  // its monitor was still rewritten to use `process`. Capture the active Xray
  // process immediately before its monitor thread instead. This is deliberately
  // a scope-only correction and does not alter the stable runtime sequence.
  const directCapture =
      '            val process = pb.start()\n            xrayProcess = process\n';
  const scopedCapture =
      '            val process = xrayProcess ?: return false\n            // Monitor process in a separate thread to detect crash\n';
  const monitorMarker =
      '            // Monitor process in a separate thread to detect crash\n';

  if (before.contains(directCapture) || before.contains(scopedCapture)) {
    stdout.writeln('[secure-socks scope fix] core already current: ${core.path}');
    return;
  }

  if (!before.contains('process.inputStream.bufferedReader().use { reader ->') ||
      !before.contains('val exitCode = process.waitFor()') ||
      !before.contains('xrayProcess === process')) {
    fail('secure Xray monitor patch is not in the expected state');
  }
  if (!before.contains('            xrayProcess = pb.start()\n')) {
    fail('stock Xray start assignment is missing');
  }
  if (!before.contains(monitorMarker)) {
    fail('Xray monitor insertion point is missing');
  }

  final after = before.replaceFirst(monitorMarker, scopedCapture);
  core.writeAsStringSync(after);
  stdout.writeln('[secure-socks scope fix] captured Xray process for monitor scope');
}

void patchOngoingNotification(File service) {
  final before = service.readAsStringSync();

  const marker = '.setOngoing(true)';
  if (before.contains(marker) &&
      before.contains('Notification.FLAG_NO_CLEAR') &&
      before.contains('.setAutoCancel(false)')) {
    stdout.writeln('[secure-socks scope fix] notification already ongoing: ${service.path}');
    return;
  }

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

        // Keep the active VPN notification attached to the foreground service
        // and resistant to bulk clearing on Android versions that honor these
        // flags. Android 14+ may still allow an explicit user swipe while the
        // device is unlocked; apps are not allowed to override that system UI.
        notification.flags = notification.flags or
            android.app.Notification.FLAG_ONGOING_EVENT or
            android.app.Notification.FLAG_NO_CLEAR
        return notification
''';

  if (!before.contains(oldBlock)) {
    fail('VPN notification builder is not in the expected stock 1.1.5 state');
  }

  final after = before.replaceFirst(oldBlock, newBlock);
  if (!after.contains(marker) ||
      !after.contains('Notification.FLAG_NO_CLEAR') ||
      !after.contains('.setAutoCancel(false)')) {
    fail('ongoing VPN notification invariant failed');
  }

  service.writeAsStringSync(after);
  stdout.writeln('[secure-socks scope fix] VPN notification marked ongoing/no-clear');
}

void main() {
  final root = packageRoot();
  final kotlin =
      '${root.path}/android/src/main/kotlin/com/github/tfox/flutter_vless';
  final core = File('$kotlin/xray/core/XrayCoreManager.kt');
  final service = File('$kotlin/xray/service/XrayVPNService.kt');

  if (!core.existsSync()) fail('XrayCoreManager.kt is missing');
  if (!service.existsSync()) fail('XrayVPNService.kt is missing');

  patchCoreScope(core);
  patchOngoingNotification(service);
  stdout.writeln('[secure-socks scope fix] scope and notification patch ready');
}
