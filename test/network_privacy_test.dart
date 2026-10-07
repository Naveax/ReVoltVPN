import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/network_privacy.dart';

void main() {
  group('VLESS endpoint privacy boundary', () {
    test('accepts canonical IPv4 without changing authority form', () {
      expect(NetworkPrivacy.vlessAuthorityHost('204.168.246.88'),
          '204.168.246.88');
      expect(NetworkPrivacy.vlessAuthorityHost('0.0.0.0'), '0.0.0.0');
    });

    test('accepts IPv6 and brackets it for URI authority', () {
      expect(NetworkPrivacy.vlessAuthorityHost('2001:db8::1'), '[2001:db8::1]');
      expect(NetworkPrivacy.vlessAuthorityHost('::1'), '[::1]');
      expect(NetworkPrivacy.vlessAuthorityHost('::ffff:192.0.2.1'),
          '[::ffff:192.0.2.1]');
    });

    test('rejects hostname, whitespace, zone id and pre-bracketed input', () {
      for (final value in <Object?>[
        'vpn.example.com',
        ' 204.168.246.88',
        '204.168.246.88 ',
        'fe80::1%wlan0',
        '[2001:db8::1]',
        '',
        null,
        1234,
      ]) {
        expect(() => NetworkPrivacy.vlessAuthorityHost(value),
            throwsFormatException,
            reason: '$value must not become a transport endpoint');
      }
    });

    test('rejects malformed and noncanonical IP syntax', () {
      for (final value in [
        '01.2.3.4',
        '256.1.1.1',
        '1.2.3',
        '2001:db8',
        'gggg::1',
        '1:2:3:4:5:6:7:8:9',
      ]) {
        expect(() => NetworkPrivacy.vlessAuthorityHost(value),
            throwsFormatException);
      }
    });

    test('port is integer-only, bounded and defaults only when absent', () {
      expect(NetworkPrivacy.vlessPort(null), 443);
      expect(NetworkPrivacy.vlessPort(1), 1);
      expect(NetworkPrivacy.vlessPort(65535), 65535);

      for (final value in <Object?>[0, 65536, -1, '443', 443.0]) {
        expect(() => NetworkPrivacy.vlessPort(value), throwsFormatException);
      }
    });
  });
}
