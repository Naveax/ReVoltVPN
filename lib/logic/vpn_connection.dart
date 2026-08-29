import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/connection_settings.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';
import 'package:revoltvpn/logic/installed_apps_service.dart';

enum VpnStatus {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error,
}

class VpnConnection extends ChangeNotifier {
  bool _cancelled = false;
  VpnStatus _status = VpnStatus.disconnected;
  VpnStatus get status => _status;

  String _statusMessage = 'Tap to connect';
  String get statusMessage => _statusMessage;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  bool _isStartupRestoration = false;
  bool get isStartupRestoration => _isStartupRestoration;

  bool _serverReachable = false;
  bool get serverReachable => _serverReachable;

  ConnectionMode _activeMode = ConnectionMode.tun;
  ConnectionMode get activeMode => _activeMode;

  ResilienceMode _activeResilienceMode = ResilienceMode.standard;
  ResilienceMode get activeResilienceMode => _activeResilienceMode;

  Timer? _healthTimer;
  Timer? _restartTimer;

  String? _lastBaseConfig;
  String _lastRemark = 'Revolt VPN';
  List<String>? _lastBlockedApps;
  bool _lastProxyOnly = false;
  int _activeTransportIndex = 0;
  int _runtimeFailures = 0;
  bool _restartInProgress = false;
  bool _userDisconnecting = false;

  late final FlutterVless _vless;
  bool _initialized = false;
  final Completer<void> _readyCompleter = Completer<void>();
  Future<void> get ready => _readyCompleter.future;

  VpnConnection() {
    _activeMode = ConnectionSettings.mode;
    _activeResilienceMode = ConnectionSettings.resilienceMode;
    _init();
  }

  Future<void> _init() async {
    try {
      await _startEngine();
    } catch (e) {
      debugPrint('[VPN] Engine init failed: $e');
    } finally {
      if (!_readyCompleter.isCompleted) _readyCompleter.complete();
    }
  }

