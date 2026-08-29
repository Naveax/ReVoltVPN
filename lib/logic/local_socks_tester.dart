import 'dart:async';
import 'dart:io';

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

  static Future<LocalSocksTestResult> test({
    String host = '127.0.0.1',
    int port = 10807,
    String targetHost = 'paladinvpn.duckdns.org',
    int targetPort = 443,
  }) async {
    final stopwatch = Stopwatch()..start();
    Socket? socket;

    try {
      socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 3),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);

      socket.add(const <int>[0x05, 0x01, 0x00]);
      await socket.flush();
      final greeting = await _readExactly(socket, 2);
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

      final replyHead = await _readExactly(socket, 4);
      if (replyHead[0] != 0x05 || replyHead[1] != 0x00) {
        return LocalSocksTestResult(
          ok: false,
          latencyMs: null,
          message: 'SOCKS5 is listening, but the ReVolt route could not reach the test target.',
        );
      }

      await _consumeAddress(socket, replyHead[3]);
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
      await socket?.close();
    }
  }

  static Future<List<int>> _readExactly(Socket socket, int count) async {
    final bytes = <int>[];
    final completer = Completer<List<int>>();
    late StreamSubscription<List<int>> subscription;

    subscription = socket.listen(
      (chunk) {
        bytes.addAll(chunk);
        if (bytes.length >= count && !completer.isCompleted) {
          completer.complete(bytes.sublist(0, count));
          subscription.cancel();
        }
      },
      onError: (Object error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(const SocketException('Socket closed early'));
        }
      },
      cancelOnError: true,
    );

    return completer.future.timeout(const Duration(seconds: 4));
  }

  static Future<void> _consumeAddress(Socket socket, int addressType) async {
    switch (addressType) {
      case 0x01:
        await _readExactly(socket, 4 + 2);
      case 0x04:
        await _readExactly(socket, 16 + 2);
      case 0x03:
        final length = (await _readExactly(socket, 1)).first;
        await _readExactly(socket, length + 2);
      default:
        throw const FormatException('Unsupported SOCKS5 address type');
    }
  }
}
