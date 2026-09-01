import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('notification liveness matches only the ReVolt VPN process', () {
    final source = File(
      'android/app/src/main/kotlin/com/paladinvpn/app/MainActivity.kt',
    ).readAsStringSync();

    expect(
      source,
      contains(r'val expectedProcessName = "$packageName$VPN_PROCESS_SUFFIX"'),
    );
    expect(source, contains('it.processName == expectedProcessName'));
    expect(source, isNot(contains('endsWith(VPN_PROCESS_SUFFIX)')));
  });

  test('SOCKS reads use one total deadline instead of per-chunk timeout', () {
    final source = File('lib/logic/local_socks_tester.dart').readAsStringSync();

    expect(
      source,
      contains('timeout.inMicroseconds - elapsed.elapsedMicroseconds'),
    );
    expect(
      source,
      contains("throw TimeoutException('Socket read timed out', timeout);"),
    );
  });
}
