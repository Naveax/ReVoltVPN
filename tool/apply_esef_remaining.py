from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected one marker, found {count}: {old[:80]!r}')
    p.write_text(text.replace(old, new, 1))


def remove_once(path: str, old: str) -> None:
    replace_once(path, old, '')


remove_once(
    'android/app/build.gradle.kts',
    '    packaging {\n        resources.excludes.add("META-INF/**")\n    }\n\n',
)
Path('.github/workflows/vendor-flutter-vless.yml').unlink(missing_ok=False)

remove_once('android/app/src/main/kotlin/com/paladinvpn/app/MainActivity.kt', 'import android.app.ActivityManager\n')
remove_once(
    'android/app/src/main/kotlin/com/paladinvpn/app/MainActivity.kt',
    '''    /**
     * Notification-only process liveness guard.
     *
     * Runtime adoption is driven by the private flutter_vless status heartbeat;
     * this check only prevents this activity process from posting notification
     * updates after the foreground-service process has disappeared.
     */
    private fun isVpnServiceProcessAlive(): Boolean {
        return try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val expectedProcessName = "$packageName$VPN_PROCESS_SUFFIX"
            am.runningAppProcesses
                ?.any { it.processName == expectedProcessName } == true
        } catch (_: Exception) {
            false
        }
    }

    /** Removes a notification left behind by a runtime that is no longer alive. */
    private fun cancelVpnNotification() {
        try {
            NotificationManagerCompat.from(this).cancel(NOTIFICATION_ID)
        } catch (_: Exception) {
        }
    }

''',
)
remove_once(
    'android/app/src/main/kotlin/com/paladinvpn/app/MainActivity.kt',
    '''        // The foreground notification (id 1) is owned by XrayVPNService via
        // startForeground. Posting to it from this process while the service is
        // gone leaves a frozen countdown nothing will ever update again.
        if (!isVpnServiceProcessAlive()) {
            cancelVpnNotification()
            return
        }

''',
)
remove_once('android/app/src/main/kotlin/com/paladinvpn/app/MainActivity.kt', '        private const val VPN_PROCESS_SUFFIX = ":RunSoLibXrayDaemon"\n')

replace_once(
    'lib/logic/connection_settings.dart',
    '''    if (storedMode != _mode.name) {
      await prefs.setString(_modeKey, _mode.name);
    }

    _initialized = true;
''',
    '''    if (storedMode != _mode.name) {
      final migrated = await prefs.setString(_modeKey, _mode.name);
      if (!migrated) {
        throw StateError('Could not persist migrated connection mode.');
      }
    }

    _initialized = true;
''',
)

