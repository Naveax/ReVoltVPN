import 'package:shared_preferences/shared_preferences.dart';

enum ConnectionMode { tun, proxy }
enum ResilienceMode { standard, extreme }

abstract final class ConnectionSettings {
  ConnectionSettings._();

  static const String _modeKey = 'connection_mode';
  static const String _resilienceModeKey = 'resilience_mode';

  static ConnectionMode _mode = ConnectionMode.tun;
  static ResilienceMode _resilienceMode = ResilienceMode.standard;
  static bool _initialized = false;

  static ConnectionMode get mode => _mode;
  static ResilienceMode get resilienceMode => _resilienceMode;

  static Future<void> initialize() async {
    if (_initialized) return;

    final prefs = await SharedPreferences.getInstance();
    final storedMode = prefs.getString(_modeKey);

    // Legacy 'ass' was the pre-V3 SOCKS5 label; map it to proxy. Everything
    // else (including the old 'auto') is TUN — there is no runtime auto mode.
    _mode = storedMode == ConnectionMode.proxy.name || storedMode == 'ass'
        ? ConnectionMode.proxy
        : ConnectionMode.tun;

    _resilienceMode =
        prefs.getString(_resilienceModeKey) == ResilienceMode.extreme.name
            ? ResilienceMode.extreme
            : ResilienceMode.standard;

    if (storedMode != _mode.name) {
      await prefs.setString(_modeKey, _mode.name);
    }

    _initialized = true;
  }

  static Future<void> setMode(ConnectionMode mode) async {
    _mode = mode;
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, mode.name);
  }

  static Future<void> setResilienceMode(ResilienceMode mode) async {
    _resilienceMode = mode;
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_resilienceModeKey, mode.name);
  }
}
