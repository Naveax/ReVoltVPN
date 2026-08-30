import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';

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

final class _ProxyInfo {
  final String host;
  final int port;
  final String username;
  final String password;

  const _ProxyInfo(this.host, this.port, this.username, this.password);
}

abstract final class LocalSocksTester {
  LocalSocksTester._();

  static const MethodChannel _channel = MethodChannel('flutter_vless');

  static Future<_ProxyInfo> _proxyInfo() async {
    final raw = await _channel.invokeMapMethod<String, dynamic>(
      'getLocalProxyInfo',
    );
    final host = raw?['host'];
    final port = raw?['port'];
    final username = raw?['username'];
    final password = raw?['password'];
    if (host is! String ||
        port is! int ||
        username is! String ||
        password is! String ||
        username.isEmpty ||
        password.isEmpty ||
        port <= 0 ||
        port > 65535) {
      throw const StateError('Local SOCKS session information is unavailable.');
    }
    return _ProxyInfo(host, port, username, password);
  }

  static Future<void> _authenticate(
    Socket socket,
    _SocketReader reader,
    _ProxyInfo info,
  ) async {
    socket.add(const <int>[0x05, 0x01, 0x02]);
    await socket.flush();
    final greeting = await reader.readExactly(2);
    if (greeting[0] != 0x05 || greeting[1] != 0x02) {
      throw const FormatException('SOCKS5 password authentication was rejected.');
    }

    final user = info.username.codeUnits;
    final pass = info.password.codeUnits;
    if (user.isEmpty || user.length > 255 || pass.isEmpty || pass.length > 255) {
      throw const FormatException('Invalid SOCKS5 session credentials.');
    }
    socket.add(<int>[0x01, user.length, ...user, pass.length, ...pass]);
    await socket.flush();
    final auth = await reader.readExactly(2);
    if (auth[0] != 0x01 || auth[1] != 0x00) {
      throw const FormatException('SOCKS5 authentication failed.');
    }
  }

  /// Fast local readiness probe used while starting the VPN.
  static Future<LocalSocksTestResult> testListener() async {
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    _SocketReader? reader;

    try {
      final info = await _proxyInfo();
      socket = await Socket.connect(
        info.host,
        info.port,
        timeout: const Duration(seconds: 1),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      reader = _SocketReader(socket);
      await _authenticate(socket, reader, info);

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
    } on PlatformException {
      return const LocalSocksTestResult(
        ok: false,
        latencyMs: null,
        message: 'Local SOCKS5 session information is unavailable.',
      );
    } on SocketException {
      return const LocalSocksTestResult(
        ok: false,
        latencyMs: null,
        message: 'Local SOCKS5 session listener is not reachable.',
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

  /// Full user-facing test: authenticated local SOCKS plus outbound CONNECT.
  static Future<LocalSocksTestResult> test({
    String targetHost = 'paladinvpn.duckdns.org',
    int targetPort = 443,
  }) async {
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    _SocketReader? reader;

    try {
      final info = await _proxyInfo();
      socket = await Socket.connect(
        info.host,
        info.port,
        timeout: const Duration(seconds: 3),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      reader = _SocketReader(socket);
      await _authenticate(socket, reader, info);

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
    } on PlatformException {
      return const LocalSocksTestResult(
        ok: false,
        latencyMs: null,
        message: 'Local SOCKS5 session information is unavailable.',
      );
    } on SocketException {
      return const LocalSocksTestResult(
        ok: false,
        latencyMs: null,
        message: 'Local SOCKS5 session listener is not reachable.',
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
