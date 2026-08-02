import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';
import 'package:revoltvpn/logic/app_config.dart';

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

  // True when the app was killed and reopened while the VPN was running.
  bool _isStartupRestoration = false;
  bool get isStartupRestoration => _isStartupRestoration;

  bool _serverReachable = false;
  bool get serverReachable => _serverReachable;

  Timer? _healthTimer;

  late final FlutterVless _vless;
  bool _initialized = false;

  VpnConnection() {
    _init();
  }

  Future<void> _init() async {
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
      );
      _initialized = true;
    } catch (e) {
      debugPrint('[VPN] VLESS init error (expected on emulator): $e');
    }

    // Periodic server health check — now goes through the tunnel
    // (AppConfig.hivemindApiBase = http://10.254.254.1:5000/api)
    _checkHealth();
    _healthTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _checkHealth());

    // Check if VPN was already running (app killed and reopened)
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
        // Native backend emitted an unrecognized state — treat as error
        // only if we aren't already in a terminal state.
        if (_status != VpnStatus.connected &&
            _status != VpnStatus.disconnected) {
          _setStatus(VpnStatus.error, 'Connection failed');
        }
        break;
    }
  }

  // ── Connect (V2: bootstrap → poll → real tunnel) ────────────────────
  //
  // Flow:
  //   1. Connect with hardcoded bootstrap VLESS URL (bundle in APK)
  //   2. Through bootstrap tunnel, poll 10.254.254.1:5000 for real config
  //   3. Disconnect bootstrap
  //   4. Connect with real per-session VLESS URL
  //
  // Parameter quickReconnect is used by the session timer for throttle
  // port-swaps — same bootstrap flow, but skip the AdMob bypass (session
  // is already active).

  Future<bool> connect(
      {bool skipAdBypass = false, bool quickReconnect = false}) async {
    if (_status == VpnStatus.connected || _status == VpnStatus.connecting) {
      return false;
    }
    _cancelled = false;

    if (!kIsWeb && !_initialized) {
      _errorMessage = 'VPN service unavailable.';
      _setStatus(VpnStatus.error, 'Service unavailable');
      return false;
    }

    _setStatus(VpnStatus.connecting, 'Establishing secure channel…');
    _errorMessage = null;

    if (kIsWeb) {
      await Future.delayed(const Duration(seconds: 1));
      _setStatus(VpnStatus.connected, 'Secured (dev mode)');
      return true;
    }

    // ── Phase 1: Bootstrap tunnel ────────────────────────────────────
    try {
      final bootstrapParsed = FlutterVless.parse(AppConfig.bootstrapVlessUrl);
      await _vless.startVless(
        remark: 'ReVoltVPN-Bootstrap',
        config: bootstrapParsed.getFullConfiguration(),
      );
    } catch (e) {
      debugPrint('[VPN] Bootstrap tunnel error: $e');
      _errorMessage = 'Tunnel failed to start.\nTry reconnecting.';
      _setStatus(VpnStatus.error, 'Connection failed');
      return false;
    }

    if (_cancelled) {
      await _safeStopVless();
      _setStatus(VpnStatus.disconnected, 'Tap to connect');
      return false;
    }

    // Let the bootstrap tunnel stabilise before API calls
    await Future.delayed(const Duration(seconds: 1));

    // ── Phase 2: Fetch real config through bootstrap tunnel ──────────
    _setStatus(VpnStatus.connecting, 'Fetching config…');

    String realUrl;
    try {
      realUrl = await HivemindService.fetchConfigThroughTunnel(
        skipAdBypass: skipAdBypass,
        onAttempt: (attempt, total) {
          if (!quickReconnect) {
            _setStatus(
                VpnStatus.connecting, 'Contacting server ($attempt/$total)…');
          }
        },
      );
    } catch (e) {
      debugPrint('[VPN] Config fetch error: $e');
      await _safeStopVless();

      final raw = e.toString().replaceAll('Exception: ', '');
      if (raw.contains('Cancelled')) {
        return false;
      } else if (raw.contains('timed out') ||
          raw.contains('Session not activated')) {
        _errorMessage =
            'The server did not respond in time.\nCheck your connection and try again.';
        _setStatus(VpnStatus.error, 'Server unreachable');
      } else {
        _errorMessage = raw;
        final short = raw.length > 35 ? '${raw.substring(0, 35)}…' : raw;
        _setStatus(VpnStatus.error, short);
      }
      return false;
    }

    if (_cancelled) {
      await _safeStopVless();
      _setStatus(VpnStatus.disconnected, 'Tap to connect');
      return false;
    }

    // ── Phase 3: Switch to real tunnel ───────────────────────────────
    _setStatus(VpnStatus.connecting, 'Securing connection…');
    await _safeStopVless();

    try {
      final realParsed = FlutterVless.parse(realUrl);
      await _vless.startVless(
        remark: realParsed.remark.isNotEmpty ? realParsed.remark : 'ReVoltVPN',
        config: realParsed.getFullConfiguration(),
      );
    } catch (e) {
      debugPrint('[VPN] Real tunnel error: $e');
      _errorMessage = 'Tunnel failed to start.\nTry reconnecting.';
      _setStatus(VpnStatus.error, 'Connection failed');
      return false;
    }

    if (quickReconnect) {
      _setStatus(VpnStatus.connected, 'Secured');
    } else {
      // Give the tunnel a moment to stabilise, then verify
      _setStatus(VpnStatus.connecting, 'Verifying session…');
      await Future.delayed(const Duration(seconds: 1));

      bool sessionOk = false;
      for (int attempt = 0; attempt < 2; attempt++) {
        sessionOk = await HivemindService.verifySession();
        if (sessionOk) break;
        if (attempt == 0) {
          debugPrint('[VPN] verifySession attempt 1 failed, retrying…');
          await Future.delayed(const Duration(seconds: 2));
        }
      }

      if (!sessionOk) {
        debugPrint(
            '[VPN] Tunnel started but no server session — tearing down.');
        try {
          await _vless.stopVless();
        } catch (_) {}
        _errorMessage = 'Session not confirmed by server.\nPlease try again.';
        _setStatus(VpnStatus.error, 'Session rejected');
        return false;
      }

      _setStatus(VpnStatus.connected, 'Secured');
    }
    return true;
  }

  Future<void> disconnect({bool skipCleanup = false}) async {
    _cancelled = true;
    HivemindService.cancel(); // abort any in-progress polling
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

    try {
      await _vless.stopVless().timeout(
            const Duration(seconds: 5),
            onTimeout: () => debugPrint('[VPN] stopVless() timed out.'),
          );
    } catch (e) {
      debugPrint('[VPN] VLESS stop error: $e');
    }

    if (!skipCleanup) {
      HivemindService.disconnectAndCleanup();
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

  Future<void> _safeStopVless() async {
    try {
      await _vless.stopVless().timeout(
            const Duration(seconds: 5),
            onTimeout: () => debugPrint('[VPN] Bootstrap stopVless() timed out.'),
          );
    } catch (e) {
      debugPrint('[VPN] Bootstrap stop error: $e');
    }
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    if (_status == VpnStatus.connected || _status == VpnStatus.connecting) {
      try {
        _vless.stopVless();
      } catch (_) {
        // Best-effort — widget is being destroyed anyway
      }
    }
    super.dispose();
  }
}
