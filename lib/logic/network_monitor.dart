import 'package:flutter/services.dart';

class NetworkSnapshot {
  final String reason;
  final String transport;
  final bool connected;
  final bool validated;
  final bool metered;
  final int timestamp;

  const NetworkSnapshot({
    required this.reason,
    required this.transport,
    required this.connected,
    required this.validated,
    required this.metered,
    required this.timestamp,
  });

  factory NetworkSnapshot.fromMap(Map<dynamic, dynamic> map) {
    return NetworkSnapshot(
      reason: map['reason'] as String? ?? 'changed',
      transport: map['transport'] as String? ?? 'unknown',
      connected: map['connected'] == true,
      validated: map['validated'] == true,
      metered: map['metered'] == true,
      timestamp: (map['timestamp'] as num?)?.toInt() ?? 0,
    );
  }
}

abstract final class NetworkMonitor {
  NetworkMonitor._();

  static const EventChannel _channel = EventChannel('com.revoltvpn.app/network');

  static Stream<NetworkSnapshot> get changes {
    return _channel.receiveBroadcastStream().where((event) => event is Map).map(
          (event) => NetworkSnapshot.fromMap(event as Map<dynamic, dynamic>),
        );
  }
}
