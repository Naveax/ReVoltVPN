import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:revoltvpn/logic/connection_settings.dart';
import 'package:revoltvpn/logic/flutter_vless_android_routing.dart';
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
  final bool proxyOnly;
  final List<String>? blockedApps;
  final List<String> allowedApps;
  final bool selectedOnly;
  final bool verifyLocalSocks;

  const _RoutingPlan({
    required this.proxyOnly,
    required this.blockedApps,
    this.allowedApps = const <String>[],
    this.selectedOnly = false,
    this.verifyLocalSocks = false,
  });
}

class VpnConnection extends ChangeNotifier {
  static const int _maxExtremeRecoveryAttempts = 2;

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

  int get fallbackCount => 0;

  String? _lastRecoveryReason;
  String? get lastRecoveryReason => _lastRecoveryReason;

  String get activeRoutingDescription {
    if (_activeMode == ConnectionMode.proxy) {
      if (_appSpecificRoutingActive) return 'SOCKS5 · selected apps';
      if (_lastBlockedApps?.isNotEmpty == true) return 'SOCKS5 · exclude apps';
      return 'SOCKS5 · all apps';
    }
    if (_appSpecificRoutingActive) {
      return _activeMode == ConnectionMode.ass
          ? 'ASS · selected apps'
          : 'Selected apps only';
    }
    if (_lastBlockedApps?.isNotEmpty == true) {
      return 'Exclude apps';
    }
    return 'All apps';
  }

  String get activeTransportProfile =>
      _status == VpnStatus.connected || _status == VpnStatus.connecting
          ? 'server'
          : 'inactive';

  Timer? _healthTimer;
  Timer? _restartTimer;
  StreamSubscription<NetworkSnapshot>? _networkSubscription;

  String? _lastBaseConfig;
  String _lastRemark = 'Revolt VPN';
  List<String>? _lastBlockedApps;
  List<String> _lastAllowedApps = const <String>[];
  bool _lastProxyOnly = false;
  bool _lastVerifyLocalSocks = false;
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

    await ConnectionSettings.initialize();
    _activeMode = ConnectionSettings.mode;
    _activeResilienceMode = ConnectionSettings.resilienceMode;

