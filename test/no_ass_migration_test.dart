import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:revoltvpn/logic/connection_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy ASS migrates to SOCKS5 selected-only without losing packages', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'connection_mode': 'ass',
      'app_routing_mode': 'selected',
      'app_routing_packages': <String>[
        'com.android.chrome',
        'com.discord',
      ],
    });

    await ConnectionSettings.initialize();

    expect(ConnectionSettings.mode, ConnectionMode.proxy);
    expect(ConnectionSettings.routingMode, AppRoutingMode.selected);
    expect(
      ConnectionSettings.appPackages,
      <String>['com.android.chrome', 'com.discord'],
    );
  });
}
