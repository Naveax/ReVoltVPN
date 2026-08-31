import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/secure_socks_session.dart';

void main() {
  test('secure SOCKS session replaces unauthenticated proxy inbounds', () async {
    const baseConfig = '''
{
  "inbounds": [
    {
      "tag": "legacy-socks",
      "listen": "127.0.0.1",
      "port": 10807,
      "protocol": "socks",
      "settings": {"auth": "noauth", "udp": true}
    },
    {
      "tag": "legacy-http",
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "http"
    },
    {
      "tag": "non-proxy-inbound",
      "listen": "127.0.0.1",
      "port": 12000,
      "protocol": "dokodemo-door"
    }
  ],
  "outbounds": []
}
''';

    final first = await SecureSocksSession.create(baseConfig);
    final second = await SecureSocksSession.create(baseConfig);

    expect(first.port, greaterThan(1024));
    expect(first.port, lessThanOrEqualTo(65535));
    expect(first.username, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(first.password, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(second.username, isNot(first.username));
    expect(second.password, isNot(first.password));

    final decoded = jsonDecode(first.configJson) as Map<String, dynamic>;
    final inbounds = decoded['inbounds'] as List<dynamic>;

    expect(
      inbounds.where((value) => value['protocol'] == 'http'),
      isEmpty,
    );

    final socks = inbounds
        .cast<Map<String, dynamic>>()
        .singleWhere((value) => value['protocol'] == 'socks');
    expect(socks['tag'], SecureSocksSession.inboundTag);
    expect(socks['listen'], '127.0.0.1');
    expect(socks['port'], first.port);

    final settings = socks['settings'] as Map<String, dynamic>;
    expect(settings['auth'], 'password');
    expect(settings['ip'], '127.0.0.1');
    expect(settings.containsKey('accounts'), isFalse);

    final users = settings['users'] as List<dynamic>;
    expect(users, hasLength(1));
    expect(users.single['user'], first.username);
    expect(users.single['pass'], first.password);

    expect(
      inbounds.where((value) => value['protocol'] == 'dokodemo-door'),
      hasLength(1),
    );
  });
}
