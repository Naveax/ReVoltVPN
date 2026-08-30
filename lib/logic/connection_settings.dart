import 'package:shared_preferences/shared_preferences.dart';

enum ConnectionMode { auto, tun, proxy, ass }
enum AppRoutingMode { all, exclude, selected }
enum ResilienceMode { standard, extreme }

abstract final class ConnectionSettings {
  ConnectionSettings._();

  static const String _modeKey = 'connection_mode';
  static const String _routingModeKey = 'app_routing_mode';
  static const String _appPackagesKey = 'app_routing_packages';
  static const String _legacyBlockedAppsKey = 'blocked_apps';
  static const String _resilienceModeKey = 'resilience_mode';

  static ConnectionMode _mode = ConnectionMode.auto;
  static AppRoutingMode _routingMode = AppRoutingMode.all;
  static ResilienceMode _configuredResilienceMode = ResilienceMode.standard;
  static List<String> _appPackages = const <String>[];
  static bool _initialized = false;

  static ConnectionMode get mode => _mode;
  static AppRoutingMode get routingMode => _routingMode;

  // Device testing showed the extra Extreme startup validator could leave the
  // data plane half-usable even though the server profile itself was healthy.
  // Keep both choices on the exact same proven runtime path for now. The UI
  // still remembers the user's choice so safer recovery logic can be restored
  // later without migrating preferences.
  static ResilienceMode get resilienceMode => ResilienceMode.standard;
  static ResilienceMode get configuredResilienceMode => _configuredResilienceMode;

  static List<String> get appPackages => List.unmodifiable(_appPackages);

  static Future<void> initialize() async {
    if (_initialized) return;

    final prefs = await SharedPreferences.getInstance();

    final storedMode = prefs.getString(_modeKey);
    if (storedMode == ConnectionMode.tun.name) {
      _mode = ConnectionMode.tun;
    } else if (storedMode == ConnectionMode.proxy.name) {
      _mode = ConnectionMode.proxy;
    } else if (storedMode == ConnectionMode.ass.name) {
      _mode = ConnectionMode.ass;
    } else {
      _mode = ConnectionMode.auto;
    }

    final legacyBlocked =
        prefs.getStringList(_legacyBlockedAppsKey) ?? const <String>[];
    final storedPackages = prefs.getStringList(_appPackagesKey);
    _appPackages = _cleanPackages(storedPackages ?? legacyBlocked);

    final storedRoutingMode = prefs.getString(_routingModeKey);
    if (storedRoutingMode == AppRoutingMode.exclude.name) {
      _routingMode = AppRoutingMode.exclude;
    } else if (storedRoutingMode == AppRoutingMode.selected.name) {
      _routingMode = AppRoutingMode.selected;
    } else if (storedRoutingMode == null && legacyBlocked.isNotEmpty) {
      _routingMode = AppRoutingMode.exclude;
    } else {
      _routingMode = AppRoutingMode.all;
    }

    _configuredResilienceMode =
        prefs.getString(_resilienceModeKey) == ResilienceMode.extreme.name
            ? ResilienceMode.extreme
            : ResilienceMode.standard;

    _initialized = true;
  }

  static Future<void> setMode(ConnectionMode mode) async {
    _mode = mode;
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, mode.name);
  }

  static Future<void> setRoutingMode(AppRoutingMode mode) async {
    _routingMode = mode;
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_routingModeKey, mode.name);
  }

  static Future<void> setAppPackages(Iterable<String> packages) async {
    _appPackages = _cleanPackages(packages);
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_appPackagesKey, _appPackages);
  }

  static Future<void> setResilienceMode(ResilienceMode mode) async {
    _configuredResilienceMode = mode;
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_resilienceModeKey, mode.name);
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
