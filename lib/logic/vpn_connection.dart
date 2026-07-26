// =============================================================================
//  vpn_connection.dart — VLESS VPN Tunnel Manager
//  =============================================================================

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';

// ── VPN States ────────────────────────────────────────────────────────────────
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
        providerBundleIdentifier: 'com.revoltvpn.app',
      );
      _initialized = true;
    } catch (e) {
      debugPrint('[VPN] VLESS init error (expected on emulator): $e');
    }

    // Check if VPN was already running (app killed and reopened)
    try {
      final coreVersion = await _vless.getCoreVersion();
      debugPrint('[VPN] Xray core version: $coreVersion');

      final delay = await _vless.getConnectedServerDelay();
      if (delay > 0) {
        _isStartupRestoration = true;
        _setStatus(VpnStatus.connected, 'Secured');
        Future.delayed(const Duration(seconds: 5), () {
          _isStartupRestoration = false;
        });
      }
    } catch (_) {}
  }

  void _mapStatus(VlessStatus status) {
    switch (status.connectionState) {
      case VlessConnectionState.connected:
        _setStatus(VpnStatus.connected, 'Secured');
        break;
      case VlessConnectionState.disconnected:
        _setStatus(VpnStatus.disconnected, 'Tap to connect');
        break;
      case VlessConnectionState.connecting:
        _setStatus(VpnStatus.connecting, 'Establishing tunnel…');
        break;
      case VlessConnectionState.disconnecting:
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

  // ── Connect ───────────────────────────────────────────────────────────────
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

    _setStatus(VpnStatus.connecting, 'Fetching config…');
    _errorMessage = null;

    if (kIsWeb) {
      await Future.delayed(const Duration(seconds: 1));
      _setStatus(VpnStatus.connected, 'Secured (dev mode)');
      return true;
    }

    // ── Step 1: Fetch VLESS URL from Hivemind ──────────────────────────
    String vlessUrl;
    try {
      vlessUrl = await HivemindService.fetchConfigWithPolling(
        onAttempt: (attempt, total) {
          _setStatus(VpnStatus.connecting, 'Contacting server ($attempt/$total)…');
        },
      );
    } catch (e) {
      debugPrint('[VPN] Hivemind config error: $e');
      final raw = e.toString().replaceAll('Exception: ', '');
      if (raw.contains('AWG protocol') || raw.contains('old AWG')) {
        _errorMessage = 'Server update required.\nThe VPN server needs to be upgraded to VLESS.';
        _setStatus(VpnStatus.error, 'Server outdated');
      } else if (raw.contains('timed out') || raw.contains('Session not activated')) {
        _errorMessage = 'The server did not respond in time.\nCheck your connection and try again.';
        _setStatus(VpnStatus.error, 'Server unreachable');
      } else if (raw.contains('SocketException') || raw.contains('Failed host lookup')) {
        _errorMessage = 'Cannot reach the server.\nMake sure you have internet access.';
        _setStatus(VpnStatus.error, 'No internet');
      } else {
        _errorMessage = raw;
        final short = raw.length > 35 ? '${raw.substring(0, 35)}…' : raw;
        _setStatus(VpnStatus.error, short);
      }
      return false;
    }

    // ── Step 2: Check for cancellation ────────────────────────────────
    if (_cancelled) {
      _setStatus(VpnStatus.disconnected, 'Tap to connect');
      return false;
    }

    // ── Step 3: Parse and start VLESS tunnel ───────────────────────────
    try {
      final parsed = FlutterVless.parse(vlessUrl);
      final config = parsed.getFullConfiguration();

      await _vless.startVless(
        remark: parsed.remark.isNotEmpty ? parsed.remark : 'ReVoltVPN',
        config: config,
      );

      // Give the tunnel a moment to stabilise
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
        debugPrint('[VPN] Tunnel started but no server session — tearing down.');
        try {
          await _vless.stopVless();
        } catch (_) {}
        _errorMessage = 'Session not confirmed by server.\nPlease try again.';
        _setStatus(VpnStatus.error, 'Session rejected');
        return false;
      }

      _setStatus(VpnStatus.connected, 'Secured');
      return true;
    } catch (e) {
      debugPrint('[VPN] VLESS tunnel error: $e');
      _errorMessage = 'Tunnel failed to start.\nTry reconnecting.';
      _setStatus(VpnStatus.error, 'Connection failed');
      return false;
    }
  }

  // ── Disconnect ────────────────────────────────────────────────────────────
  Future<void> disconnect() async {
    _cancelled = true;
    if (_status == VpnStatus.disconnected || _status == VpnStatus.disconnecting) {
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

    HivemindService.disconnectAndCleanup();
    _setStatus(VpnStatus.disconnected, 'Tap to connect');
  }

  void _setStatus(VpnStatus s, String msg) {
    _status = s;
    _statusMessage = msg;
    notifyListeners();
  }

  @override
  void dispose() {
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
