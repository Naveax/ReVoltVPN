import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('VPN notification icon stays on the ReVolt asset across updates', () {
    final connection = File('lib/logic/vpn_connection.dart').readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/paladinvpn/app/MainActivity.kt',
    ).readAsStringSync();

    expect(
      connection,
      contains("notificationIconResourceName: 'notification_icon'"),
    );
    expect(activity, contains('R.drawable.notification_icon'));
    expect(activity, isNot(contains('R.drawable.notification_status_icon')));
  });

  test('removed Always-on settings bridge is not reintroduced', () {
    final activity = File(
      'android/app/src/main/kotlin/com/paladinvpn/app/MainActivity.kt',
    ).readAsStringSync();

    expect(activity, isNot(contains('openVpnSettings')));
    expect(activity, isNot(contains('Settings.ACTION_VPN_SETTINGS')));
  });
}
