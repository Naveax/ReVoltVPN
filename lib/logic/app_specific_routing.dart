import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract final class AppSpecificRouting {
  AppSpecificRouting._();

  static const MethodChannel _channel =
      MethodChannel('com.revoltvpn.app/app_routing');

  static Future<void> start(Iterable<String> packages) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    final values = packages
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    if (values.isEmpty) {
      throw StateError('Select at least one app.');
    }

    await _channel.invokeMethod<void>(
      'start',
      <String, Object>{'packages': values},
    );
  }

  static Future<void> stop() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('stop');
  }
}
