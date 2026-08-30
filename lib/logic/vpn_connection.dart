import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/app_specific_routing.dart';
import 'package:revoltvpn/logic/connection_settings.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';
import 'package:revoltvpn/logic/installed_apps_service.dart';
import 'package:revoltvpn/logic/local_socks_tester.dart';
import 'package:revoltvpn/logic/network_monitor.dart';

enum VpnStatus {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error,
}

class _RoutingPlan {
  final bool runtimeProxyOnly;
  final List<String>? blockedApps;
  final NativeRoutingPolicy? nativePolicy;
  final List<String> nativePackages;

  const _RoutingPlan({
    required this.runtimeProxyOnly,
    required this.blockedApps,
    required this.nativePolicy,
    required this.nativePackages,
  });

  bool get usesNativeRouting => nativePolicy != null;
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

  ConnectionMode _activeMode = ConnectionMode.auto;
  ConnectionMode get activeMode => _activeMode;

  ResilienceMode _activeResilienceMode = ResilienceMode.standard;
  ResilienceMode get activeResilienceMode => _activeResilienceMode;

  bool _appSpecificRoutingActive = false;
  bool get appSpecificRoutingActive => _appSpecificRoutingActive;

  String _networkTransport = 'unknown';
  String get networkTransport => _networkTransport;

  bool _networkValidated = false;
  bool get networkValidated => _networkValidated;

  int? _lastHealthLatencyMs;
  int? get lastHealthLatencyMs => _lastHealthLatencyMs;

  int _reconnectCount = 0;
  int get reconnectCount => _reconnectCount;

  int _fallbackCount = 0;
  int get fallbackCount => _fallbackCount;

  String? _lastRecoveryReason;
  String? get lastRecoveryReason => _lastRecoveryReason;

  String get activeRoutingDescription {
    if (!_appSpecificRoutingActive) {
      if (_activeMode == ConnectionMode.proxy) return 'Local SOCKS5';
      return ConnectionSettings.routingMode.name;
    }

    switch (_lastNativePolicy) {
      case NativeRoutingPolicy.all:
        return 'SOCKS5 · all apps';
      case NativeRoutingPolicy.exclude:
        return 'SOCKS5 · excluded apps bypass';
      case NativeRoutingPolicy.selected:
        return _activeMode == ConnectionMode.ass
            ? 'ASS · selected apps'
            : 'Selected apps only';
      case null:
        return ConnectionSettings.routingMode.name;
    }
  }

  String get activeTransportProfile =>
      _status == VpnStatus.connected || _status == VpnStatus.connecting
          ? 'server'
          : 'inactive';

  Timer? _healthTimer;
  Timer? _restartTimer;
  Timer? _networkDebounce;
  StreamSubscription<NetworkSnapshot>? _networkSubscription;

  String? _lastBaseConfig;
  String _lastRemark = 'Revolt VPN';
  List<String>? _lastBlockedApps;
  NativeRoutingPolicy? _lastNativePolicy;
  List<String> _lastNativePackages = const <String>[];
  bool _lastProxyOnly = false;
  int _activeTransportIndex = 0;
  int _runtimeFailures = 0;
  bool _restartInProgress = false;
  bool _userDisconnecting = false;
  bool _receivedInitialNetwork = false;

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

    await ConnectionSettings.initialize();
    _activeMode = ConnectionSettings.mode;
    _activeResilienceMode = ConnectionSettings.resilienceMode;

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

