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

    // Any unrecognized value (including the pre-V3 'auto') is TUN. 'proxy' is
    // the only persisted value that selects the SOCKS5 mode.
    _mode = storedMode == ConnectionMode.proxy.name
        ? ConnectionMode.proxy
        : ConnectionMode.tun;

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
}
