// =============================================================================
//  vpn_connection.dart — WireGuard Tunnel Manager
//  ─────────────────────────────────────────────────────────────────────────────
//  This file manages the WireGuard tunnel on the Android device.
//  It is the bridge between the UI (the big connect button) and the actual
//  VPN tunnel running inside the Android operating system.
//
//  HOW IT WORKS:
//  1. When connect() is called, it first asks WgApiService to fetch the config
//     file for this device from the server (see wg_api_service.dart).
//  2. It passes that config text to the wireguard_flutter plugin, which handles
//     all the native Android VPN stuff automatically.
//  3. It listens to the native tunnel state and updates the UI accordingly.
//
//  You never need to edit this file.
//  Server settings → app_config.dart
//  Server communication → wg_api_service.dart
// =============================================================================

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:wireguard_flutter/wireguard_flutter.dart';
import 'package:paladinvpn/logic/app_config.dart';
import 'package:paladinvpn/logic/hivemind_service.dart';

// ── VPN States ────────────────────────────────────────────────────────────────
// These are the possible states the tunnel can be in.
// The UI uses these to decide what to display (spinner, shield icon, etc.)
enum VpnStatus {
  disconnected,  // No tunnel active — idle state
  connecting,    // Fetching config from server + starting tunnel
  connected,     // Tunnel is up and routing traffic
  disconnecting, // Tearing down the tunnel
  error,         // Something went wrong (server unreachable, etc.)
}

// ── VpnConnection ─────────────────────────────────────────────────────────────
// This is a "ChangeNotifier" — it works like a Python observable/event emitter.
// Whenever the state changes, it automatically notifies all widgets that are
// listening, and they re-render themselves. You never call setState() manually.
class VpnConnection extends ChangeNotifier {
  // Current tunnel state (starts disconnected)
  VpnStatus _status = VpnStatus.disconnected;
  VpnStatus get status => _status;

  bool _pluginAvailable = false;

  // True only during the brief window after startup where we detected an
  // already-running tunnel — lets SessionTimer know to auto-resume.
  bool _isStartupRestoration = false;
  bool get isStartupRestoration => _isStartupRestoration;

  // Short message shown to the user under the connect button
  String _statusMessage = 'Tap to connect';
  String get statusMessage => _statusMessage;

  // Optional error message shown if something goes wrong
  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  // The internal WireGuard IP assigned to this device (e.g. 10.8.0.2)
  // Populated after a successful config fetch and used by SessionTimer.
  String? internalIp;

  // The wireguard_flutter plugin instance — this is what actually talks to Android
  final _wireguard = WireGuardFlutter.instance;

  // Subscription to the native tunnel state stream
  StreamSubscription? _stageSub;

  // ── Initialization ────────────────────────────────────────────────────────
  // Called automatically when the app starts (via Provider in main.dart)
  VpnConnection() {
    _init();
  }

  Future<void> _init() async {
    // WireGuard doesn't work in a web browser — skip on web
    if (kIsWeb) return;

    try {
      // Register our tunnel interface with Android.
      // 'Paladin0' is just the name of the network interface — like "eth0"
      await _wireguard.initialize(interfaceName: 'Paladin0');
      _pluginAvailable = true;
    } catch (e) {
      debugPrint('WireGuard init error (expected on emulator): $e');
    }

    // Start listening to native tunnel state changes from Android.
    // When Android reports the tunnel went up/down, _mapStage() is called.
    try {
      _stageSub = _wireguard.vpnStageSnapshot.listen(_mapStage);
    } catch (_) {}

    // Check if the VPN was already running before the app started.
    // This handles the case where the user swiped the app away and reopened it.
    try {
      final currentStage = await _wireguard.stage();
      if (currentStage == VpnStage.connected) {
        _isStartupRestoration = true;
        _mapStage(currentStage);
        // Clear the flag after a few seconds — only needed during app startup
        Future.delayed(const Duration(seconds: 5), () {
          _isStartupRestoration = false;
        });
      }
    } catch (_) {}
  }