  Future<void> _startEngine() async {
    if (kIsWeb) return;

    _vless = FlutterVless(
      onStatusChanged: (status) {
        debugPrint('[VPN] Status: state=${status.state} '
            'connection=${status.connectionState.name}');
        _mapStatus(status);
      },
    );

    try {
      await _vless.initializeVless(
        providerBundleIdentifier: 'com.paladinvpn.app',
        notificationIconResourceType: 'drawable',
        notificationIconResourceName: 'notification_icon',
      );
      _initialized = true;
    } catch (e) {
      debugPrint('[VPN] VLESS init error (expected on emulator): $e');
    }

    unawaited(_checkHealth());
    _healthTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_checkHealth());
      unawaited(_checkActiveRuntime());
    });

    try {
      final coreVersion = await _vless.getCoreVersion();
      debugPrint('[VPN] Xray core version: $coreVersion');

      final delay = await _vless.getConnectedServerDelay();
      if (delay > 0) {
        _isStartupRestoration = true;
        _setStatus(VpnStatus.connected, _connectedLabel);
      }
    } catch (_) {}
  }

  String get _connectedLabel =>
      _activeMode == ConnectionMode.proxy ? 'Proxy ready' : 'Secured';

  void _mapStatus(VlessStatus status) {
    switch (status.connectionState) {
      case VlessConnectionState.connected:
        _runtimeFailures = 0;
        _setStatus(VpnStatus.connected, _connectedLabel);
        break;
      case VlessConnectionState.disconnected:
        if (_restartInProgress) return;

        final shouldRecover = !_userDisconnecting &&
            _lastBaseConfig != null &&
            _status == VpnStatus.connected;
        if (shouldRecover) {
          _scheduleRuntimeRestart('Network changed');
          return;
        }

        _isStartupRestoration = false;
        _setStatus(VpnStatus.disconnected, 'Tap to connect');
        break;
      case VlessConnectionState.connecting:
        if (!_restartInProgress) {
          _setStatus(VpnStatus.connecting, 'Establishing tunnel…');
        }
        break;
      case VlessConnectionState.disconnecting:
        _isStartupRestoration = false;
        if (!_restartInProgress) {
          _setStatus(VpnStatus.disconnecting, 'Tearing down…');
        }
        break;
      case VlessConnectionState.unknown:
        if (_status != VpnStatus.connected &&
            _status != VpnStatus.disconnected &&
            !_restartInProgress) {
          _setStatus(VpnStatus.error, 'Connection failed');
        }
        break;
    }
  }

  Future<bool> connect({
    bool skipAdBypass = false,
  }) async {
    if (_status == VpnStatus.connected || _status == VpnStatus.connecting) {
      return false;
    }

    _cancelled = false;
    _userDisconnecting = false;
    _restartTimer?.cancel();

    await ConnectionSettings.initialize();
    _activeMode = ConnectionSettings.mode;
    _activeResilienceMode = ConnectionSettings.resilienceMode;
    final proxyOnly = _activeMode == ConnectionMode.proxy;

    if (!kIsWeb && !_initialized) {
      _errorMessage = 'VPN service unavailable.';
      _setStatus(VpnStatus.error, 'Service unavailable');
      return false;
    }

    if (!kIsWeb && !proxyOnly) {
      final ok = await _vless.requestPermission();
      if (!ok) {
        _errorMessage = 'VPN permission denied.';
        _setStatus(VpnStatus.error, 'Permission required');
        return false;
      }
    }

    _setStatus(
      VpnStatus.connecting,
      proxyOnly ? 'Starting local proxy…' : 'Establishing secure channel…',
    );
    _errorMessage = null;

    if (kIsWeb) {
      await Future.delayed(const Duration(seconds: 1));
      _setStatus(VpnStatus.connected, 'Secured (dev mode)');
      return true;
    }

    _setStatus(VpnStatus.connecting, 'Fetching config…');

    String realUrl;
    try {
      realUrl = await HivemindService.fetchConfigDirectly(
        skipAdBypass: skipAdBypass,
        onAttempt: (attempt, total) {
          _setStatus(
            VpnStatus.connecting,
            'Contacting server ($attempt/$total)…',
          );
        },
      );
    } catch (e) {
      debugPrint('[VPN] Config fetch error: $e');
      final raw = e.toString().replaceAll('Exception: ', '');
      if (raw.contains('Cancelled')) return false;
      if (raw.contains('timed out') || raw.contains('Session not activated')) {
        _errorMessage =
            'The server did not respond in time.\nCheck your connection and try again.';
        _setStatus(VpnStatus.error, 'Server unreachable');
      } else {
        _errorMessage = raw;
        _setStatus(VpnStatus.error, 'Config fetch error');
      }
      return false;
    }

    if (_cancelled) {
      _setStatus(VpnStatus.disconnected, 'Tap to connect');
      return false;
    }

    _setStatus(
      VpnStatus.connecting,
      proxyOnly ? 'Starting proxy…' : 'Securing connection…',
    );

    try {
      final parsed = FlutterVless.parse(realUrl);
      final baseConfig = parsed.getFullConfiguration();
      final remark = parsed.remark.isNotEmpty ? parsed.remark : 'Revolt VPN';
      final blockedApps = await _resolveBlockedApps(proxyOnly);
      final configs = _transportConfigs(baseConfig, _activeResilienceMode);

      final transportIndex = await _startRuntime(
        configs: configs,
        remark: remark,
        blockedApps: blockedApps,
        proxyOnly: proxyOnly,
        validate: _activeResilienceMode == ResilienceMode.extreme,
      );

      if (transportIndex == null) {
        throw StateError('No working runtime profile');
      }

      _lastBaseConfig = baseConfig;
      _lastRemark = remark;
      _lastBlockedApps = blockedApps == null ? null : List.of(blockedApps);
      _lastProxyOnly = proxyOnly;
      _activeTransportIndex = transportIndex;
      _runtimeFailures = 0;
    } catch (e) {
      debugPrint('[VPN] Tunnel start error: $e');
      _clearRuntimeSnapshot();
      _errorMessage = proxyOnly
          ? 'Proxy failed to start.\nTry reconnecting.'
          : 'Tunnel failed to start.\nTry reconnecting.';
      _setStatus(VpnStatus.error, 'Connection failed');
      return false;
    }

    _setStatus(VpnStatus.connected, _connectedLabel);
    return true;
  }

  Future<List<String>?> _resolveBlockedApps(bool proxyOnly) async {
    if (proxyOnly) return null;

    final selected = ConnectionSettings.appPackages;
    switch (ConnectionSettings.routingMode) {
      case AppRoutingMode.all:
        return null;
      case AppRoutingMode.exclude:
        return selected.isEmpty ? null : selected;
      case AppRoutingMode.selected:
        if (selected.isEmpty) {
          throw StateError('Select at least one app for Selected only mode.');
        }

        final apps = await InstalledAppsService.loadLaunchableApps();
        final selectedSet = selected.toSet();
        final availableSelected =
            apps.where((app) => selectedSet.contains(app.packageName)).toList();
        if (availableSelected.isEmpty) {
          throw StateError('None of the selected apps are installed.');
        }

        final blocked = apps
            .where((app) => !selectedSet.contains(app.packageName))
            .map((app) => app.packageName)
            .toList();
        return blocked.isEmpty ? null : blocked;
    }
  }

  List<String> _transportConfigs(
    String baseConfig,
    ResilienceMode resilienceMode,
  ) {
    if (resilienceMode == ResilienceMode.standard) {
      return <String>[baseConfig];
    }

    final configs = <String>[baseConfig];
    for (final mode in const <String>['stream-up', 'packet-up']) {
      final variant = _withXhttpMode(baseConfig, mode);
      if (variant != null && !configs.contains(variant)) {
        configs.add(variant);
      }
    }
    return configs;
  }

  String? _withXhttpMode(String config, String mode) {
    try {
      final decoded = jsonDecode(config);
      if (decoded is! Map<String, dynamic>) return null;

      final outbounds = decoded['outbounds'];
      if (outbounds is! List) return null;

      var changed = false;
      for (final item in outbounds) {
        if (item is! Map<String, dynamic>) continue;
        final streamSettings = item['streamSettings'];
        if (streamSettings is! Map<String, dynamic>) continue;
        if (streamSettings['network'] != 'xhttp') continue;

        final current = streamSettings['xhttpSettings'];
        final xhttpSettings = current is Map<String, dynamic>
            ? Map<String, dynamic>.from(current)
            : <String, dynamic>{};
        xhttpSettings['mode'] = mode;
        streamSettings['xhttpSettings'] = xhttpSettings;
        changed = true;
      }

      return changed ? jsonEncode(decoded) : null;
    } catch (e) {
      debugPrint('[VPN] Could not build XHTTP fallback: $e');
      return null;
    }
  }

  Future<int?> _startRuntime({
    required List<String> configs,
    required String remark,
    required List<String>? blockedApps,
    required bool proxyOnly,
    required bool validate,
    int startIndex = 0,
  }) async {
    for (var offset = 0; offset < configs.length; offset++) {
      final index = (startIndex + offset) % configs.length;
      try {
        await _vless.startVless(
          remark: remark,
          config: configs[index],
          blockedApps: blockedApps,
          proxyOnly: proxyOnly,
        );

        if (!validate || await _runtimeHealthy()) {
          return index;
        }

        debugPrint('[VPN] Runtime profile $index did not pass health check.');
      } catch (e) {
        debugPrint('[VPN] Runtime profile $index failed: $e');
      }

      await _stopForRetry();
    }

    return null;
  }

  Future<bool> _runtimeHealthy() async {
    await Future.delayed(const Duration(milliseconds: 900));
    try {
      final delay = await _vless
          .getConnectedServerDelay(
            url: '${AppConfig.hivemindApiPublic}/health',
          )
          .timeout(
            const Duration(seconds: 6),
            onTimeout: () => -1,
          );
      return delay >= 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _stopForRetry() async {
    try {
      await _vless.stopVless().timeout(const Duration(seconds: 4));
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 500));
  }

  Future<void> _checkActiveRuntime() async {
    if (_status != VpnStatus.connected ||
        _restartInProgress ||
        _userDisconnecting ||
        _lastBaseConfig == null) {
      return;
    }

    if (await _runtimeHealthy()) {
      _runtimeFailures = 0;
      return;
    }

    _runtimeFailures++;
    if (_runtimeFailures >= 2) {
      _scheduleRuntimeRestart('Runtime health check failed');
    }
  }

  void _scheduleRuntimeRestart(String reason) {
    if (_restartInProgress || _userDisconnecting || _lastBaseConfig == null) {
      return;
    }
    if (_restartTimer?.isActive ?? false) return;

    _setStatus(VpnStatus.connecting, 'Network changed — reconnecting…');
    _restartTimer = Timer(const Duration(milliseconds: 1500), () {
      unawaited(_restartActiveRuntime(reason));
    });
  }

  Future<void> _restartActiveRuntime(String reason) async {
    if (_restartInProgress || _userDisconnecting || _lastBaseConfig == null) {
      return;
    }

    _restartInProgress = true;
    debugPrint('[VPN] Restarting runtime: $reason');

    try {
      await _stopForRetry();

      final configs = _transportConfigs(
        _lastBaseConfig!,
        _activeResilienceMode,
      );
      final startIndex = _activeResilienceMode == ResilienceMode.extreme &&
              configs.length > 1
          ? (_activeTransportIndex + 1) % configs.length
          : 0;

      final transportIndex = await _startRuntime(
        configs: configs,
        remark: _lastRemark,
        blockedApps: _lastBlockedApps,
        proxyOnly: _lastProxyOnly,
        validate: _activeResilienceMode == ResilienceMode.extreme,
        startIndex: startIndex,
      );

      if (transportIndex == null) {
        _errorMessage = 'Could not restore the connection after a network change.';
        _setStatus(VpnStatus.error, 'Reconnect failed');
        return;
      }

      _activeTransportIndex = transportIndex;
      _runtimeFailures = 0;
      _setStatus(VpnStatus.connected, _connectedLabel);
    } finally {
      _restartInProgress = false;
    }
  }

  Future<void> disconnect() async {
    _cancelled = true;
    _userDisconnecting = true;
    _restartTimer?.cancel();
    HivemindService.cancel();
    _clearRuntimeSnapshot();

    if (_status == VpnStatus.disconnected ||
        _status == VpnStatus.disconnecting) {
      _userDisconnecting = false;
      return;
    }

    _setStatus(VpnStatus.disconnecting, 'Tearing down…');

    if (kIsWeb) {
      await Future.delayed(const Duration(milliseconds: 500));
      _setStatus(VpnStatus.disconnected, 'Tap to connect');
      _userDisconnecting = false;
      return;
    }

    bool timedOut = false;
    try {
      await _vless.stopVless().timeout(
            const Duration(seconds: 5),
            onTimeout: () => timedOut = true,
          );
    } catch (e) {
      debugPrint('[VPN] VLESS stop error: $e');
      _errorMessage = 'VPN shutdown error.\nPlease restart the app.';
      _setStatus(VpnStatus.error, 'Shutdown failed');
      _userDisconnecting = false;
      return;
    }

    if (timedOut) {
      debugPrint('[VPN] stopVless() timed out after 5 s — '
          'tunnel may still be active.');
      _errorMessage = 'VPN did not shut down cleanly.\nPlease restart the app.';
      _setStatus(VpnStatus.error, 'Shutdown failed');
      _userDisconnecting = false;
      return;
    }

    _setStatus(VpnStatus.disconnected, 'Tap to connect');
    _userDisconnecting = false;
  }

  void _clearRuntimeSnapshot() {
    _lastBaseConfig = null;
    _lastBlockedApps = null;
    _lastProxyOnly = false;
    _activeTransportIndex = 0;
    _runtimeFailures = 0;
  }

  void _setStatus(VpnStatus status, String message) {
    _status = status;
    _statusMessage = message;
    notifyListeners();
  }

  Future<void> _checkHealth() async {
    _serverReachable = await HivemindService.checkHealth();
    notifyListeners();
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _restartTimer?.cancel();
    if (_status == VpnStatus.connected || _status == VpnStatus.connecting) {
      try {
        _vless.stopVless();
      } catch (_) {}
    }
    super.dispose();
  }
}
