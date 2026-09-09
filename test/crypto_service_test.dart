import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/crypto_service.dart';

void main() {
  test('device id is canonicalized to lowercase UUIDv4', () {
    expect(
      CryptoService.canonicalizeDeviceId(
        'A0B1C2D3-E4F5-4A67-8B9C-0D1E2F3A4B5C',
      ),
      'a0b1c2d3-e4f5-4a67-8b9c-0d1e2f3a4b5c',
    );
  });

  test('invalid or non-v4 device ids are rejected', () {
    for (final value in <String?>[
      null,
      '',
      'not-a-uuid',
      'a0b1c2d3-e4f5-3a67-8b9c-0d1e2f3a4b5c',
      'a0b1c2d3e4f54a678b9c0d1e2f3a4b5c',
    ]) {
      expect(CryptoService.canonicalizeDeviceId(value), isNull);
    }
  });
}