replace_once('lib/logic/hivemind_service.dart', "  static const _pollBackoff = <Duration>[\n", "  static const int _maxControlResponseBytes = 256 * 1024;\n  static const _pollBackoff = <Duration>[\n")
replace_once(
    'lib/logic/hivemind_service.dart',
    '''  static Future<http.Response> directGet(
    Uri uri, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    return http.get(uri, headers: {'User-Agent': _ua}).timeout(timeout);
  }

''',
    '''  static Future<http.Response> directGet(
    Uri uri, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    return http.get(uri, headers: {'User-Agent': _ua}).timeout(timeout);
  }

  static Future<http.Response> controlGet(
    Uri uri, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final client = http.Client();
    final request = http.Request('GET', uri)..headers['User-Agent'] = _ua;

    Future<http.Response> read() async {
      final streamed = await client.send(request);
      final declaredLength = streamed.contentLength;
      if (declaredLength != null && declaredLength > _maxControlResponseBytes) {
        throw const FormatException('Control response is too large.');
      }

      final bytes = <int>[];
      await for (final chunk in streamed.stream) {
        if (bytes.length + chunk.length > _maxControlResponseBytes) {
          throw const FormatException('Control response is too large.');
        }
        bytes.addAll(chunk);
      }

      return http.Response.bytes(
        bytes,
        streamed.statusCode,
        headers: streamed.headers,
        isRedirect: streamed.isRedirect,
        persistentConnection: streamed.persistentConnection,
        reasonPhrase: streamed.reasonPhrase,
        request: request,
      );
    }

    try {
      return await read().timeout(
        timeout,
        onTimeout: () {
          client.close();
          throw TimeoutException('Control request timed out.', timeout);
        },
      );
    } finally {
      client.close();
    }
  }

''',
)
replace_once('lib/logic/hivemind_service.dart', "      final response = await directGet(\n        _publicUrl('/health'),\n        timeout: const Duration(seconds: 3),\n      );\n", "      final response = await controlGet(\n        _publicUrl('/health'),\n        timeout: const Duration(seconds: 3),\n      );\n")
replace_once('lib/logic/hivemind_service.dart', '    final response = await directGet(statusUri);\n', '    final response = await controlGet(statusUri);\n')
replace_once('lib/logic/session_timer.dart', '      final response = await HivemindService.directGet(url);\n', '      final response = await HivemindService.controlGet(url);\n')
replace_once('lib/logic/hivemind_service.dart', "    final pinnedHost = _validatedHost(AppConfig.serverIp, 'serverIp');\n", "    final pinnedHost = _validatedPublicIp(AppConfig.serverIp, 'serverIp');\n")
replace_once(
    'lib/logic/hivemind_service.dart',
    "    final port = _portOr(json['vless_port'], 443);\n",
    "    final advertisedPort = json['vless_port'];\n    if (advertisedPort != null &&\n        (advertisedPort is! num || advertisedPort.toInt() != 443)) {\n      throw const FormatException('Session VLESS port does not match compiled pin');\n    }\n    const port = 443;\n",
)
replace_once(
    'lib/logic/hivemind_service.dart',
    '''  static int _portOr(Object? value, int fallback) {
    final parsed = value is num ? value.toInt() : fallback;
    if (parsed <= 0 || parsed > 65535) {
      throw const FormatException('Invalid VLESS port');
    }
    return parsed;
  }
''',
    '''  static String _validatedPublicIp(String input, String field) {
    final value = input.trim().toLowerCase();
    if (_isPublicIpv4(value) || _isPublicIpv6(value)) return value;
    throw FormatException('Invalid public IP pin: $field');
  }

  static bool _isPublicIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;
    final octets = <int>[];
    for (final part in parts) {
      if (part.isEmpty || (part.length > 1 && part.startsWith('0'))) return false;
      final parsed = int.tryParse(part);
      if (parsed == null || parsed < 0 || parsed > 255) return false;
      octets.add(parsed);
    }
    final a = octets[0];
    final b = octets[1];
    if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
    if (a == 100 && b >= 64 && b <= 127) return false;
    if (a == 169 && b == 254) return false;
    if (a == 172 && b >= 16 && b <= 31) return false;
    if (a == 192 && b == 168) return false;
    if (a == 192 && b == 0 && octets[2] == 2) return false;
    if (a == 198 && b == 51 && octets[2] == 100) return false;
    if (a == 203 && b == 0 && octets[2] == 113) return false;
    return true;
  }

  static bool _isPublicIpv6(String value) {
    if (!value.contains(':') || value.contains('.')) return false;
    try {
      final parsed = Uri.parse('https://[$value]/');
      if (parsed.host.isEmpty || !parsed.host.contains(':')) return false;
    } on FormatException {
      return false;
    }
    if (value == '::' || value == '::1') return false;
    if (value.startsWith('fc') || value.startsWith('fd')) return false;
    if (value.startsWith('fe8') || value.startsWith('fe9') || value.startsWith('fea') || value.startsWith('feb')) return false;
    if (value.startsWith('ff')) return false;
    if (value.startsWith('2001:db8:') || value == '2001:db8::') return false;
    return true;
  }
''',
)

