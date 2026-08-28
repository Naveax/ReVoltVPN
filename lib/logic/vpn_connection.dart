import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';

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

  Timer? _healthTimer;

  late final FlutterVless _vless;
  bool _initialized = false;
  final Completer<void> _readyCompleter = Completer<void>();
  Future<void> get ready => _readyCompleter.future;

  VpnConnection() {
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

    _checkHealth();
    _healthTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _checkHealth());

    try {
      final coreVersion = await _vless.getCoreVersion();
      debugPrint('[VPN] Xray core version: $coreVersion');

      final delay = await _vless.getConnectedServerDelay();
      if (delay > 0) {
        _isStartupRestoration = true;
        _setStatus(VpnStatus.connected, 'Secured');
      }
    } catch (_) {}
  }

  void _mapStatus(VlessStatus status) {
    switch (status.connectionState) {
      case VlessConnectionState.connected:
        _setStatus(VpnStatus.connected, 'Secured');
        break;
      case VlessConnectionState.disconnected:
        _isStartupRestoration = false;
        _setStatus(VpnStatus.disconnected, 'Tap to connect');
        break;
      case VlessConnectionState.connecting:
        _setStatus(VpnStatus.connecting, 'Establishing tunnel…');
        break;
      case VlessConnectionState.disconnecting:
        _isStartupRestoration = false;
        _setStatus(VpnStatus.disconnecting, 'Tearing down…');
        break;
      case VlessConnectionState.unknown:
        if (_status != VpnStatus.connected &&
            _status != VpnStatus.disconnected) {
          _setStatus(VpnStatus.error, 'Connection failed');
        }
        break;
    }
  }

  Future<bool> connect() async {
    if (_status == VpnStatus.connected || _status == VpnStatus.connecting) {
      return false;
    }
    _cancelled = false;

    if (!kIsWeb && !_initialized) {
      _errorMessage = 'VPN service unavailable.';
      _setStatus(VpnStatus.error, 'Service unavailable');
      return false;
    }

    if (!kIsWeb) {
      final ok = await _vless.requestPermission();
      if (!ok) {
        _errorMessage = 'VPN permission denied.';
        _setStatus(VpnStatus.error, 'Permission required');
        return false;
      }
    }

    _setStatus(VpnStatus.connecting, 'Establishing secure channel…');
    _errorMessage = null;

    if (kIsWeb) {
      await Future.delayed(const Duration(seconds: 1));
      _setStatus(VpnStatus.connected, 'Secured (dev mode)');
      return true;
    }

    _setStatus(VpnStatus.connecting, 'Waiting for verified session…');

    String realUrl;
    try {
      realUrl = await HivemindService.fetchConfigDirectly(
        onAttempt: (attempt, total) {
          _setStatus(
            VpnStatus.connecting,
            'Verifying reward ($attempt/$total)…',
          );
        },
      );
    } catch (e) {
      debugPrint('[VPN] Config fetch error: $e');
      final raw = e.toString().replaceAll('Exception: ', '');
      if (raw.contains('Cancelled')) return false;

      if (raw.contains('timed out') || raw.contains('Session not activated')) {
        _errorMessage =
            'The rewarded session was not verified in time.\nTry again.';
        _setStatus(VpnStatus.error, 'Verification failed');
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

    _setStatus(VpnStatus.connecting, 'Securing connection…');

    try {
      final parsed = FlutterVless.parse(realUrl);

      await _vless.startVless(
        remark: parsed.remark.isNotEmpty ? parsed.remark : 'Revolt VPN',
        config: parsed.getFullConfiguration(),
      );
    } catch (e) {
      debugPrint('[VPN] Tunnel start error: $e');
      _errorMessage = 'Tunnel failed to start.\nTry reconnecting.';
      _setStatus(VpnStatus.error, 'Connection failed');
      return false;
    }

    _setStatus(VpnStatus.connected, 'Secured');
    return true;
  }

  Future<void> disconnect() async {
    _cancelled = true;
    HivemindService.cancel();
    if (_status == VpnStatus.disconnected ||
        _status == VpnStatus.disconnecting) {
      return;
    }

    _setStatus(VpnStatus.disconnecting, 'Tearing down…');

    if (kIsWeb) {
      await Future.delayed(const Duration(milliseconds: 500));
      _setStatus(VpnStatus.disconnected, 'Tap to connect');
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
      return;
    }

    if (timedOut) {
      debugPrint('[VPN] stopVless() timed out after 5 s; '
          'tunnel may still be active.');
      _errorMessage = 'VPN did not shut down cleanly.\nPlease restart the app.';
      _setStatus(VpnStatus.error, 'Shutdown failed');
      return;
    }

    _setStatus(VpnStatus.disconnected, 'Tap to connect');
  }

  void _setStatus(VpnStatus s, String msg) {
    _status = s;
    _statusMessage = msg;
    notifyListeners();
  }

  Future<void> _checkHealth() async {
    _serverReachable = await HivemindService.checkHealth();
    notifyListeners();
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    if (_status == VpnStatus.connected || _status == VpnStatus.connecting) {
      try {
        _vless.stopVless();
      } catch (_) {}
    }
    super.dispose();
  }
}
