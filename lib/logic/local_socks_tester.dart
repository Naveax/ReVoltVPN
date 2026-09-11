import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class LocalSocksTestResult {
  final bool ok;
  final int? latencyMs;
  final String message;

  const LocalSocksTestResult({
    required this.ok,
    required this.latencyMs,
    required this.message,
  });
}

abstract final class LocalSocksTester {
  LocalSocksTester._();

  /// Fast local readiness probe used while starting the VPN.
  ///
  /// This stops after authenticated SOCKS5 negotiation. Startup must not depend
  /// on an unrelated external host being reachable.
  static Future<LocalSocksTestResult> testListener({
    String host = '127.0.0.1',
    required int port,
    required String username,
    required String password,
  }) async {
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    _SocketReader? reader;

    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 1),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      reader = _SocketReader(socket);

      final authenticated = await _authenticate(
        reader,
        socket,
        username: username,
        password: password,
        timeout: const Duration(seconds: 1),
      );
      if (!authenticated) {
        return const LocalSocksTestResult(
          ok: false,
          latencyMs: null,
          message: 'Local SOCKS5 listener rejected authentication.',
        );
      }

      stopwatch.stop();
      return LocalSocksTestResult(
        ok: true,
        latencyMs: stopwatch.elapsedMilliseconds,
        message: 'Local SOCKS5 listener is ready.',
      );
    } on TimeoutException {
      return const LocalSocksTestResult(
        ok: false,
        latencyMs: null,
        message: 'Local SOCKS5 listener timed out.',
      );
    } on SocketException {
      return LocalSocksTestResult(
        ok: false,
        latencyMs: null,
        message: 'Local SOCKS5 is not listening on $host:$port.',
      );
    } catch (_) {
      return const LocalSocksTestResult(
        ok: false,
        latencyMs: null,
        message: 'Local SOCKS5 listener check failed.',
      );
    } finally {
      await reader?.close();
      await socket?.close();
    }
  }

  /// Full user-facing test. It proves both:
  /// 1. authenticated TCP CONNECT reaches an external target; and
  /// 2. RFC 1928 UDP ASSOCIATE carries an actual DNS datagram round-trip.
  ///
  /// The UDP leg matters for Discord voice/video and other real-time traffic.
  static Future<LocalSocksTestResult> test({
    String host = '127.0.0.1',
    required int port,
    required String username,
    required String password,
    String targetHost = 'example.com',
    int targetPort = 443,
  }) async {
    const totalTimeout = Duration(seconds: 10);
    final stopwatch = Stopwatch()..start();

    Duration remaining() {
      final micros = totalTimeout.inMicroseconds - stopwatch.elapsedMicroseconds;
      if (micros <= 0) {
        throw TimeoutException('SOCKS5 test timed out.', totalTimeout);
      }
      return Duration(microseconds: micros);
    }

    try {
      final tcpOk = await _testTcpConnect(
        host: host,
        port: port,
        username: username,
        password: password,
        targetHost: targetHost,
        targetPort: targetPort,
        timeout: remaining(),
      );
      if (!tcpOk) {
        return const LocalSocksTestResult(
          ok: false,
          latencyMs: null,
          message: 'SOCKS5 TCP route could not reach the test target.',
        );
      }

      final udpOk = await _testUdpDnsRoundTrip(
        host: host,
        port: port,
        username: username,
        password: password,
        timeout: remaining(),
      );
      if (!udpOk) {
        return const LocalSocksTestResult(
          ok: false,
          latencyMs: null,
          message: 'SOCKS5 TCP works, but UDP ASSOCIATE/data relay failed.',
        );
      }

      stopwatch.stop();
      return LocalSocksTestResult(
        ok: true,
        latencyMs: stopwatch.elapsedMilliseconds,
        message: 'Local SOCKS5 TCP and UDP routes are reachable.',
      );
    } on TimeoutException {
      return const LocalSocksTestResult(
        ok: false,
        latencyMs: null,
        message: 'Local SOCKS5 TCP/UDP test timed out.',
      );
    } on SocketException {
      return LocalSocksTestResult(
        ok: false,
        latencyMs: null,
        message: 'Local SOCKS5 is not listening on $host:$port.',
      );
    } catch (_) {
      return const LocalSocksTestResult(
        ok: false,
        latencyMs: null,
        message: 'Local SOCKS5 TCP/UDP test failed.',
      );
    }
  }

  static Future<bool> _testTcpConnect({
    required String host,
    required int port,
    required String username,
    required String password,
    required String targetHost,
    required int targetPort,
    required Duration timeout,
  }) async {
    if (targetPort <= 0 || targetPort > 65535) return false;
    final hostBytes = utf8.encode(targetHost);
    if (hostBytes.isEmpty || hostBytes.length > 255) return false;

    Socket? socket;
    _SocketReader? reader;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      socket.setOption(SocketOption.tcpNoDelay, true);
      reader = _SocketReader(socket);
      if (!await _authenticate(
        reader,
        socket,
        username: username,
        password: password,
        timeout: timeout,
      )) {
        return false;
      }

      socket.add(<int>[
        0x05,
        0x01, // CONNECT
        0x00,
        0x03,
        hostBytes.length,
        ...hostBytes,
        (targetPort >> 8) & 0xff,
        targetPort & 0xff,
      ]);
      await socket.flush();

      final replyHead = await reader.readExactly(4, timeout: timeout);
      if (replyHead[0] != 0x05 || replyHead[1] != 0x00) return false;
      await _readAddress(reader, replyHead[3], timeout: timeout);
      return true;
    } finally {
      await reader?.close();
      await socket?.close();
    }
  }

  static Future<bool> _testUdpDnsRoundTrip({
    required String host,
    required int port,
    required String username,
    required String password,
    required Duration timeout,
  }) async {
    Socket? control;
    _SocketReader? reader;
    RawDatagramSocket? udp;
    StreamSubscription<RawSocketEvent>? subscription;
    final response = Completer<bool>();

    try {
      control = await Socket.connect(host, port, timeout: timeout);
      control.setOption(SocketOption.tcpNoDelay, true);
      reader = _SocketReader(control);
      if (!await _authenticate(
        reader,
        control,
        username: username,
        password: password,
        timeout: timeout,
      )) {
        return false;
      }

      // UDP ASSOCIATE, client endpoint 0.0.0.0:0. The TCP control connection
      // remains open for the lifetime of the UDP association.
      control.add(const <int>[
        0x05,
        0x03,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
      ]);
      await control.flush();

      final replyHead = await reader.readExactly(4, timeout: timeout);
      if (replyHead[0] != 0x05 || replyHead[1] != 0x00) return false;
      final relay = await _readAddress(reader, replyHead[3], timeout: timeout);

      final relayAddress = await _resolveRelayAddress(relay.host, host, timeout);
      if (relay.port <= 0 || relay.port > 65535) return false;

      udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final random = Random.secure();
      final transactionId = random.nextInt(0x10000);
      final dnsQuery = _dnsQuery(transactionId);
      final packet = <int>[
        0x00,
        0x00, // RSV
        0x00, // FRAG: fragmentation unsupported by ReVolt test
        0x01, // IPv4 destination
        0x01,
        0x01,
        0x01,
        0x01, // 1.1.1.1
        0x00,
        0x35, // UDP/53
        ...dnsQuery,
      ];

      subscription = udp.listen((event) {
        if (event != RawSocketEvent.read || response.isCompleted) return;
        Datagram? datagram;
        while ((datagram = udp?.receive()) != null) {
          final data = datagram!.data;
          final payloadOffset = _socksUdpPayloadOffset(data);
          if (payloadOffset == null || data.length < payloadOffset + 2) continue;
          final id = (data[payloadOffset] << 8) | data[payloadOffset + 1];
          if (id == transactionId) response.complete(true);
        }
      });

      if (udp.send(packet, relayAddress, relay.port) != packet.length) {
        return false;
      }

      return await response.future.timeout(timeout, onTimeout: () => false);
    } finally {
      await subscription?.cancel();
      udp?.close();
      await reader?.close();
      await control?.close();
    }
  }

  static Future<InternetAddress> _resolveRelayAddress(
    String relayHost,
    String controlHost,
    Duration timeout,
  ) async {
    // RFC 1928 servers commonly answer 0.0.0.0 to mean the same interface on
    // which the control connection was accepted.
    if (relayHost == '0.0.0.0' || relayHost == '::') {
      return InternetAddress(controlHost);
    }
    final literal = InternetAddress.tryParse(relayHost);
    if (literal != null) return literal;
    final addresses = await InternetAddress.lookup(relayHost).timeout(timeout);
    final ipv4 = addresses.where((address) => address.type == InternetAddressType.IPv4);
    return ipv4.isNotEmpty ? ipv4.first : addresses.first;
  }

  static List<int> _dnsQuery(int transactionId) {
    // Standard recursive A query for example.com. No application data or user
    // destination is involved; this is only an outbound UDP capability probe.
    return <int>[
      (transactionId >> 8) & 0xff,
      transactionId & 0xff,
      0x01,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x07,
      ...ascii.encode('example'),
      0x03,
      ...ascii.encode('com'),
      0x00,
      0x00,
      0x01,
      0x00,
      0x01,
    ];
  }

  static int? _socksUdpPayloadOffset(Uint8List data) {
    if (data.length < 4 || data[0] != 0 || data[1] != 0 || data[2] != 0) {
      return null;
    }
    var offset = 4;
    switch (data[3]) {
      case 0x01:
        offset += 4;
        break;
      case 0x04:
        offset += 16;
        break;
      case 0x03:
        if (data.length <= offset) return null;
        final length = data[offset];
        offset += 1 + length;
        break;
      default:
        return null;
    }
    // Address is followed by two-byte destination port.
    offset += 2;
    return data.length >= offset ? offset : null;
  }

  static Future<bool> _authenticate(
    _SocketReader reader,
    Socket socket, {
    required String username,
    required String password,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final userBytes = utf8.encode(username);
    final passBytes = utf8.encode(password);
    if (userBytes.isEmpty ||
        passBytes.isEmpty ||
        userBytes.length > 255 ||
        passBytes.length > 255) {
      return false;
    }

    socket.add(const <int>[0x05, 0x01, 0x02]);
    await socket.flush();

    final greeting = await reader.readExactly(2, timeout: timeout);
    if (greeting[0] != 0x05 || greeting[1] != 0x02) return false;

    socket.add(<int>[
      0x01,
      userBytes.length,
      ...userBytes,
      passBytes.length,
      ...passBytes,
    ]);
    await socket.flush();

    final authReply = await reader.readExactly(2, timeout: timeout);
    return authReply[0] == 0x01 && authReply[1] == 0x00;
  }

  static Future<_SocksAddress> _readAddress(
    _SocketReader reader,
    int addressType, {
    required Duration timeout,
  }) async {
    late String host;
    if (addressType == 0x01) {
      final bytes = await reader.readExactly(4, timeout: timeout);
      host = bytes.join('.');
    } else if (addressType == 0x04) {
      final bytes = await reader.readExactly(16, timeout: timeout);
      host = InternetAddress.fromRawAddress(Uint8List.fromList(bytes)).address;
    } else if (addressType == 0x03) {
      final length = (await reader.readExactly(1, timeout: timeout)).first;
      if (length == 0) throw const FormatException('Invalid SOCKS5 domain length');
      host = utf8.decode(await reader.readExactly(length, timeout: timeout));
    } else {
      throw const FormatException('Unsupported SOCKS5 address type');
    }

    final portBytes = await reader.readExactly(2, timeout: timeout);
    return _SocksAddress(
      host,
      (portBytes[0] << 8) | portBytes[1],
    );
  }
}

class _SocksAddress {
  final String host;
  final int port;

  const _SocksAddress(this.host, this.port);
}

class _SocketReader {
  final StreamIterator<Uint8List> _iterator;
  final List<int> _buffer = <int>[];

  _SocketReader(Socket socket) : _iterator = StreamIterator<Uint8List>(socket);

  Future<List<int>> readExactly(
    int count, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final elapsed = Stopwatch()..start();
    while (_buffer.length < count) {
      final remainingMicros = timeout.inMicroseconds - elapsed.elapsedMicroseconds;
      if (remainingMicros <= 0) {
        throw TimeoutException('Socket read timed out', timeout);
      }
      final hasNext = await _iterator.moveNext().timeout(
            Duration(microseconds: remainingMicros),
          );
      if (!hasNext) throw const SocketException('Socket closed early');
      _buffer.addAll(_iterator.current);
    }

    final result = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return result;
  }

  Future<void> close() => _iterator.cancel();
}
