import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stock runtime patch validates the current SOCKS5 users schema', () {
    final source = File(
      'tool/patch_flutter_vless_secure_socks_v2.dart',
    ).readAsStringSync();

    expect(source, contains('settings.optJSONArray("users")'));
    expect(source, contains('settings.optString("auth") != "password"'));
    expect(source, contains('inbound.optString("listen") != "127.0.0.1"'));
    expect(source, contains('account.optString("user").isEmpty()'));
    expect(source, contains('account.optString("pass").isEmpty()'));
    expect(source, isNot(contains('settings.optJSONArray("accounts")')));
  });
}