  // ── Native State Mapping ──────────────────────────────────────────────────
  // Android sends back low-level states like "authenticating", "preparing", etc.
  // This function translates those into our simpler 5-state enum above.
  void _mapStage(VpnStage stage) {
    switch (stage) {
      case VpnStage.connected:
        _setStatus(VpnStatus.connected, 'Secured');
        break;
      case VpnStage.disconnected:
        _setStatus(VpnStatus.disconnected, 'Tap to connect');
        break;
      case VpnStage.connecting:
      case VpnStage.waitingConnection:
      case VpnStage.authenticating:
      case VpnStage.preparing:
      case VpnStage.reconnect:
        _setStatus(VpnStatus.connecting, 'Establishing tunnel…');
        break;
      case VpnStage.disconnecting:
      case VpnStage.exiting:
        _setStatus(VpnStatus.disconnecting, 'Tearing down…');
        break;
      default:
        _setStatus(VpnStatus.disconnected, 'Tap to connect');
        break;
    }
  }

  // ── Connect ───────────────────────────────────────────────────────────────
  // This is the main function — called after the user watches the rewarded ad.
  //
  // Step 1: Call the WG-Easy API to get the .conf for this device
  // Step 2: Pass that .conf to the WireGuard plugin to start the tunnel
  //
  // Returns true if the connection was successful, false if it failed.
  // The connect button uses this to decide whether to start the timer.
  Future<bool> connect() async {
    // Don't do anything if we're already connected or currently connecting
    if (_status == VpnStatus.connected || _status == VpnStatus.connecting) {
      return false;
    }

    // Guard: native plugin never loaded (wrong arch, missing .so)
    if (!kIsWeb && !_pluginAvailable) {
      _errorMessage = 'VPN service unavailable. The native tunnel library '
          'could not be loaded on this device.';
      _setStatus(VpnStatus.error, 'Service unavailable');
      return false;
    }

    _setStatus(VpnStatus.connecting, 'Fetching config…');
    _errorMessage = null;

    // ── Web / emulator fallback ────────────────────────────────────────────
    if (kIsWeb) {
      await Future.delayed(const Duration(seconds: 1));
      _setStatus(VpnStatus.connected, 'Secured (dev mode)');
      return true;
    }

    // ── Step 1: Fetch WireGuard config from Hivemind ────────────────────
    String configText;
    try {
      configText = await HivemindService.fetchConfigWithPolling(
        onAttempt: (attempt, total) {
          _setStatus(VpnStatus.connecting, 'Contacting server ($attempt/$total)…');
        },
      );

      // Parse the internal IP (e.g. "Address = 10.8.0.2/16" or "/32")
      final regex = RegExp(r'Address\s*=\s*([0-9\.]+)/');
      final match = regex.firstMatch(configText);
      if (match != null) {
        internalIp = match.group(1);
      }
    } catch (e) {
      debugPrint('Hivemind config error: $e');
      final raw = e.toString().replaceAll('Exception: ', '');
      // Map the known failures to something the user can act on
      if (raw.contains('timed out') || raw.contains('Session not activated')) {
        _errorMessage = 'The server did not respond in time.\n'
            'Check your internet connection and try again.';
        _setStatus(VpnStatus.error, 'Server unreachable');
      } else if (raw.contains('SocketException') ||
                 raw.contains('Failed host lookup')) {
        _errorMessage = 'Cannot reach the VPN server.\n'
            'Make sure you have an active internet connection.';
        _setStatus(VpnStatus.error, 'No internet');
      } else {
        _errorMessage = raw;
        final short = raw.length > 35 ? '${raw.substring(0, 35)}…' : raw;
        _setStatus(VpnStatus.error, short);
      }
      return false;
    }

    // ── Step 2: Start the WireGuard tunnel with the fetched config ──────
    try {
      // Re-initialize to ensure VPN permission is granted before starting
      await _wireguard.initialize(interfaceName: 'Paladin0');
      await _wireguard.startVpn(
        serverAddress: AppConfig.serverEndpoint,
        wgQuickConfig: configText,
        providerBundleIdentifier: 'com.paladinvpn.app.WireGuardProvider',
      );

      // ── Step 3: Verify the server session is alive ──────────────────
      // The tunnel is up but the server might not have a session yet.
      // Do a quick one-shot status check before telling the UI we're
      // connected — if the session doesn't exist, tear down and fail.
      _setStatus(VpnStatus.connecting, 'Verifying session…');
      final sessionOk = await HivemindService.verifySession();
      if (!sessionOk) {
        debugPrint('[VPN] Tunnel started but no server session — tearing down.');
        try {
          await _wireguard.stopVpn().timeout(const Duration(seconds: 3));
        } catch (_) {}
        _errorMessage = 'Session not confirmed by server.\n'
            'Please try again.';
        _setStatus(VpnStatus.error, 'Session rejected');
        return false;
      }

      _setStatus(VpnStatus.connected, 'Secured');
      return true;
    } catch (e) {
      debugPrint('WireGuard tunnel error: $e');
      final raw = e.toString();
      if (raw.contains('VPN_PERMISSION_REQUESTED')) {
        // Native plugin showed the VPN permission dialog — wait and retry
        _setStatus(VpnStatus.connecting, 'Waiting for permission…');
        await Future.delayed(const Duration(seconds: 2));
        // Retry the tunnel start once the user has had time to grant permission
        try {
          await _wireguard.startVpn(
            serverAddress: AppConfig.serverEndpoint,
            wgQuickConfig: configText,
            providerBundleIdentifier: 'com.paladinvpn.app.WireGuardProvider',
          );
          _setStatus(VpnStatus.connected, 'Secured');
          return true;
        } catch (retryError) {
          debugPrint('WireGuard retry error: $retryError');
          _errorMessage = 'VPN permission was denied.\n'
              'Please grant the VPN permission and try again.';
          _setStatus(VpnStatus.error, 'Permission denied');
          return false;
        }
      } else if (raw.contains('Permission') || raw.contains('permissions')) {
        _errorMessage = 'VPN permission was denied.\n'
            'Please grant the VPN permission and try again.';
        _setStatus(VpnStatus.error, 'Permission denied');
      } else if (raw.contains('NameInvalid') || raw.contains('invalid')) {
        _errorMessage = 'The WireGuard configuration is invalid.\n'
            'Please contact support.';
        _setStatus(VpnStatus.error, 'Bad config');
      } else {
        _errorMessage = 'Tunnel failed to start.\nTry reconnecting.';
        _setStatus(VpnStatus.error, 'Tunnel error');
      }
      return false;
    }
  }

