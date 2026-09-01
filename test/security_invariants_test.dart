import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/power_settings.dart';
import 'package:revoltvpn/logic/secure_socks_session.dart';

void main() {
  group('SecureSocksSession', () {
    test('replaces every imported inbound with one authenticated loopback SOCKS5', () async {
      final session = await SecureSocksSession.create(jsonEncode({
        'inbounds': [
          {
            'tag': 'malicious-socks',
            'listen': '0.0.0.0',
            'port': 1080,
            'protocol': 'socks',
            'settings': {'auth': 'noauth'},
          },
          {
            'tag': 'malicious-http',
            'listen': '0.0.0.0',
            'port': 8080,
            'protocol': 'http',
          },
          {
            'tag': 'malicious-door',
            'listen': '0.0.0.0',
            'port': 9000,
            'protocol': 'dokodemo-door',
          },
        ],
        'outbounds': [
          {'protocol': 'freedom', 'tag': 'direct'},
        ],
      }));

      final decoded = jsonDecode(session.configJson) as Map<String, dynamic>;
      final inbounds = decoded['inbounds'] as List<dynamic>;
      expect(inbounds, hasLength(1));

      final inbound = inbounds.single as Map<String, dynamic>;
      expect(inbound['tag'], SecureSocksSession.inboundTag);
      expect(inbound['listen'], '127.0.0.1');
      expect(inbound['protocol'], 'socks');
      expect(inbound['port'], session.port);
      expect(session.port, inInclusiveRange(1025, 65535));

      final settings = inbound['settings'] as Map<String, dynamic>;
      expect(settings['auth'], 'password');
      expect(settings['udp'], isTrue);
      final users = settings['users'] as List<dynamic>;
      final account = users.single as Map<String, dynamic>;
      expect(account['user'], session.username);
      expect(account['pass'], session.password);
      expect(session.username, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(session.password, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('uses fresh credentials for separate sessions', () async {
      final first = await SecureSocksSession.create('{}');
      final second = await SecureSocksSession.create('{}');

      expect(second.username, isNot(first.username));
      expect(second.password, isNot(first.password));
    });
  });

  group('VpnRuntimeState.aliveFor', () {
    VpnRuntimeState state({
      bool processAlive = true,
      bool vpnTransport = true,
      bool healthy = true,
      bool stale = false,
      bool proxyOnly = false,
      bool xrayAlive = true,
      bool tun2socksAlive = true,
      bool fdReady = true,
      bool outboundReady = true,
    }) {
      return VpnRuntimeState(
        processAlive: processAlive,
        vpnTransport: vpnTransport,
        healthy: healthy,
        stale: stale,
        proxyOnly: proxyOnly,
        xrayAlive: xrayAlive,
        tun2socksAlive: tun2socksAlive,
        fdReady: fdReady,
        outboundReady: outboundReady,
      );
    }

    test('accepts only a complete TUN runtime', () {
      expect(state().aliveFor(tunMode: true), isTrue);
      expect(state(processAlive: false).aliveFor(tunMode: true), isFalse);
      expect(state(vpnTransport: false).aliveFor(tunMode: true), isFalse);
      expect(state(stale: true).aliveFor(tunMode: true), isFalse);
      expect(state(healthy: false).aliveFor(tunMode: true), isFalse);
      expect(state(xrayAlive: false).aliveFor(tunMode: true), isFalse);
      expect(state(tun2socksAlive: false).aliveFor(tunMode: true), isFalse);
      expect(state(fdReady: false).aliveFor(tunMode: true), isFalse);
      expect(state(outboundReady: false).aliveFor(tunMode: true), isFalse);
      expect(state(proxyOnly: true).aliveFor(tunMode: true), isFalse);
    });

    test('proxy mode ignores TUN-only signals but still requires Xray outbound', () {
      final proxy = state(
        vpnTransport: false,
        proxyOnly: true,
        tun2socksAlive: false,
        fdReady: false,
      );
      expect(proxy.aliveFor(tunMode: false), isTrue);
      expect(
        state(
          vpnTransport: false,
          proxyOnly: true,
          tun2socksAlive: false,
          fdReady: false,
          outboundReady: false,
        ).aliveFor(tunMode: false),
        isFalse,
      );
      expect(
        state(
          vpnTransport: false,
          proxyOnly: true,
          tun2socksAlive: false,
          fdReady: false,
          xrayAlive: false,
        ).aliveFor(tunMode: false),
        isFalse,
      );
    });
  });
}
