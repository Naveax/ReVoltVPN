import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';

void main() {
  test('initial lease subtracts local startup time', () {
    final lease = HivemindConfigLease(
      vlessUrl: 'vless://example',
      expiresInSeconds: 120,
    );

    expect(lease.remainingAfter(const Duration(seconds: 17)), 103);
  });

  test('initial lease saturates at zero', () {
    final lease = HivemindConfigLease(
      vlessUrl: 'vless://example',
      expiresInSeconds: 30,
    );

    expect(lease.remainingAfter(const Duration(seconds: 30)), 0);
    expect(lease.remainingAfter(const Duration(seconds: 90)), 0);
  });

  test('invalid initial lease is rejected', () {
    expect(
      () => HivemindConfigLease(vlessUrl: '', expiresInSeconds: 60),
      throwsArgumentError,
    );
    expect(
      () => HivemindConfigLease(
        vlessUrl: 'vless://example',
        expiresInSeconds: 0,
      ),
      throwsArgumentError,
    );
  });
}
