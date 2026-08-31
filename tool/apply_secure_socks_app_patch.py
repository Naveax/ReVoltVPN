from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"[secure-socks app patch] missing expected block: {label}")
    return text.replace(old, new, 1)


vpn_path = Path('lib/logic/vpn_connection.dart')
vpn = vpn_path.read_text()

vpn = replace_once(
    vpn,
    "import 'package:revoltvpn/logic/network_monitor.dart';\n",
    "import 'package:revoltvpn/logic/network_monitor.dart';\n"
    "import 'package:revoltvpn/logic/secure_socks_session.dart';\n",
    'secure socks import',
)

vpn = replace_once(
    vpn,
    "  bool _lastVerifyLocalSocks = false;\n",
    "  bool _lastVerifyLocalSocks = false;\n"
    "  SecureSocksSession? _lastSecureSocks;\n",
    'secure socks runtime snapshot',
)

vpn = replace_once(
    vpn,
    "      final baseConfig = parsed.getFullConfiguration();\n"
    "      final remark = parsed.remark.isNotEmpty ? parsed.remark : 'Revolt VPN';\n",
    "      final baseConfig = parsed.getFullConfiguration();\n"
    "      final remark = parsed.remark.isNotEmpty ? parsed.remark : 'Revolt VPN';\n"
    "      final secureSocks = await SecureSocksSession.create(baseConfig);\n",
    'secure session creation',
)

vpn = replace_once(
    vpn,
    "      await _startRuntime(\n"
    "        config: baseConfig,\n"
    "        remark: remark,\n"
    "        blockedApps: routingPlan.blockedApps,\n"
    "      );\n",
    "      await _startRuntime(\n"
    "        config: secureSocks.configJson,\n"
    "        remark: remark,\n"
    "        blockedApps: routingPlan.blockedApps,\n"
    "      );\n",
    'secure runtime config',
)

vpn = replace_once(
    vpn,
    "        if (!await _waitForLocalSocksListener()) {\n",
    "        if (!await _waitForLocalSocksListener(secureSocks)) {\n",
    'authenticated startup probe',
)

vpn = replace_once(
    vpn,
    "      _lastBaseConfig = baseConfig;\n"
    "      _lastRemark = remark;\n",
    "      _lastBaseConfig = secureSocks.configJson;\n"
    "      _lastSecureSocks = secureSocks;\n"
    "      _lastRemark = remark;\n",
    'secure snapshot persistence',
)

old_wait = """  Future<bool> _waitForLocalSocksListener() async {
    for (var attempt = 0; attempt < 4; attempt++) {
      final result = await LocalSocksTester.testListener();
      if (result.ok) {
        _lastHealthLatencyMs = result.latencyMs;
        notifyListeners();
        return true;
      }
      if (attempt < 3) {
        await Future.delayed(const Duration(milliseconds: 250));
      }
    }
    return false;
  }
"""
new_wait = """  Future<bool> _waitForLocalSocksListener([
    SecureSocksSession? session,
  ]) async {
    final active = session ?? _lastSecureSocks;
    if (active == null) return false;

    for (var attempt = 0; attempt < 4; attempt++) {
      final result = await LocalSocksTester.testListener(
        host: '127.0.0.1',
        port: active.port,
        username: active.username,
        password: active.password,
      );
      if (result.ok) {
        _lastHealthLatencyMs = result.latencyMs;
        notifyListeners();
        return true;
      }
      if (attempt < 3) {
        await Future.delayed(const Duration(milliseconds: 250));
      }
    }
    return false;
  }
"""
vpn = replace_once(vpn, old_wait, new_wait, 'authenticated local SOCKS probe')

vpn = replace_once(
    vpn,
    "    _lastVerifyLocalSocks = false;\n"
    "    _selectedRoutingActive = false;\n",
    "    _lastVerifyLocalSocks = false;\n"
    "    _lastSecureSocks = null;\n"
    "    _selectedRoutingActive = false;\n",
    'clear secure SOCKS snapshot',
)

old_dispose = """  @override
  void dispose() {
    _healthTimer?.cancel();
    _restartTimer?.cancel();
    _networkSubscription?.cancel();
    if (_status == VpnStatus.connected || _status == VpnStatus.connecting) {
      try {
        _vless.stopVless();
      } catch (_) {}
    }
    super.dispose();
  }
"""
new_dispose = """  @override
  void dispose() {
    _healthTimer?.cancel();
    _restartTimer?.cancel();
    _networkSubscription?.cancel();
    // Provider/UI disposal is not a user disconnect command. Keeping teardown
    // in disconnect() prevents lifecycle churn from silently dropping the VPN.
    super.dispose();
  }
"""
vpn = replace_once(vpn, old_dispose, new_dispose, 'dispose must not stop VPN')
vpn_path.write_text(vpn)

local_path = Path('lib/logic/local_socks_tester.dart')
local_path.write_text(r'''import 'dart:async';
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

  /// Fast local readiness probe used while starting the VPN.
  ///
  /// This stops after SOCKS5 authentication. Startup must not depend on an
  /// unrelated external host being reachable.
  static Future<LocalSocksTestResult> testListener({
    String host = '127.0.0.1',
    int port = 10807,
    String? username,
    String? password,
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

  /// Full user-facing test: authenticated local SOCKS handshake plus outbound
  /// CONNECT. Credentials are optional so the helper remains usable for legacy
  /// no-auth diagnostic builds.
  static Future<LocalSocksTestResult> test({
    String host = '127.0.0.1',
    int port = 10807,
    String? username,
    String? password,
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

      final authenticated = await _authenticate(
        reader,
        socket,
        username: username,
        password: password,
      );
      if (!authenticated) {
        return const LocalSocksTestResult(
          ok: false,
          latencyMs: null,
          message: 'Local SOCKS5 listener rejected authentication.',
        );
      }

      final hostBytes = utf8.encode(targetHost);
      if (hostBytes.isEmpty || hostBytes.length > 255) {
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
      return LocalSocksTestResult(
        ok: false,
        latencyMs: null,
        message: 'Local SOCKS5 is not listening on $host:$port.',
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
    _SocketReader reader,
    Socket socket, {
    required String? username,
    required String? password,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final passwordAuth = username != null && password != null;
    if ((username == null) != (password == null)) return false;

    socket.add(passwordAuth
        ? const <int>[0x05, 0x01, 0x02]
        : const <int>[0x05, 0x01, 0x00]);
    await socket.flush();

    final greeting = await reader.readExactly(2, timeout: timeout);
    if (greeting[0] != 0x05) return false;
    if (!passwordAuth) return greeting[1] == 0x00;
    if (greeting[1] != 0x02) return false;

    final userBytes = utf8.encode(username);
    final passBytes = utf8.encode(password);
    if (userBytes.isEmpty ||
        passBytes.isEmpty ||
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
''')

print('[secure-socks app patch] application sources are ready')
