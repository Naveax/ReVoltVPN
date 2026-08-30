import 'dart:async';
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

  /// Fast local readiness probe used while starting the VPN.
  ///
  /// This deliberately stops after the SOCKS5 greeting. Startup must not fail
  /// just because an unrelated external test host is temporarily unreachable.
  static Future<LocalSocksTestResult> testListener({
    String host = '127.0.0.1',
    int port = 10807,
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

      socket.add(const <int>[0x05, 0x01, 0x00]);
      await socket.flush();
      final greeting = await reader.readExactly(
        2,
        timeout: const Duration(seconds: 1),
      );
      if (greeting[0] != 0x05 || greeting[1] != 0x00) {
        return const LocalSocksTestResult(
          ok: false,
          latencyMs: null,
          message: 'Local SOCKS5 listener rejected the handshake.',
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
        message: 'Local SOCKS5 is not listening on 127.0.0.1:10807.',
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

  /// Full user-facing test: local SOCKS handshake plus outbound CONNECT.
  static Future<LocalSocksTestResult> test({
    String host = '127.0.0.1',
    int port = 10807,
    String targetHost = 'paladinvpn.duckdns.org',
    int targetPort = 443,
  }) async {
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    _SocketReader? reader;

    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 3),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      reader = _SocketReader(socket);

      socket.add(const <int>[0x05, 0x01, 0x00]);
      await socket.flush();
      final greeting = await reader.readExactly(2);
      if (greeting[0] != 0x05 || greeting[1] != 0x00) {
        return const LocalSocksTestResult(
          ok: false,
          latencyMs: null,
          message: 'Local SOCKS5 listener rejected the handshake.',
        );
      }

      final hostBytes = targetHost.codeUnits;
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
          message: 'SOCKS5 is listening, but the ReVolt route could not reach the test target.',
        );
      }

      await _consumeAddress(reader, replyHead[3]);
      stopwatch.stop();
      return LocalSocksTestResult(
        ok: true,
        latencyMs: stopwatch.elapsedMilliseconds,
        message: 'Local SOCKS5 and the ReVolt outbound are reachable.',
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
        message: 'Local SOCKS5 is not listening on 127.0.0.1:10807.',
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

  static Future<void> _consumeAddress(_SocketReader reader, int addressType) async {
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
