import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/native_tunnel_control.dart';

void main() {
  test('fresh app-process state is unknown, not authoritative stopped', () {
    final state = NativeTunnelState.fromMap(<Object?, Object?>{
      'state': 'DISCONNECTED',
      'generation': 0,
      'error': '',
    });

    expect(state.state, 'UNKNOWN');
    expect(state.stopped, isFalse);
    expect(state.fullyReady, isFalse);
  });

  test('connected requires the complete native data path and private SOCKS session', () {
    final ready = NativeTunnelState.fromMap(<Object?, Object?>{
      'state': 'CONNECTED',
      'tunEstablished': true,
      'fdDelivered': true,
      'socksReady': true,
      'socksPort': 24001,
      'socksUser': 'rv_test',
      'socksPass': 'secret',
      'generation': 4,
      'error': '',
    });

    expect(ready.fullyReady, isTrue);

    final missingFd = NativeTunnelState.fromMap(<Object?, Object?>{
      'state': 'CONNECTED',
      'tunEstablished': true,
      'fdDelivered': false,
      'socksReady': true,
      'socksPort': 24001,
      'socksUser': 'rv_test',
      'socksPass': 'secret',
      'generation': 4,
      'error': '',
    });

    expect(missingFd.fullyReady, isFalse);
  });

  test('authoritative disconnect requires readiness to be cleared', () {
    final state = NativeTunnelState.fromMap(<Object?, Object?>{
      'state': 'DISCONNECTED',
      'tunEstablished': false,
      'fdDelivered': false,
      'socksReady': false,
      'generation': 5,
      'error': 'tun2socks exited unexpectedly',
    });

    expect(state.stopped, isTrue);
    expect(state.fullyReady, isFalse);
  });
}
