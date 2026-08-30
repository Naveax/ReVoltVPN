import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum NativeRoutingPolicy { all, exclude, selected }

abstract final class AppSpecificRouting {
  AppSpecificRouting._();

  static const MethodChannel _channel =
      MethodChannel('com.revoltvpn.app/app_routing');

  static Future<void> start({
    required NativeRoutingPolicy policy,
    Iterable<String> packages = const <String>[],
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    final values = packages
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    if (policy == NativeRoutingPolicy.selected && values.isEmpty) {
      throw StateError('Select at least one app.');
    }

    await _channel.invokeMethod<void>(
      'start',
      <String, Object>{
        'policy': policy.name,
        'packages': values,
      },
    );
  }

  static Future<void> stop() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('stop');
  }
}
