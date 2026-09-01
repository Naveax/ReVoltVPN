import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/secure_socks_session.dart';

void main() {
  test('secure SOCKS session owns the entire inbound surface', () async {
    final session = await SecureSocksSession.create(jsonEncode({
      'inbounds': [
        {
          'tag': 'remote-listener',
          'listen': '0.0.0.0',
          'port': 9999,
          'protocol': 'dokodemo-door',
        },
        {
          'tag': 'old-http',
          'listen': '127.0.0.1',
          'port': 8080,
          'protocol': 'http',
        },
      ],
      'outbounds': [
        {'tag': 'proxy', 'protocol': 'freedom'}
      ],
    }));

    final decoded = jsonDecode(session.configJson) as Map<String, dynamic>;
    final inbounds = decoded['inbounds'] as List<dynamic>;
    expect(inbounds, hasLength(1));

    final inbound = inbounds.single as Map<String, dynamic>;
    expect(inbound['tag'], SecureSocksSession.inboundTag);
    expect(inbound['listen'], '127.0.0.1');
    expect(inbound['protocol'], 'socks');
    expect(inbound['port'], session.port);

    final settings = inbound['settings'] as Map<String, dynamic>;
    expect(settings['auth'], 'password');
    final users = settings['users'] as List<dynamic>;
    expect(users, hasLength(1));
    final account = users.single as Map<String, dynamic>;
    expect(account['user'], session.username);
    expect(account['pass'], session.password);
  });

  test('security patch keeps full-tunnel and private IPC invariants', () {
    final patch = File('tool/patch_flutter_vless_security_invariants.dart')
        .readAsStringSync();

    expect(patch, contains('builder.addRoute("0.0.0.0", 0)'));
    expect(patch, contains('builder.addRoute("::", 0)'));
    expect(patch, contains('ContextCompat.RECEIVER_NOT_EXPORTED'));
    expect(patch, contains('.setPackage(context.packageName)'));
    expect(patch, contains('android:value="false"'));
    expect(patch, contains('Android refused to establish VPN interface'));
    expect(patch, contains('Per-app VPN bypass is disabled in ReVolt'));
    expect(patch, contains('NotificationManager.IMPORTANCE_LOW'));
    expect(patch, contains('XRAY_SERVICE_CHANNEL'));
    expect(patch, contains("Queries Xray's stats API"));
    expect(patch, contains('stats helper end anchor missing'));
  });

  test('native app bridge does not advertise unsupported Always-on behavior', () {
    final source = File(
      'android/app/src/main/kotlin/com/paladinvpn/app/MainActivity.kt',
    ).readAsStringSync();

    expect(source, isNot(contains('openVpnSettings')));
    expect(source, isNot(contains('ACTION_VPN_SETTINGS')));
    expect(source, isNot(contains('FROM_DISCONNECT_BTN')));
    expect(source, contains('not proof of packet flow'));
  });

  test('configured AdMob bypass contract remains intact', () {
    final source = File('lib/logic/hivemind_service.dart').readAsStringSync();

    expect(source, contains('await _runConfiguredBypass(deviceId, nonce);'));
    expect(
      source,
      contains('/admob/callback?signature=test&key_id=test&custom_data='),
    );
    expect(
      source,
      contains('Validation bypass behavior is intentionally best-effort'),
    );
  });

  test('local SOCKS diagnostics cannot fall back to unauthenticated legacy mode', () {
    final source = File('lib/logic/local_socks_tester.dart').readAsStringSync();

    expect(source, contains('required int port'));
    expect(source, contains('required String username'));
    expect(source, contains('required String password'));
    expect(source, contains('const <int>[0x05, 0x01, 0x02]'));
    expect(source, isNot(contains('const <int>[0x05, 0x01, 0x00]')));
    expect(source, isNot(contains('int port = 10807')));
    expect(source, isNot(contains('paladinvpn.duckdns.org')));
    expect(source, contains("String targetHost = 'example.com'"));
  });

  test('hivemind rejects missing nonce and stale session responses', () {
    final source = File('lib/logic/hivemind_service.dart').readAsStringSync();

    expect(source, contains('_expectedNonce != nonce ||'));
    expect(source, contains('serverNonce is! String ||'));
    expect(
      source,
      contains(
        'final session = await _fetchActiveSession(deviceId, nonce);\n'
        '        _throwIfCancelled(callId);',
      ),
    );
  });

  test('hivemind validates session fields before constructing a VLESS URI', () {
    final source = File('lib/logic/hivemind_service.dart').readAsStringSync();

    expect(source, contains('_uuidPattern'));
    expect(source, contains("_requiredString(json, 'reality_pbk', maxLength: 128)"));
    expect(source, contains('_validatedHost('));
    expect(source, contains('return Uri('));
    expect(source, contains('queryParameters: <String, String>{'));
    expect(source, isNot(contains("return 'vless://\$uuid@\$host:\$port'")));
  });

  test('VPN connect work cannot outlive its generation', () {
    final source = File('lib/logic/vpn_connection.dart').readAsStringSync();

    expect(source, contains('int _connectEpoch = 0;'));
    expect(source, contains('final connectEpoch = ++_connectEpoch;'));
    expect(source, contains('epoch == _connectEpoch && !_userDisconnecting'));
    expect(source, contains('_connectEpoch++;\n    _suppressNativeConnect = true;'));
    expect(source, contains('if (_suppressNativeConnect || _userDisconnecting) return;'));
    expect(source, isNot(contains('bool _cancelled = false;')));
  });

  test('unsupported server picker is not wired into app state', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    final statusBar = File('lib/components/status_bar.dart').readAsStringSync();

    expect(mainSource, isNot(contains('ServerList')));
    expect(statusBar, isNot(contains('SelectionScreen')));
    expect(statusBar, contains('Helsinki, Finland'));
  });

  test('session timer rejects stale session work by generation', () {
    final source = File('lib/logic/session_timer.dart').readAsStringSync();

    expect(source, contains('_sessionEpoch'));
    expect(source, contains('Stopwatch'));
    expect(source, contains("_doDisconnect('VPN entered error state')"));
    expect(source, isNot(contains('_stopForVpnFailure')));
  });
}
