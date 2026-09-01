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

  test('Hivemind captures cancellation generation before first async lookup', () {
    final source = File('lib/logic/hivemind_service.dart').readAsStringSync();
    final callIdIndex = source.indexOf('final callId = ++_currentCallId;');
    final deviceIdIndex =
        source.indexOf('final deviceId = await CryptoService.getDeviceId();');

    expect(callIdIndex, greaterThanOrEqualTo(0));
    expect(deviceIdIndex, greaterThan(callIdIndex));
    expect(
      source.substring(deviceIdIndex),
      contains('_throwIfCancelled(callId);'),
    );
    expect(
      source,
      contains('_currentCallId++;\n    _expectedNonce = null;'),
    );
  });

  test('notification text is cached only after native update succeeds', () {
    final source =
        File('lib/logic/notification_service.dart').readAsStringSync();
    final invokeIndex =
        source.indexOf("await _channel.invokeMethod<void>('updateNotificationText'");
    final cacheIndex = source.indexOf('_lastText = text;');

    expect(invokeIndex, greaterThanOrEqualTo(0));
    expect(cacheIndex, greaterThan(invokeIndex));
  });
}
