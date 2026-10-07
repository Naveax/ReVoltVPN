import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/network_privacy.dart';

void main() {
  group('VLESS endpoint privacy boundary', () {
    test('accepts public canonical IPv4 literals', () {
      expect(NetworkPrivacy.vlessAuthorityHost('204.168.246.88'),
          '204.168.246.88');
      expect(NetworkPrivacy.vlessAuthorityHost('1.1.1.1'), '1.1.1.1');
      expect(NetworkPrivacy.vlessAuthorityHost('8.8.8.8'), '8.8.8.8');
    });

    test('accepts public IPv6 and brackets it for URI authority', () {
      expect(NetworkPrivacy.vlessAuthorityHost('2606:4700:4700::1111'),
          '[2606:4700:4700::1111]');
      expect(NetworkPrivacy.vlessAuthorityHost('2001:4860:4860::8888'),
          '[2001:4860:4860::8888]');
    });

    test('rejects unsafe IPv4 transport endpoints', () {
      for (final value in [
        '0.0.0.0',
        '10.0.0.7',
        '100.64.0.1',
        '100.127.255.254',
        '127.0.0.1',
        '127.42.0.9',
        '169.254.10.20',
        '172.16.0.1',
        '172.31.255.254',
        '192.0.0.9',
        '192.0.2.1',
        '192.88.99.1',
        '192.168.50.1',
        '198.18.0.1',
        '198.19.255.254',
        '198.51.100.1',
        '203.0.113.1',
        '224.0.0.1',
        '239.255.255.250',
        '240.0.0.1',
        '255.255.255.255',
      ]) {
        expect(() => NetworkPrivacy.vlessAuthorityHost(value),
            throwsFormatException);
      }
    });

    test('rejects unsafe IPv6 transport endpoints', () {
      for (final value in [
        '::',
        '::1',
        '0:0:0:0:0:0:0:1',
        'fe80::1',
        'febf::1',
        'fc00::1',
        'fd00::1',
        'ff02::1',
        '100::1',
        '2001::1',
        '2001:2::1',
        '2001:10::1',
        '2001:20::1',
        '2001:db8::1',
        '2002::1',
        '3fff::1',
        '::ffff:127.0.0.1',
        '::ffff:169.254.10.20',
      ]) {
        expect(() => NetworkPrivacy.vlessAuthorityHost(value),
            throwsFormatException);
      }
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
        '2001:db8::1::2',
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