replace_once(
    'lib/logic/local_socks_tester.dart',
    '''  }) async {
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    _SocketReader? reader;

    try {
      if (targetPort <= 0 || targetPort > 65535) {
''',
    '''  }) async {
    const totalTimeout = Duration(seconds: 8);
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    _SocketReader? reader;

    Duration remaining() {
      final micros = totalTimeout.inMicroseconds - stopwatch.elapsedMicroseconds;
      if (micros <= 0) throw TimeoutException('SOCKS5 test timed out.', totalTimeout);
      return Duration(microseconds: micros);
    }

    try {
      if (targetPort <= 0 || targetPort > 65535) {
''',
)
replace_once('lib/logic/local_socks_tester.dart', "      socket = await Socket.connect(\n        host,\n        port,\n        timeout: const Duration(seconds: 3),\n      );\n", "      socket = await Socket.connect(\n        host,\n        port,\n        timeout: remaining(),\n      );\n")
replace_once('lib/logic/local_socks_tester.dart', "      final authenticated = await _authenticate(\n        reader,\n        socket,\n        username: username,\n        password: password,\n      );\n", "      final authenticated = await _authenticate(\n        reader,\n        socket,\n        username: username,\n        password: password,\n        timeout: remaining(),\n      );\n")
replace_once('lib/logic/local_socks_tester.dart', '      final replyHead = await reader.readExactly(4);\n', '      final replyHead = await reader.readExactly(4, timeout: remaining());\n')
replace_once('lib/logic/local_socks_tester.dart', '      await _consumeAddress(reader, replyHead[3]);\n', '      await _consumeAddress(reader, replyHead[3], timeout: remaining());\n')
replace_once('lib/logic/local_socks_tester.dart', "  static Future<void> _consumeAddress(\n    _SocketReader reader,\n    int addressType,\n  ) async {\n", "  static Future<void> _consumeAddress(\n    _SocketReader reader,\n    int addressType, {\n    required Duration timeout,\n  }) async {\n")
replace_once('lib/logic/local_socks_tester.dart', '      await reader.readExactly(4 + 2);\n', '      await reader.readExactly(4 + 2, timeout: timeout);\n')
replace_once('lib/logic/local_socks_tester.dart', '      await reader.readExactly(16 + 2);\n', '      await reader.readExactly(16 + 2, timeout: timeout);\n')
replace_once('lib/logic/local_socks_tester.dart', '      final length = (await reader.readExactly(1)).first;\n', '      final length = (await reader.readExactly(1, timeout: timeout)).first;\n')
replace_once('lib/logic/local_socks_tester.dart', '      await reader.readExactly(length + 2);\n', '      await reader.readExactly(length + 2, timeout: timeout);\n')

replace_once('test/security_regression_test.dart', "    expect(source, contains('isVpnServiceProcessAlive'));\n", "    expect(source, isNot(contains('isVpnServiceProcessAlive')));\n")
replace_once('test/security_regression_test.dart', "    expect(source, contains(\"String targetHost = 'example.com'\"));\n", "    expect(source, contains(\"String targetHost = 'example.com'\"));\n    expect(source, contains('const totalTimeout = Duration(seconds: 8);'));\n")
replace_once('test/security_regression_test.dart', "    expect(source, contains('_uuidPattern'));\n", "    expect(source, contains('_uuidPattern'));\n    expect(source, contains('_maxControlResponseBytes = 256 * 1024'));\n    expect(source, contains('controlGet('));\n    expect(source, contains('_validatedPublicIp(AppConfig.serverIp'));\n    expect(source, contains('const port = 443;'));\n")

# One-shot patch machinery deletes itself from the resulting commit.
Path('tool/apply_esef_remaining.py').unlink(missing_ok=False)
Path('.github/workflows/apply-esef-remaining.yml').unlink(missing_ok=False)
print('ESEF remaining hardening patch applied successfully.')
