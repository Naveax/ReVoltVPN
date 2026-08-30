import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum NativeRoutingPolicy { all, exclude, selected }

class NativeRoutingStatus {
  final String state;
  final String? error;

  const NativeRoutingStatus({
    required this.state,
    required this.error,
  });

  bool get running => state == 'running';
  bool get failed => state == 'error';
}

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

    for (var attempt = 0; attempt < 24; attempt++) {
      await Future.delayed(const Duration(milliseconds: 200));
      final snapshot = await status();
      if (snapshot.running) return;
      if (snapshot.failed) {
        throw StateError(snapshot.error ?? 'Native app routing failed.');
      }
    }

    throw TimeoutException(
      'Native app routing did not become ready.',
      const Duration(milliseconds: 4800),
    );
  }

  static Future<NativeRoutingStatus> status() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const NativeRoutingStatus(state: 'idle', error: null);
    }

    final raw = await _channel.invokeMapMethod<String, dynamic>('status');
    return NativeRoutingStatus(
      state: raw?['state']?.toString() ?? 'idle',
      error: raw?['error']?.toString(),
    );
  }

  static Future<void> stop() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('stop');
  }
}
