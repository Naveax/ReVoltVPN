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
