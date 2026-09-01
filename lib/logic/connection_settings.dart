import 'package:shared_preferences/shared_preferences.dart';

enum ConnectionMode { tun, proxy }

abstract final class ConnectionSettings {
  ConnectionSettings._();

  static const String _modeKey = 'connection_mode';

  static ConnectionMode _mode = ConnectionMode.tun;
  static bool _initialized = false;

  static ConnectionMode get mode => _mode;

  static Future<void> initialize() async {
    if (_initialized) return;

    final prefs = await SharedPreferences.getInstance();
    final storedMode = prefs.getString(_modeKey);

    // Legacy 'ass' was the pre-V3 SOCKS5 label; map it to proxy. Everything
    // else (including the old 'auto') is TUN — there is no runtime auto mode.
    _mode = storedMode == ConnectionMode.proxy.name || storedMode == 'ass'
        ? ConnectionMode.proxy
        : ConnectionMode.tun;

    if (storedMode != _mode.name) {
      await prefs.setString(_modeKey, _mode.name);
    }

    _initialized = true;
  }

  static Future<bool> setMode(ConnectionMode mode) async {
    if (_initialized && _mode == mode) return true;

    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(_modeKey, mode.name);
    if (!saved) return false;

    _mode = mode;
    _initialized = true;
    return true;
  }
}
