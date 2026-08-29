import 'package:shared_preferences/shared_preferences.dart';

enum ConnectionMode { tun, proxy }

abstract final class ConnectionSettings {
  ConnectionSettings._();

  static const String _modeKey = 'connection_mode';
  static const String _blockedAppsKey = 'blocked_apps';

  static ConnectionMode _mode = ConnectionMode.tun;
  static List<String> _blockedApps = const <String>[];
  static bool _initialized = false;

  static ConnectionMode get mode => _mode;
  static List<String> get blockedApps => List.unmodifiable(_blockedApps);

  static Future<void> initialize() async {
    if (_initialized) return;

    final prefs = await SharedPreferences.getInstance();
    final storedMode = prefs.getString(_modeKey);
    _mode = storedMode == ConnectionMode.proxy.name
        ? ConnectionMode.proxy
        : ConnectionMode.tun;

    final storedApps = prefs.getStringList(_blockedAppsKey) ?? const <String>[];
    _blockedApps = _cleanPackages(storedApps);
    _initialized = true;
  }

  static Future<void> setMode(ConnectionMode mode) async {
    _mode = mode;
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, mode.name);
  }

  static Future<void> setBlockedApps(Iterable<String> packages) async {
    _blockedApps = _cleanPackages(packages);
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_blockedAppsKey, _blockedApps);
  }

  static List<String> _cleanPackages(Iterable<String> packages) {
    final seen = <String>{};
    final result = <String>[];
    for (final raw in packages) {
      final value = raw.trim();
      if (value.isEmpty || !seen.add(value)) continue;
      result.add(value);
    }
    result.sort();
    return result;
  }
}
