import 'dart:convert';
import 'dart:io';
import 'dart:math';

class SecureSocksSession {
  static const String inboundTag = 'revolt-secure-socks';
  static final Random _random = Random.secure();

  final int port;
  final String username;
  final String password;
  final String configJson;

  const SecureSocksSession._({
    required this.port,
    required this.username,
    required this.password,
    required this.configJson,
  });

  static Future<SecureSocksSession> create(String baseConfig) async {
    final decoded = jsonDecode(baseConfig);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('VLESS configuration must be a JSON object.');
    }

    final reservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    final port = reservation.port;
    await reservation.close();

    if (port <= 1024 || port > 65535) {
      throw StateError('Could not allocate a safe local SOCKS5 port.');
    }

    final username = _token(16);
    final password = _token(32);

    // ReVolt owns every client-side Android ingress. Server-provided inbounds
    // are intentionally discarded rather than filtered by protocol: accepting
    // an imported dokodemo-door, transparent proxy, API listener, or future
    // inbound type could expose an unexpected local/network listener. The only
    // ingress allowed into the runtime is the authenticated loopback SOCKS5
    // listener created below.
    final inbounds = <dynamic>[];

    inbounds.add(<String, dynamic>{
      'tag': inboundTag,
      'port': port,
      'listen': '127.0.0.1',
      'protocol': 'socks',
      'settings': <String, dynamic>{
        'auth': 'password',
        'udp': true,
        'ip': '127.0.0.1',
        'users': <Map<String, String>>[
          <String, String>{'user': username, 'pass': password},
        ],
      },
      'sniffing': <String, dynamic>{
        'enabled': true,
        'destOverride': <String>['http', 'tls'],
      },
    });
    decoded['inbounds'] = inbounds;

    return SecureSocksSession._(
      port: port,
      username: username,
      password: password,
      configJson: jsonEncode(decoded),
    );
  }

  static String _token(int byteCount) {
    final bytes = List<int>.generate(byteCount, (_) => _random.nextInt(256));
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}
