import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Small Android-only extension used by ReVolt's pinned flutter_vless 1.1.5.
///
/// The stock plugin exposes a blocklist but not Android's native allowlist.
/// The build patch adds `setAllowedApps` to the existing `flutter_vless`
/// MethodChannel. Keeping the extension here avoids a second VpnService.
abstract final class FlutterVlessAndroidRouting {
  FlutterVlessAndroidRouting._();

  static const MethodChannel _channel = MethodChannel('flutter_vless');

  static Future<void> setAllowedApps(Iterable<String> packages) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    final values = packages
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    await _channel.invokeMethod<void>(
      'setAllowedApps',
      <String, Object>{'allowed_apps': values},
    );
  }
}
