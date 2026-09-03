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

    // Only the explicit current proxy value restores SOCKS5. Unknown and
    // obsolete values, including the former 'auto'/'ass' labels, fail closed
    // to full-tunnel TUN instead of silently selecting a weaker route.
    _mode = storedMode == ConnectionMode.proxy.name
        ? ConnectionMode.proxy
        : ConnectionMode.tun;

    if (storedMode != _mode.name) {
      final migrated = await prefs.setString(_modeKey, _mode.name);
      if (!migrated) {
        throw StateError('Could not persist migrated connection mode.');
      }
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
