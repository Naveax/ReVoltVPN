import 'package:flutter_test/flutter_test.dart';

import '../lib/logic/network_monitor.dart';

void main() {
  test('malformed network metadata falls back without a cast failure', () {
    final snapshot = NetworkSnapshot.fromMap(<String, Object>{
      'reason': 123,
      'transport': false,
      'timestamp': 'invalid',
      'connected': 'true',
    });
    expect(snapshot.reason, 'changed');
    expect(snapshot.transport, 'unknown');
    expect(snapshot.timestamp, 0);
    expect(snapshot.connected, isFalse);
  });

  test('valid native network metadata is preserved', () {
    final snapshot = NetworkSnapshot.fromMap(<String, Object>{
      'reason': 'available',
      'transport': 'wifi',
      'timestamp': 123,
      'connected': true,
      'validated': true,
      'metered': false,
    });
    expect(snapshot.reason, 'available');
    expect(snapshot.transport, 'wifi');
    expect(snapshot.timestamp, 123);
    expect(snapshot.connected, isTrue);
    expect(snapshot.validated, isTrue);
    expect(snapshot.metered, isFalse);
  });
}