  // ── Disconnect ────────────────────────────────────────────────────────────
  // Tears down the active tunnel and returns Android to normal networking.
  Future<void> disconnect() async {
    if (_status == VpnStatus.disconnected || _status == VpnStatus.disconnecting) {
      return; // Already disconnecting or disconnected — don't double-fire
    }

    _setStatus(VpnStatus.disconnecting, 'Tearing down…');

    if (kIsWeb) {
      await Future.delayed(const Duration(milliseconds: 500));
      _setStatus(VpnStatus.disconnected, 'Tap to connect');
      return;
    }

    // Stop the VPN tunnel with a hard timeout.
    // stopVpn() can hang indefinitely if the native Go backend is stuck —
    // we give it 5 seconds max, then force through.
    try {
      await _wireguard.stopVpn().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('[VPN] stopVpn() timed out — forcing disconnect state.');
        },
      );
    } catch (e) {
      debugPrint('WireGuard stop error: $e');
    }

    // Clean up the peer from the server so we don't leave dead connections lying around.
    // Fire-and-forget with a short timeout — server cleanup failing should never
    // block the local disconnect from completing.
    HivemindService.disconnectAndCleanup();

    _setStatus(VpnStatus.disconnected, 'Tap to connect');
  }

  // ── Internal state updater ────────────────────────────────────────────────
  // Updates state and triggers a UI re-render (like calling setState() in Python/Qt)
  void _setStatus(VpnStatus s, String msg) {
    _status = s;
    _statusMessage = msg;
    notifyListeners(); // tells all listening widgets to rebuild
  }

  @override
  void dispose() {
    _stageSub?.cancel();
    super.dispose();
  }
}
