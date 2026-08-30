import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

  static Future<LocalSocksTestResult> testListener({
    String host = '127.0.0.1',
    required int port,
    String username = '',
    String password = '',
  }) async {
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    _SocketReader? reader;

    try {
      if (port <= 0) {
        return const LocalSocksTestResult(
          ok: false,
          latencyMs: null,
          message: 'Local SOCKS5 session is not ready.',
        );
      }
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 1),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      reader = _SocketReader(socket);

      if (!await _authenticate(
        socket,
        reader,
        username: username,
        password: password,
        timeout: const Duration(seconds: 1),
      )) {
        return const LocalSocksTestResult(
          ok: false,
          latencyMs: null,
          message: 'Local SOCKS5 authentication failed.',
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
      return const LocalSocksTestResult(
        ok: false,
        latencyMs: null,
        message: 'Local SOCKS5 session is not listening.',
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

  /// Full user-facing test: authenticated local SOCKS handshake plus outbound
  /// CONNECT. It verifies the Xray egress; native TUN/FD readiness is checked
  /// separately by NativeTunnelControl before the VPN may show Secured.
  static Future<LocalSocksTestResult> test({
    String host = '127.0.0.1',
    required int port,
    String username = '',
    String password = '',
    String targetHost = 'paladinvpn.duckdns.org',
    int targetPort = 443,
  }) async {
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    _SocketReader? reader;

    try {
      if (port <= 0) {
        return const LocalSocksTestResult(
          ok: false,
          latencyMs: null,
          message: 'Local SOCKS5 session is not ready.',
        );
      }
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 3),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      reader = _SocketReader(socket);

      if (!await _authenticate(
        socket,
        reader,
        username: username,
        password: password,
      )) {
        return const LocalSocksTestResult(
          ok: false,
          latencyMs: null,
          message: 'Local SOCKS5 authentication failed.',
        );
      }

      final hostBytes = utf8.encode(targetHost);
      if (hostBytes.length > 255) {
        return const LocalSocksTestResult(
          ok: false,
          latencyMs: null,
          message: 'SOCKS5 test target is invalid.',
        );
      }

      socket.add(<int>[
        0x05,
        0x01,
        0x00,
        0x03,
        hostBytes.length,
        ...hostBytes,
        (targetPort >> 8) & 0xff,
        targetPort & 0xff,
      ]);
      await socket.flush();

      final replyHead = await reader.readExactly(4);
      if (replyHead[0] != 0x05 || replyHead[1] != 0x00) {
        return const LocalSocksTestResult(
          ok: false,
          latencyMs: null,
          message: 'SOCKS5 is ready, but the ReVolt outbound could not reach the test target.',
        );
      }

      await _consumeAddress(reader, replyHead[3]);
      stopwatch.stop();
      return LocalSocksTestResult(
        ok: true,
        latencyMs: stopwatch.elapsedMilliseconds,
        message: 'Authenticated Local SOCKS5 and the ReVolt outbound are reachable.',
      );
    } on TimeoutException {
      return const LocalSocksTestResult(
        ok: false,
        latencyMs: null,
        message: 'Local SOCKS5 test timed out.',
      );
    } on SocketException {
      return const LocalSocksTestResult(
        ok: false,
        latencyMs: null,
        message: 'Local SOCKS5 session is not listening.',
      );
    } catch (_) {
      return const LocalSocksTestResult(
        ok: false,
        latencyMs: null,
        message: 'Local SOCKS5 test failed.',
      );
    } finally {
      await reader?.close();
      await socket?.close();
    }
  }

  static Future<bool> _authenticate(
    Socket socket,
    _SocketReader reader, {
    required String username,
    required String password,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final usePassword = username.isNotEmpty;
    socket.add(<int>[0x05, 0x01, usePassword ? 0x02 : 0x00]);
    await socket.flush();
    final greeting = await reader.readExactly(2, timeout: timeout);
    if (greeting[0] != 0x05 || greeting[1] != (usePassword ? 0x02 : 0x00)) {
      return false;
    }
    if (!usePassword) return true;

    final userBytes = utf8.encode(username);
    final passBytes = utf8.encode(password);
    if (userBytes.isEmpty ||
        userBytes.length > 255 ||
        passBytes.length > 255) {
      return false;
    }
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

  static Future<void> _consumeAddress(
    _SocketReader reader,
    int addressType,
  ) async {
    if (addressType == 0x01) {
      await reader.readExactly(4 + 2);
      return;
    }
    if (addressType == 0x04) {
      await reader.readExactly(16 + 2);
      return;
    }
    if (addressType == 0x03) {
      final length = (await reader.readExactly(1)).first;
      await reader.readExactly(length + 2);
      return;
    }
    throw const FormatException('Unsupported SOCKS5 address type');
  }
}

class _SocketReader {
  final StreamIterator<Uint8List> _iterator;
  final List<int> _buffer = <int>[];

  _SocketReader(Socket socket) : _iterator = StreamIterator<Uint8List>(socket);

  Future<List<int>> readExactly(
    int count, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    while (_buffer.length < count) {
      final hasNext = await _iterator.moveNext().timeout(timeout);
      if (!hasNext) {
        throw const SocketException('Socket closed early');
      }
      _buffer.addAll(_iterator.current);
    }

    final result = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return result;
  }

  Future<void> close() => _iterator.cancel();
}