    _vless = FlutterVless(
      onStatusChanged: (status) {
        debugPrint(
          '[VPN] Status: state=${status.state} '
          'connection=${status.connectionState.name}',
        );
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
      (snapshot) {
        // ConnectivityManager is informational only. Android/Xray already
        // survives most Wi-Fi/mobile handovers. Forcing a restart from every
        // callback caused the old reconnect loop because VPN creation itself
        // also changes network state.
        _networkTransport = snapshot.transport;
        _networkValidated = snapshot.validated;
        notifyListeners();
      },
      onError: (Object error) {
        debugPrint('[VPN] Network monitor error: $error');
      },
    );

    unawaited(_checkHealth());
    _healthTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_checkHealth());
    });

    try {
      final coreVersion = await _vless.getCoreVersion();
      debugPrint('[VPN] Xray core version: $coreVersion');

      final delay = await _vless.getConnectedServerDelay();
      if (delay > 0) {
        _lastHealthLatencyMs = delay;
        _isStartupRestoration = true;
        _restoreRoutingPresentationFromSettings();
        _setStatus(VpnStatus.connected, _connectedLabel);
      }
    } catch (_) {}
  }

  void _restoreRoutingPresentationFromSettings() {
    final routingMode = ConnectionSettings.routingMode;
    final packages = ConnectionSettings.appPackages;

    _lastBlockedApps = null;
    _lastAllowedApps = const <String>[];
    _lastProxyOnly = false;
    _lastVerifyLocalSocks = _activeMode == ConnectionMode.proxy ||
        _activeMode == ConnectionMode.ass ||
        routingMode == AppRoutingMode.selected;
    _appSpecificRoutingActive = false;

    if (_activeMode == ConnectionMode.ass ||
        ((_activeMode == ConnectionMode.auto ||
                _activeMode == ConnectionMode.tun ||
                _activeMode == ConnectionMode.proxy) &&
            routingMode == AppRoutingMode.selected)) {
      _appSpecificRoutingActive = packages.isNotEmpty;
      return;
    }

    if ((_activeMode == ConnectionMode.auto ||
            _activeMode == ConnectionMode.tun ||
            _activeMode == ConnectionMode.proxy) &&
        routingMode == AppRoutingMode.exclude &&
        packages.isNotEmpty) {
      _lastBlockedApps = List.of(packages);
    }
  }

  String get _connectedLabel {
    switch (_activeMode) {
      case ConnectionMode.auto:
        return _appSpecificRoutingActive
            ? 'Auto · selected apps secured'
            : 'Auto · secured';
      case ConnectionMode.proxy:
        return _appSpecificRoutingActive
            ? 'SOCKS5 · selected apps secured'
            : 'SOCKS5 gateway active';
      case ConnectionMode.ass:
        return 'App Specific routing active';
      case ConnectionMode.tun:
        return _appSpecificRoutingActive ? 'Selected apps secured' : 'Secured';
    }
  }

  void _mapStatus(VlessStatus status) {
    switch (status.connectionState) {
      case VlessConnectionState.connected:
        _setStatus(VpnStatus.connected, _connectedLabel);
        break;

      case VlessConnectionState.disconnected:
        // A recovery timer changes the public state to `connecting` before the
        // restart begins. Repeated native DISCONNECTED broadcasts during that
        // debounce window must not clear the config snapshot the timer needs.
        if (_restartInProgress || (_restartTimer?.isActive ?? false)) return;

        final canRecover = !_userDisconnecting &&
            _activeResilienceMode == ResilienceMode.extreme &&
            _lastBaseConfig != null &&
            _status == VpnStatus.connected;
        if (canRecover) {
          _scheduleRuntimeRestart('Runtime disconnected');
          return;
        }

        _clearRuntimeSnapshot();
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

  Future<bool> connect({bool skipAdBypass = false}) async {
    if (_status == VpnStatus.connected || _status == VpnStatus.connecting) {
      return false;
    }

    _cancelled = false;
    _userDisconnecting = false;
    _restartTimer?.cancel();
    _reconnectCount = 0;
    _lastRecoveryReason = null;
    _lastHealthLatencyMs = null;
    _appSpecificRoutingActive = false;

    await ConnectionSettings.initialize();
    _activeMode = ConnectionSettings.mode;
    _activeResilienceMode = ConnectionSettings.resilienceMode;

    late final _RoutingPlan routingPlan;
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

    if (!kIsWeb && !routingPlan.proxyOnly) {
      final ok = await _vless.requestPermission();
      if (!ok) {
        _errorMessage = 'VPN permission denied.';
        _setStatus(VpnStatus.error, 'Permission required');
        return false;
      }
    }

    final startingMessage = switch (_activeMode) {
      ConnectionMode.auto => routingPlan.selectedOnly
          ? 'Auto · starting selected-app route…'
          : 'Auto · starting TUN…',
      ConnectionMode.tun => routingPlan.selectedOnly
          ? 'Starting selected-app tunnel…'
          : 'Establishing secure channel…',
      ConnectionMode.proxy => routingPlan.selectedOnly
          ? 'SOCKS5 · starting selected-app gateway…'
          : 'Starting transparent SOCKS5 gateway…',
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

      // Set this before the native status callback can report CONNECTED so the
      // first visible label already reflects Selected-only/ASS accurately.
      _appSpecificRoutingActive = routingPlan.selectedOnly;

      await _startRuntime(
        config: baseConfig,
        remark: remark,
        blockedApps: routingPlan.blockedApps,
        allowedApps: routingPlan.allowedApps,
        proxyOnly: routingPlan.proxyOnly,
      );

      if (routingPlan.proxyOnly) {
        _setStatus(VpnStatus.connecting, 'Checking Local SOCKS5…');
        if (!await _waitForLocalSocks()) {
          throw StateError('Local SOCKS5 did not become ready');
        }
      } else {
        _setStatus(VpnStatus.connecting, 'Waiting for VPN interface…');
        if (!await _waitForNativeConnected()) {
          throw StateError('VPN runtime did not report CONNECTED');
        }
        if (routingPlan.verifyLocalSocks) {
          _setStatus(VpnStatus.connecting, 'Checking Local SOCKS5…');
          if (!await _waitForLocalSocks()) {
            throw StateError('Local SOCKS5 gateway did not become ready');
          }
        }
      }

      _lastBaseConfig = baseConfig;
      _lastRemark = remark;
      _lastBlockedApps = routingPlan.blockedApps == null
          ? null
          : List.of(routingPlan.blockedApps!);
      _lastAllowedApps = List.of(routingPlan.allowedApps);
      _lastProxyOnly = routingPlan.proxyOnly;
      _lastVerifyLocalSocks = routingPlan.verifyLocalSocks;
      _appSpecificRoutingActive = routingPlan.selectedOnly;
    } catch (e) {
      debugPrint('[VPN] Tunnel start error: $e');
      await _stopRuntime();
      await _clearAndroidAllowlist();
      _clearRuntimeSnapshot();
      _errorMessage = _activeMode == ConnectionMode.proxy
          ? 'SOCKS5 gateway failed to start.\nTry reconnecting.'
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

    switch (_activeMode) {
      case ConnectionMode.auto:
        if (routingMode == AppRoutingMode.selected) {
          return _selectedCompatibilityPlan(verifyLocalSocks: true);
        }
        return _tunPlan(routingMode, selected);

      case ConnectionMode.tun:
        if (routingMode == AppRoutingMode.selected) {
          return _selectedCompatibilityPlan(verifyLocalSocks: true);
        }
        return _tunPlan(routingMode, selected);

      case ConnectionMode.proxy:
        // Transparent SOCKS5 keeps the local 127.0.0.1:10807 ingress but also
        // creates the Android TUN wrapper so ordinary apps do not need their
        // own proxy setting. All/Exclude/Selected routing therefore works here.
        if (routingMode == AppRoutingMode.selected) {
          return _selectedCompatibilityPlan(verifyLocalSocks: true);
        }
        return _tunPlan(
          routingMode,
          selected,
          verifyLocalSocks: true,
        );

      case ConnectionMode.ass:
        // ASS is compatibility-first selected-app SOCKS routing. Other
        // launchable apps bypass the VPN while Android system/network helpers
        // remain available inside it, which avoids breaking apps that rely on
        // resolver / Play Services traffic.
        return _selectedCompatibilityPlan(verifyLocalSocks: true);
    }
  }

  _RoutingPlan _tunPlan(
    AppRoutingMode routingMode,
    List<String> selected, {
    bool verifyLocalSocks = false,
  }) {
    if (routingMode == AppRoutingMode.exclude) {
      return _RoutingPlan(
        proxyOnly: false,
        blockedApps: selected.isEmpty ? null : selected,
        verifyLocalSocks: verifyLocalSocks,
      );
    }

    return _RoutingPlan(
      proxyOnly: false,
      blockedApps: null,
      verifyLocalSocks: verifyLocalSocks,
    );
  }

  Future<_RoutingPlan> _selectedCompatibilityPlan({
    bool verifyLocalSocks = false,
  }) async {
    final selected = ConnectionSettings.appPackages.toSet();
    if (selected.isEmpty) {
      throw StateError('Select at least one app.');
    }

    final apps = await InstalledAppsService.loadLaunchableApps();
    final availableSelected = apps
        .where((app) => selected.contains(app.packageName))
        .map((app) => app.packageName)
        .toSet();

    if (availableSelected.isEmpty) {
      throw StateError('None of the selected apps are installed.');
    }

    // Compatibility selected routing uses the plugin's proven blocklist path:
    // every other launchable user app bypasses the VPN, while Android system
    // helpers (DNS resolver, Play Services, network stack, etc.) are not
    // excluded. Strict addAllowedApplication remains available in the native
    // patch for future opt-in use, but is intentionally not the default.
    final blocked = apps
        .map((app) => app.packageName)
        .where((packageName) => !availableSelected.contains(packageName))
        .toSet()
        .toList()
      ..sort();

    return _RoutingPlan(
      proxyOnly: false,
      blockedApps: blocked.isEmpty ? null : blocked,
      selectedOnly: true,
      verifyLocalSocks: verifyLocalSocks,
    );
  }

  Future<void> _startRuntime({
    required String config,
    required String remark,
    required List<String>? blockedApps,
    required List<String> allowedApps,
    required bool proxyOnly,
  }) async {
    await FlutterVlessAndroidRouting.setAllowedApps(allowedApps);
    await _vless.startVless(
      remark: remark,
      config: config,
      blockedApps: blockedApps,
      proxyOnly: proxyOnly,
    );
  }

  Future<bool> _waitForLocalSocks() async {
    for (var attempt = 0; attempt < 6; attempt++) {
      final result = await LocalSocksTester.test();
      if (result.ok) {
        _lastHealthLatencyMs = result.latencyMs;
        notifyListeners();
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }
    return false;
  }

  Future<bool> _waitForNativeConnected() async {
    // startVless() only queues the Android foreground service. Wait for the
    // service/core broadcast instead of treating MethodChannel completion as a
    // successfully established TUN interface.
    for (var attempt = 0; attempt < 24; attempt++) {
      if (_status == VpnStatus.connected) return true;
      if (_status == VpnStatus.error) return false;
      if (_cancelled || _userDisconnecting) return false;
      await Future.delayed(const Duration(milliseconds: 250));
    }
    return _status == VpnStatus.connected;
  }

  void _scheduleRuntimeRestart(String reason) {
    if (_activeResilienceMode != ResilienceMode.extreme ||
        _restartInProgress ||
        _userDisconnecting ||
        _lastBaseConfig == null ||
        (_restartTimer?.isActive ?? false)) {
      return;
    }

    _lastRecoveryReason = reason;
    _setStatus(VpnStatus.connecting, 'Reconnecting…');
    _restartTimer = Timer(const Duration(milliseconds: 1200), () {
      unawaited(_restartActiveRuntime(reason));
    });
  }

  Future<void> _restartActiveRuntime(String reason) async {
    if (_restartInProgress || _userDisconnecting || _lastBaseConfig == null) {
      return;
    }

    _restartInProgress = true;
    Object? lastError;

    try {
      for (var attempt = 1;
          attempt <= _maxExtremeRecoveryAttempts;
          attempt++) {
        if (_userDisconnecting || _lastBaseConfig == null) return;

        try {
          debugPrint(
            '[VPN] Extreme recovery attempt '
            '$attempt/$_maxExtremeRecoveryAttempts: $reason',
          );

          await _stopRuntime();
          if (_userDisconnecting) return;

          await Future.delayed(
            Duration(milliseconds: attempt == 1 ? 600 : 900),
          );
          if (_userDisconnecting || _lastBaseConfig == null) return;

          await _startRuntime(
            config: _lastBaseConfig!,
            remark: _lastRemark,
            blockedApps: _lastBlockedApps,
            allowedApps: _lastAllowedApps,
            proxyOnly: _lastProxyOnly,
          );

          if (_lastProxyOnly) {
            if (!await _waitForLocalSocks()) {
              throw StateError('Local SOCKS5 did not recover');
            }
          } else {
            if (!await _waitForNativeConnected()) {
              throw StateError('VPN runtime did not recover');
            }
            if (_lastVerifyLocalSocks && !await _waitForLocalSocks()) {
              throw StateError('Local SOCKS5 gateway did not recover');
            }
          }

          if (_userDisconnecting) return;

          _reconnectCount++;
          _lastRecoveryReason = reason;
          _appSpecificRoutingActive = _activeMode == ConnectionMode.ass ||
              ConnectionSettings.routingMode == AppRoutingMode.selected;
          _errorMessage = null;
          _setStatus(VpnStatus.connected, _connectedLabel);
          return;
        } catch (e) {
          lastError = e;
          debugPrint(
            '[VPN] Extreme recovery attempt '
            '$attempt/$_maxExtremeRecoveryAttempts failed: $e',
          );
          await _stopRuntime();
          if (_userDisconnecting) return;

          if (attempt < _maxExtremeRecoveryAttempts) {
            _setStatus(
              VpnStatus.connecting,
              'Reconnecting… (${attempt + 1}/$_maxExtremeRecoveryAttempts)',
            );
            await Future.delayed(const Duration(milliseconds: 700));
          }
        }
      }

      if (_userDisconnecting) return;

      debugPrint('[VPN] Extreme recovery exhausted: $lastError');
      await _clearAndroidAllowlist();
      _clearRuntimeSnapshot();
      _errorMessage = 'Could not restore the connection.';
      _setStatus(VpnStatus.error, 'Reconnect failed');
    } finally {
      _restartInProgress = false;
    }
  }

  Future<void> _stopRuntime() async {
    try {
      await _vless.stopVless().timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  Future<void> disconnect() async {
    _cancelled = true;
    _userDisconnecting = true;
    _restartTimer?.cancel();
    HivemindService.cancel();

    if (_status == VpnStatus.disconnected ||
        _status == VpnStatus.disconnecting) {
      await _clearAndroidAllowlist();
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

    bool timedOut = false;
    try {
      await _vless.stopVless().timeout(
            const Duration(seconds: 5),
            onTimeout: () => timedOut = true,
          );
    } catch (e) {
      debugPrint('[VPN] VLESS stop error: $e');
      _errorMessage = 'VPN shutdown error.\nPlease restart the app.';
      await _clearAndroidAllowlist();
      _clearRuntimeSnapshot();
      _setStatus(VpnStatus.error, 'Shutdown failed');
      _userDisconnecting = false;
      return;
    }

    await _clearAndroidAllowlist();

    if (timOut) {
      debugPrint('[VPN] stopVless() timed out after 5 s.');
      _errorMessage = 'VPN did not shut down cleanly.\nPlease restart the app.';
      _clearRuntimeSnapshot();
      _setStatus(VpnStatus.error, 'Shutdown failed');
      _userDisconnecting = false;
      return;
    }

    _errorMessage = null;
    _clearRuntimeSnapshot();
    _setStatus(VpnStatus.disconnected, 'Tap to connect');
    _userDisconnecting = false;
  }

  Future<void> _clearAndroidAllowlist() async {
    try {
      await FlutterVlessAndroidRouting.setAllowedApps(const <String>[]);
    } catch (_) {}
  }

  void _clearRuntimeSnapshot() {
    _lastBaseConfig = null;
    _lastBlockedApps = null;
    _lastAllowedApps = const <String>[];
    _lastProxyOnly = false;
    _lastVerifyLocalSocks = false;
    _appSpecificRoutingActive = false;
    _lastHealthLatencyMs = null;
    _isStartupRestoration = false;
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
    _networkSubscription?.cancel();
    if (_status == VpnStatus.connected || _status == VpnStatus.connecting) {
      unawaited(_clearAndroidAllowlist());
      try {
        _vless.stopVless();
      } catch (_) {}
    }
    super.dispose();
  }
}