    _networkSubscription = NetworkMonitor.changes.listen(
      _handleNetworkSnapshot,
      onError: (Object error) {
        debugPrint('[VPN] Network monitor error: $error');
      },
    );

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
        _lastHealthLatencyMs = delay;
        _isStartupRestoration = true;
        _setStatus(VpnStatus.connected, _connectedLabel);
      }
    } catch (_) {}
  }

  void _handleNetworkSnapshot(NetworkSnapshot snapshot) {
    if (snapshot.transport == 'vpn') return;

    final previousTransport = _networkTransport;
    _networkTransport = snapshot.transport;
    _networkValidated = snapshot.validated;
    notifyListeners();

    if (!_receivedInitialNetwork) {
      _receivedInitialNetwork = true;
      return;
    }

    if (_status != VpnStatus.connected ||
        _userDisconnecting ||
        _restartInProgress ||
        _lastBaseConfig == null) {
      return;
    }

    final changedPhysicalNetwork =
        _isPhysicalTransport(previousTransport) &&
            _isPhysicalTransport(snapshot.transport) &&
            previousTransport != snapshot.transport &&
            snapshot.connected &&
            snapshot.validated;

    final restoredPhysicalNetwork = previousTransport == 'none' &&
        _isPhysicalTransport(snapshot.transport) &&
        snapshot.connected &&
        snapshot.validated;

    if (!changedPhysicalNetwork && !restoredPhysicalNetwork) return;

    _networkDebounce?.cancel();
    _networkDebounce = Timer(const Duration(milliseconds: 1200), () {
      if (_status != VpnStatus.connected || _userDisconnecting) return;
      final reason = changedPhysicalNetwork
          ? 'Network $previousTransport → ${snapshot.transport}'
          : 'Network restored: ${snapshot.transport}';
      _scheduleRuntimeRestart(reason);
    });
  }

  bool _isPhysicalTransport(String value) {
    return value == 'wifi' ||
        value == 'cellular' ||
        value == 'ethernet' ||
        value == 'other';
  }

  String get _connectedLabel {
    switch (_activeMode) {
      case ConnectionMode.auto:
        return _appSpecificRoutingActive ? 'Auto · apps secured' : 'Auto · secured';
      case ConnectionMode.proxy:
        return 'SOCKS5 routing active';
      case ConnectionMode.ass:
        return 'App Specific routing active';
      case ConnectionMode.tun:
        return _appSpecificRoutingActive ? 'Selected apps secured' : 'Secured';
    }
  }

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
          _scheduleRuntimeRestart('Runtime disconnected');
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
    _networkDebounce?.cancel();
    _reconnectCount = 0;
    _fallbackCount = 0;
    _lastRecoveryReason = null;
    _lastHealthLatencyMs = null;
    _appSpecificRoutingActive = false;

    await ConnectionSettings.initialize();
    _activeMode = ConnectionSettings.mode;
    _activeResilienceMode = ConnectionSettings.resilienceMode;

    _RoutingPlan routingPlan;
    try {
      routingPlan = await _resolveRoutingPlan();
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Bad state: ', '');
      _setStatus(VpnStatus.error, 'App routing error');
      return false;
    }

    if (!kIsWeb && !_initialized) {
      _errorMessage = 'VPN service unavailable.';
      _setStatus(VpnStatus.error, 'Service unavailable');
      return false;
    }

    final needsVpnPermission =
        !routingPlan.runtimeProxyOnly || routingPlan.usesNativeRouting;
    if (!kIsWeb && needsVpnPermission) {
      final ok = await _vless.requestPermission();
      if (!ok) {
        _errorMessage = 'VPN permission denied.';
        _setStatus(VpnStatus.error, 'Permission required');
        return false;
      }
    }

    final startingMessage = switch (_activeMode) {
      ConnectionMode.auto => 'Choosing the best route…',
      ConnectionMode.tun => routingPlan.usesNativeRouting
          ? 'Starting selected-app tunnel…'
          : 'Establishing secure channel…',
      ConnectionMode.proxy => 'Starting SOCKS5 routing…',
      ConnectionMode.ass => 'Starting App Specific routing…',
    };
    _setStatus(VpnStatus.connecting, startingMessage);
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

    _setStatus(VpnStatus.connecting, 'Starting secure route…');

    try {
      final parsed = FlutterVless.parse(realUrl);
      final baseConfig = parsed.getFullConfiguration();
      final remark = parsed.remark.isNotEmpty ? parsed.remark : 'Revolt VPN';
      final configs = _transportConfigs(baseConfig);

      final transportIndex = await _startRuntime(
        configs: configs,
        remark: remark,
        blockedApps: routingPlan.blockedApps,
        proxyOnly: routingPlan.runtimeProxyOnly,
        validate: _activeResilienceMode == ResilienceMode.extreme,
      );

      if (transportIndex == null) {
        throw StateError('No working runtime profile');
      }

      if (routingPlan.runtimeProxyOnly) {
        _setStatus(VpnStatus.connecting, 'Checking Local SOCKS5…');
        if (!await _waitForLocalSocks()) {
          throw StateError('Local SOCKS5 did not become ready');
        }
      }

      if (routingPlan.usesNativeRouting) {
        await AppSpecificRouting.start(
          policy: routingPlan.nativePolicy!,
          packages: routingPlan.nativePackages,
        );
        await Future.delayed(const Duration(milliseconds: 500));
        _appSpecificRoutingActive = true;
      }

      _lastBaseConfig = baseConfig;
      _lastRemark = remark;
      _lastBlockedApps = routingPlan.blockedApps == null
          ? null
          : List.of(routingPlan.blockedApps!);
      _lastNativePolicy = routingPlan.nativePolicy;
      _lastNativePackages = List.of(routingPlan.nativePackages);
      _lastProxyOnly = routingPlan.runtimeProxyOnly;
      _activeTransportIndex = transportIndex;
      _runtimeFailures = 0;
      if (transportIndex > 0) _fallbackCount++;
    } catch (e) {
      debugPrint('[VPN] Tunnel start error: $e');
      await _stopForRetry();
      _clearRuntimeSnapshot();
      _errorMessage = _activeMode == ConnectionMode.proxy
          ? 'Local SOCKS5 failed to start.\nTry reconnecting.'
          : 'Connection failed to start.\nTry reconnecting.';
      _setStatus(VpnStatus.error, 'Connection failed');
      return false;
    }

    _setStatus(VpnStatus.connected, _connectedLabel);
    return true;
  }

  Future<_RoutingPlan> _resolveRoutingPlan() async {
    final routingMode = ConnectionSettings.routingMode;
    final selected = ConnectionSettings.appPackages;

    if (_activeMode == ConnectionMode.auto) {
      if (routingMode == AppRoutingMode.selected) {
        return _selectedProxyPlan();
      }
      return _tunPlan(routingMode, selected);
    }

    if (_activeMode == ConnectionMode.tun) {
      if (routingMode == AppRoutingMode.selected) {
        return _selectedProxyPlan();
      }
      return _tunPlan(routingMode, selected);
    }

    if (_activeMode == ConnectionMode.proxy) {
      switch (routingMode) {
        case AppRoutingMode.all:
          return const _RoutingPlan(
            runtimeProxyOnly: true,
            blockedApps: null,
            nativePolicy: NativeRoutingPolicy.all,
            nativePackages: <String>[],
          );
        case AppRoutingMode.exclude:
          return _RoutingPlan(
            runtimeProxyOnly: true,
            blockedApps: null,
            nativePolicy: NativeRoutingPolicy.exclude,
            nativePackages: selected,
          );
        case AppRoutingMode.selected:
          return _selectedProxyPlan();
      }
    }

    return _selectedProxyPlan();
  }

  _RoutingPlan _tunPlan(
    AppRoutingMode routingMode,
    List<String> selected,
  ) {
    if (routingMode == AppRoutingMode.exclude) {
      return _RoutingPlan(
        runtimeProxyOnly: false,
        blockedApps: selected.isEmpty ? null : selected,
        nativePolicy: null,
        nativePackages: const <String>[],
      );
    }

    return const _RoutingPlan(
      runtimeProxyOnly: false,
      blockedApps: null,
      nativePolicy: null,
      nativePackages: <String>[],
    );
  }

  Future<_RoutingPlan> _selectedProxyPlan() async {
    return _RoutingPlan(
      runtimeProxyOnly: true,
      blockedApps: null,
      nativePolicy: NativeRoutingPolicy.selected,
      nativePackages: await _selectedInstalledPackages(),
    );
  }

  Future<List<String>> _selectedInstalledPackages() async {
    final selected = ConnectionSettings.appPackages.toSet();
    if (selected.isEmpty) {
      throw StateError('Select at least one app.');
    }

    final apps = await InstalledAppsService.loadLaunchableApps();
    final available = apps
        .where((app) => selected.contains(app.packageName))
        .map((app) => app.packageName)
        .toList()
      ..sort();
    if (available.isEmpty) {
      throw StateError('None of the selected apps are installed.');
    }
    return available;
  }

  List<String> _transportConfigs(String baseConfig) {
    // Keep the server-provided VLESS/Reality/XHTTP transport unchanged.
    // Extreme mode changes validation/recovery behavior, not the transport JSON.
    return <String>[baseConfig];
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

  Future<bool> _waitForLocalSocks() async {
    for (var attempt = 0; attempt < 4; attempt++) {
      final result = await LocalSocksTester.test();
      if (result.ok) {
        _lastHealthLatencyMs = result.latencyMs;
        notifyListeners();
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return false;
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
      _lastHealthLatencyMs = delay >= 0 ? delay : null;
      notifyListeners();
      return delay >= 0;
    } catch (_) {
      _lastHealthLatencyMs = null;
      notifyListeners();
      return false;
    }
  }

  Future<void> _stopForRetry() async {
    try {
      await AppSpecificRouting.stop();
    } catch (_) {}
    _appSpecificRoutingActive = false;

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
    final failureLimit =
        _activeResilienceMode == ResilienceMode.extreme ? 1 : 2;
    if (_runtimeFailures >= failureLimit) {
      _scheduleRuntimeRestart('Runtime health check failed');
    }
  }

  void _scheduleRuntimeRestart(String reason) {
    if (_restartInProgress || _userDisconnecting || _lastBaseConfig == null) {
      return;
    }
    if (_restartTimer?.isActive ?? false) return;

    _lastRecoveryReason = reason;
    _setStatus(VpnStatus.connecting, 'Reconnecting…');
    _restartTimer = Timer(const Duration(milliseconds: 900), () {
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

      final configs = _transportConfigs(_lastBaseConfig!);
      final transportIndex = await _startRuntime(
        configs: configs,
        remark: _lastRemark,
        blockedApps: _lastBlockedApps,
        proxyOnly: _lastProxyOnly,
        validate: _activeResilienceMode == ResilienceMode.extreme,
      );

      if (transportIndex == null) {
        _errorMessage = 'Could not restore the connection after a network change.';
        _setStatus(VpnStatus.error, 'Reconnect failed');
        return;
      }

      if (_lastProxyOnly && !await _waitForLocalSocks()) {
        throw StateError('Local SOCKS5 did not recover');
      }

      if (_lastNativePolicy != null) {
        await AppSpecificRouting.start(
          policy: _lastNativePolicy!,
          packages: _lastNativePackages,
        );
        await Future.delayed(const Duration(milliseconds: 500));
        _appSpecificRoutingActive = true;
      }

      if (transportIndex != _activeTransportIndex) _fallbackCount++;
      _activeTransportIndex = transportIndex;
      _runtimeFailures = 0;
      _reconnectCount++;
      _lastRecoveryReason = reason;
      _setStatus(VpnStatus.connected, _connectedLabel);
    } catch (e) {
      debugPrint('[VPN] Reconnect failed: $e');
      _errorMessage = 'Could not restore the connection after a network change.';
      _setStatus(VpnStatus.error, 'Reconnect failed');
    } finally {
      _restartInProgress = false;
    }
  }

  Future<void> disconnect() async {
    _cancelled = true;
    _userDisconnecting = true;
    _restartTimer?.cancel();
    _networkDebounce?.cancel();
    HivemindService.cancel();

    if (_status == VpnStatus.disconnected ||
        _status == VpnStatus.disconnecting) {
      _clearRuntimeSnapshot();
      _userDisconnecting = false;
      return;
    }

    _setStatus(VpnStatus.disconnecting, 'Tearing down…');

    if (kIsWeb) {
      await Future.delayed(const Duration(milliseconds: 500));
      _clearRuntimeSnapshot();
      _setStatus(VpnStatus.disconnected, 'Tap to connect');
      _userDisconnecting = false;
      return;
    }

    try {
      await AppSpecificRouting.stop();
    } catch (_) {}
    _appSpecificRoutingActive = false;

    bool timedOut = false;
    try {
      await _vless.stopVless().timeout(
            const Duration(seconds: 5),
            onTimeout: () => timedOut = true,
          );
    } catch (e) {
      debugPrint('[VPN] VLESS stop error: $e');
      _errorMessage = 'VPN shutdown error.\nPlease restart the app.';
      _clearRuntimeSnapshot();
      _setStatus(VpnStatus.error, 'Shutdown failed');
      _userDisconnecting = false;
      return;
    }

    if (timedOut) {
      debugPrint('[VPN] stopVless() timed out after 5 s — '
          'tunnel may still be active.');
      _errorMessage = 'VPN did not shut down cleanly.\nPlease restart the app.';
      _clearRuntimeSnapshot();
      _setStatus(VpnStatus.error, 'Shutdown failed');
      _userDisconnecting = false;
      return;
    }

    _clearRuntimeSnapshot();
    _setStatus(VpnStatus.disconnected, 'Tap to connect');
    _userDisconnecting = false;
  }

  void _clearRuntimeSnapshot() {
    _lastBaseConfig = null;
    _lastBlockedApps = null;
    _lastNativePolicy = null;
    _lastNativePackages = const <String>[];
    _lastProxyOnly = false;
    _activeTransportIndex = 0;
    _runtimeFailures = 0;
    _lastHealthLatencyMs = null;
    _appSpecificRoutingActive = false;
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
    _networkDebounce?.cancel();
    _networkSubscription?.cancel();
    if (_status == VpnStatus.connected || _status == VpnStatus.connecting) {
      unawaited(AppSpecificRouting.stop());
      try {
        _vless.stopVless();
      } catch (_) {}
    }
    super.dispose();
  }
}
