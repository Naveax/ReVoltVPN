import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('vendored Xray SOCKS5 auth uses the current users schema', () {
    final source = File(
      'third_party/flutter_vless_android/android/src/main/kotlin/'
      'com/github/tfox/flutter_vless/xray/core/XrayCoreManager.kt',
    ).readAsStringSync();

    expect(source, contains('.put("auth", "password")'));
    expect(source, contains('.put("users",'));
    expect(source, isNot(contains('.put("accounts",')));
    expect(source, contains('.put("ip", "127.0.0.1")'));
  });
}
