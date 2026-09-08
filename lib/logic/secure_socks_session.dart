import 'dart:convert';
import 'dart:math';

class SecureSocksSession {
  static const String inboundTag = 'revolt-secure-socks';
  static final Random _random = Random.secure();
  static const int _minimumPort = 1025;
  static const int _maximumPort = 65535;

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

    // Do not probe a port with bind(0) and then release it before Xray starts.
    // That check/use split creates a real ownership race and also exposes which
    // port the client intends to use. Xray is the first process to bind the
    // CSPRNG-selected candidate. Ordinary collision is handled by the bounded
    // runtime retry in VpnConnection rather than pretending a released socket
    // is a reservation.
    final port = _candidatePort();
    final username = _token(16);
    final password = _token(32);

    // ReVolt owns local ingress. Never accept listeners supplied by a remote
    // or imported Xray config; the client exposes exactly one authenticated
    // loopback SOCKS5 listener for the current ephemeral session.
    decoded['inbounds'] = <Map<String, dynamic>>[
      <String, dynamic>{
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
      },
    ];

    return SecureSocksSession._(
      port: port,
      username: username,
      password: password,
      configJson: jsonEncode(decoded),
    );
  }

  static int _candidatePort() =>
      _minimumPort + _random.nextInt(_maximumPort - _minimumPort + 1);

  static String _token(int byteCount) {
    if (byteCount <= 0) {
      throw ArgumentError.value(byteCount, 'byteCount', 'must be positive');
    }
    final bytes = List<int>.generate(byteCount, (_) => _random.nextInt(256));
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}
