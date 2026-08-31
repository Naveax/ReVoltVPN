import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:revoltvpn/logic/connection_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy Auto connection mode migrates to TUN', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'connection_mode': 'auto',
      'app_routing_mode': 'all',
    });

    await ConnectionSettings.initialize();

    expect(ConnectionSettings.mode, ConnectionMode.tun);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('connection_mode'), ConnectionMode.tun.name);
  });
}
