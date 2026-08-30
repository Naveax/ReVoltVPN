import 'dart:async';

import 'package:flutter/services.dart';

class NativeTunnelState {
  final String state;
  final bool tunEstablished;
  final bool fdDelivered;
  final bool socksReady;
  final int socksPort;
  final String socksUser;
  final String socksPass;
  final int generation;
  final String error;

  const NativeTunnelState({
    required this.state,
    required this.tunEstablished,
    required this.fdDelivered,
    required this.socksReady,
    required this.socksPort,
    required this.socksUser,
    required this.socksPass,
    required this.generation,
    required this.error,
  });

  factory NativeTunnelState.fromMap(Map<Object?, Object?> map) {
    final generation = (map['generation'] as num?)?.toInt() ?? 0;
    final error = map['error']?.toString() ?? '';
    final rawState = map['state']?.toString() ?? 'UNKNOWN';
    final state = rawState == 'DISCONNECTED' && generation == 0 && error.isEmpty
        ? 'UNKNOWN'
        : rawState;

    return NativeTunnelState(
      state: state,
      tunEstablished: map['tunEstablished'] == true,
      fdDelivered: map['fdDelivered'] == true,
      socksReady: map['socksReady'] == true,
      socksPort: (map['socksPort'] as num?)?.toInt() ?? 0,
      socksUser: map['socksUser']?.toString() ?? '',
      socksPass: map['socksPass']?.toString() ?? '',
      generation: generation,
      error: error,
    );
  }

  bool get fullyReady =>
      state == 'CONNECTED' &&
      tunEstablished &&
      fdDelivered &&
      socksReady &&
      socksPort > 0 &&
      socksUser.isNotEmpty &&
      socksPass.isNotEmpty;

  bool get stopped =>
      state == 'DISCONNECTED' &&
      generation > 0 &&
      !tunEstablished &&
      !fdDelivered &&
      !socksReady;
}

abstract final class NativeTunnelControl {
  NativeTunnelControl._();

  static const MethodChannel _channel = MethodChannel('flutter_vless');

  static Future<NativeTunnelState> getState() async {
    final raw = await _channel.invokeMethod<Object?>('getTunnelState');
    if (raw is! Map) {
      throw StateError('Native VPN state payload is invalid.');
    }
    return NativeTunnelState.fromMap(Map<Object?, Object?>.from(raw));
  }

  static Future<void> setAllowedApps(List<String> packages) async {
    final ok = await _channel.invokeMethod<bool>(
          'setAllowedApps',
          <String, Object>{'packages': packages},
        ) ??
        false;
    if (!ok) {
      throw StateError('Native app routing policy was rejected.');
    }
  }

  static Future<bool> waitUntilReady({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final deadline = DateTime.now().add(timeout);
    do {
      final state = await getState();
      if (state.fullyReady) return true;
      if (state.state == 'DISCONNECTED' && state.error.isNotEmpty) return false;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    } while (DateTime.now().isBefore(deadline));
    return (await getState()).fullyReady;
  }

  static Future<bool> waitUntilStopped({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final deadline = DateTime.now().add(timeout);
    do {
      final state = await getState();
      if (state.stopped) return true;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    } while (DateTime.now().isBefore(deadline));
    return (await getState()).stopped;
  }

  static Future<bool> restartCurrentRuntime() async {
    return await _channel.invokeMethod<bool>('restartCurrentRuntime') ?? false;
  }
}
