import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:revoltvpn/logic/crypto_service.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';
import 'package:revoltvpn/logic/vpn_start_guard.dart';
import 'package:revoltvpn/logic/session_stop_barrier.dart';

enum VpnStatus {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error,
}

class VpnConnection extends ChangeNotifier {
  bool _cancelled = false;
  bool _connectInFlight = false;
  bool _disposed = false;
  final VpnStartGuard _startGuard = VpnStartGuard();
  final SessionStopBarrier _disconnectBarrier = SessionStopBarrier();
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
      // Do not start background health/revocation recovery until the startup
      // ownership gate and native restoration checks have fully settled.
      // Earlier scheduling raced the initial pending-stop decision and could
      // consume the marker before native teardown was checked.
      if (!kIsWeb && !_disposed) {
        _healthTimer ??=
            Timer.periodic(const Duration(seconds: 30), (_) => _checkHealth());
        unawaited(_checkHealth());
      }
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

    // A prior explicit disconnect may have lost the network/process before the server confirmed
    // credential revocation. Honor that durable intent before attempting startup restoration.
    if (await CryptoService.isSessionStopPending()) {
      // An unavailable native engine cannot prove that the previous OS VPN
      // has been torn down. Retain a fail-closed restart latch either way.
      var localStopFailed = !_initialized;
      if (!_initialized) {
        _startGuard.blockUnsafeRestart();
        debugPrint('[VPN] Pending revocation: native teardown unavailable.');
      } else {
        try {
          await _vless.stopVless().timeout(const Duration(seconds: 5));
        } catch (e) {
          localStopFailed = true;
          _startGuard.blockUnsafeRestart();
          debugPrint('[VPN] Pending-revocation local stop failed: $e');
        }
      }
      // Revoke the server capability even when local teardown is ambiguous.
      // Never report a clean disconnect or allow a new native start if the
      // previous engine did not confirm that it stopped.
      final resolved = await HivemindService.retryPendingSessionStop();
      _isStartupRestoration = false;
      if (localStopFailed) {
        _errorMessage = resolved
            ? 'The previous VPN tunnel did not shut down cleanly. Restart the app.'
            : 'VPN shutdown failed and server revocation is still pending.';
        _setStatus(VpnStatus.error, 'Shutdown failed');
        return;
      }
      if (resolved) {
        _errorMessage = null;
        _setStatus(VpnStatus.disconnected, 'Tap to connect');
      } else {
        _errorMessage =
            'The local VPN is off, but server credential revocation is still pending.';
        _setStatus(VpnStatus.disconnected, 'Revocation pending');
      }
      return;
    }

    try {
      final coreVersion = await _vless.getCoreVersion();
      debugPrint('[VPN] Xray core version: $coreVersion');

      final delay = await _vless.getConnectedServerDelay();
      if (delay > 0) {
        // Native delay is NOT proof of current server authorization: an old
        // tunnel may survive process restart after its nonce was revoked.
        final ownedNonce = await CryptoService.getSessionNonce();
        final probe = ownedNonce == null
            ? SessionProbeResult.inactive
            : await HivemindService.probeCurrentSession();
        // An explicit revoke intent outranks an earlier status response.
        // This read also closes the initialization-vs-health-recovery window.
        final stopPending = await CryptoService.isSessionStopPending();
        if (_cancelled) return;
        if (probe == SessionProbeResult.active && !stopPending) {
          _startGuard.authorizeConnected();
          _isStartupRestoration = true;
          _setStatus(VpnStatus.connected, 'Secured');
        } else {
          _startGuard.invalidateConnected();
          try {
            await _vless.stopVless().timeout(const Duration(seconds: 5));
            _setStatus(
                stopPending || probe == SessionProbeResult.unavailable
                    ? VpnStatus.error
                    : VpnStatus.disconnected,
                stopPending
                    ? 'Revocation pending'
                    : probe == SessionProbeResult.unavailable
                        ? 'Session verification unavailable'
                        : 'Tap to connect');
          } catch (e) {
            _startGuard.blockUnsafeRestart();
            _errorMessage = 'Unverified native VPN shutdown failed.';
            _setStatus(VpnStatus.error, 'Shutdown failed');
            debugPrint('[VPN] Unverified startup cleanup failed: $e');
          }
        }
      }
    } catch (_) {}
  }

  void _mapStatus(VlessStatus status) {
    if (_disposed) return;
    // Late native events must not resurrect a tunnel after user disconnect.
    if (_cancelled || _status == VpnStatus.disconnecting) return;
    switch (status.connectionState) {
      case VlessConnectionState.connected:
        // A stale native callback is untrusted until the current start future
        // or authenticated startup restoration authorizes this generation.
        if (!_startGuard.mayReportConnected) return;
        _setStatus(VpnStatus.connected, 'Secured');
        break;
      case VlessConnectionState.disconnected:
        if (!_startGuard.mayReportConnected) return;
        _revokeUnexpectedNativeDrop();
        break;
      case VlessConnectionState.connecting:
        if (_status != VpnStatus.connecting) return;
        _setStatus(VpnStatus.connecting, 'Establishing tunnel…');
        break;
      case VlessConnectionState.disconnecting:
        if (!_startGuard.mayReportConnected) return;
        _revokeUnexpectedNativeDrop();
        break;
      case VlessConnectionState.unknown:
        if (_status != VpnStatus.connected &&
            _status != VpnStatus.disconnected) {
          _setStatus(VpnStatus.error, 'Connection failed');
        }
        break;
    }
  }

  /// A native tunnel loss does not authenticate terminal server teardown.
  /// Invoke the same persisted, explicit revoke path as user disconnect;
  /// disconnect synchronously cancels this native generation before its first
  /// storage await. Do not rely on SessionTimer having a live UI listener.
  void _revokeUnexpectedNativeDrop() {
    unawaited(disconnect().catchError((Object error, StackTrace trace) {
      _startGuard.blockUnsafeRestart();
      _isStartupRestoration = false;
      _errorMessage =
          'Native tunnel dropped and server revocation could not be confirmed.';
      _setStatus(VpnStatus.error, 'Revocation failed');
      debugPrint('[VPN] Unexpected native drop cleanup failed: $error');
    }));
  }

  // ── Connect ────────────────────────────────────────────────────────
  //
  // 1. Direct HTTPS to the public API → get per-user VLESS URL
  // 2. Start tunnel directly with that URL (no bootstrap, no switch)
  //
  // The only hardcoded data in the APK is the Reality public key and
  // shortId (needed for every Reality handshake — unavoidable).
  // The tunnel UUID is per-user, assigned by Hivemind via AdMob SSV.

  Future<bool> connect({bool skipAdBypass = false}) async {
    if (_connectInFlight ||
        _disconnectBarrier.isStopping ||
        _status == VpnStatus.connected ||
        _status == VpnStatus.connecting ||
        _status == VpnStatus.disconnecting ||
        _startGuard.cannotRestart) return false;
    _connectInFlight = true;
    try {
      _startGuard.reset();
      return await _connectInner(skipAdBypass: skipAdBypass);
    } finally {
      _connectInFlight = false;
    }
  }

  Future<bool> _connectInner({required bool skipAdBypass}) async {
    _cancelled = false;

    // Defense in depth for callers that bypass AdManager: never reconnect while an explicit
    // previous server revocation remains ambiguous.
    if (!await HivemindService.retryPendingSessionStop()) {
      _errorMessage = 'Previous server session revocation is still pending.';
      _setStatus(VpnStatus.error, 'Revocation pending');
      return false;
    }

    if (_cancelled) return false;

    if (!kIsWeb && !_initialized) {
      _errorMessage = 'VPN service unavailable.';
      _setStatus(VpnStatus.error, 'Service unavailable');
      return false;
    }

    if (!kIsWeb) {
      final ok = await _vless.requestPermission();
      if (_cancelled) return false;
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
      if (_cancelled) return false;
      _setStatus(VpnStatus.connected, 'Secured (dev mode)');
      return true;
    }

    _setStatus(VpnStatus.connecting, 'Fetching config…');

    String realUrl;
    try {
      realUrl = await HivemindService.fetchConfigDirectly(
        skipAdBypass: skipAdBypass,
        onAttempt: (attempt, total) {
          if (_cancelled) return;
          _setStatus(
              VpnStatus.connecting, 'Contacting server ($attempt/$total)…');
        },
      );
    } catch (e) {
      debugPrint('[VPN] Config fetch error: $e');
      final raw = e.toString().replaceAll('Exception: ', '');
      if (_cancelled || raw.contains('Cancelled')) return false;
      if (raw.contains('timed out') || raw.contains('Session not activated')) {
        _errorMessage =
            'The server did not respond in time.\nCheck your connection and try again.';
        _setStatus(VpnStatus.error, 'Server unreachable');
      } else {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _setStatus(VpnStatus.error, 'Config fetch error');
      }
      return false;
    }

    if (_cancelled) return false;

    _setStatus(VpnStatus.connecting, 'Securing connection…');

    var nativeStartAttempted = false;
    try {
      final parsed = FlutterVless.parse(realUrl);

      nativeStartAttempted = true;
      final started = await _startGuard.start(() => _vless.startVless(
            remark: parsed.remark.isNotEmpty ? parsed.remark : 'Revolt VPN',
            config: parsed.getFullConfiguration(),
            // Privacy v2: no application/subnet bypass is permitted in the managed
            // ReVoltVPN profile. AndroidDnsPolicy.proxy installs a virtual resolver
            // whose queries are forwarded through the selected VLESS outbound.
            blockedApps: const <String>[],
            bypassSubnets: const <String>[],
            proxyOnly: false,
            androidDnsPolicy: AndroidDnsPolicy.proxy,
          ));
      if (!started || _cancelled) return false;
    } catch (e) {
      // A rejected native start may still have established part of a TUN.
      // The user's concurrent disconnect owns cleanup if already cancelled.
      if (_cancelled) return false;
      debugPrint('[VPN] Tunnel start error: $e');
      if (nativeStartAttempted) {
        final cleaned = await _startGuard.cleanupFailedStart(
          () => _vless.stopVless().timeout(const Duration(seconds: 5)),
        );
        if (!cleaned) {
          _errorMessage =
              'VPN shutdown could not be confirmed. Restart the app.';
          _setStatus(VpnStatus.error, 'Shutdown failed');
          return false;
        }
      }
      if (_cancelled) return false;
      _errorMessage = 'Tunnel failed to start.\nTry reconnecting.';
      _setStatus(VpnStatus.error, 'Connection failed');
      return false;
    }

    if (_cancelled) return false;
    _startGuard.authorizeConnected();
    _setStatus(VpnStatus.connected, 'Secured');
    return true;
  }

  Future<void> disconnect() {
    // Cancel the native generation synchronously even when an existing stop
    // is underway; all callers must await that SAME exact teardown Future.
    _cancelled = true;
    _startGuard.cancel();
    HivemindService.cancel();
    return _disconnectBarrier.run(_disconnectInner);
  }

  Future<void> _disconnectInner() async {
    final wasLocallyDisconnected = _status == VpnStatus.disconnected;
    _setStatus(VpnStatus.disconnecting, 'Tearing down…');

    // Persist user intent before touching the local tunnel. If the process dies anywhere below,
    // the next launch will retry the authenticated server revoke instead of forgetting it.
    try {
      await CryptoService.setSessionStopPending();
    } catch (e) {
      // The durable stop marker is required for crash recovery. If secure
      // storage rejects the write, do not leave the UI in 'disconnecting' and
      // never permit a new native start in this process. Still attempt local
      // shutdown and authenticated remote revocation as best-effort cleanup.
      _startGuard.blockUnsafeRestart();
      debugPrint('[VPN] Cannot persist stop intent: $e');
      if (!kIsWeb && _initialized) {
        try {
          await _vless.stopVless().timeout(const Duration(seconds: 5));
        } catch (stopError) {
          debugPrint('[VPN] Local stop after storage error failed: $stopError');
        }
      }
      try {
        await HivemindService.stopSession(markPending: false);
      } catch (stopError) {
        debugPrint(
            '[VPN] Remote revoke after storage error failed: $stopError');
      }
      _isStartupRestoration = false;
      _errorMessage =
          'VPN stop intent could not be saved. Shutdown is unverified; restart the app after checking the connection.';
      _setStatus(VpnStatus.error, 'Shutdown not durable');
      return;
    }

    bool localStopFailed = false;
    final nativeStartWasPending = _startGuard.isStarting;
    if (nativeStartWasPending &&
        !await _startGuard.waitForStart(const Duration(seconds: 6))) {
      localStopFailed = true;
      // Native start may complete after our timeout. Tear it down again when
      // that future finally settles, without claiming a successful shutdown.
      _startGuard.stopAfterLateStart(() => _vless.stopVless().timeout(
            const Duration(seconds: 5),
          ));
    }
    if (!kIsWeb &&
        _initialized &&
        (!wasLocallyDisconnected || nativeStartWasPending)) {
      bool timedOut = false;
      try {
        await _vless.stopVless().timeout(
              const Duration(seconds: 5),
              onTimeout: () => timedOut = true,
            );
      } catch (e) {
        debugPrint('[VPN] VLESS stop error: $e');
        localStopFailed = true;
      }

      if (timedOut) {
        debugPrint('[VPN] stopVless() timed out after 5 s — '
            'tunnel may still be active.');
        localStopFailed = true;
      }
    }

    // Revoke the server credential even if local shutdown reported an error. Removing the Xray
    // identity is the safest fallback when the local engine's state is ambiguous.
    late final SessionStopResult stopResult;
    try {
      stopResult = await HivemindService.stopSession(markPending: false);
    } catch (e) {
      // An unexpected secure-store/control-plane error must not leave the UI
      // in 'disconnecting' or make a fresh tunnel start seem permissible.
      // The durable marker remains the retry authority after restart.
      _startGuard.blockUnsafeRestart();
      _isStartupRestoration = false;
      _errorMessage =
          'Server revocation could not be verified. Reconnect is blocked until recovery.';
      _setStatus(VpnStatus.error, 'Revocation unverified');
      debugPrint('[VPN] Session stop did not complete: $e');
      rethrow;
    }
    final revocationPending = stopResult == SessionStopResult.retryNeeded;

    _isStartupRestoration = false;
    if (localStopFailed) {
      // A failed native stop must not be treated as an ordinary UI error:
      // the engine may still own the TUN. Deny any new start this process.
      _startGuard.blockUnsafeRestart();
      _errorMessage = revocationPending
          ? 'VPN shutdown was ambiguous and server credential revocation is still pending.'
          : 'VPN did not shut down cleanly. Please restart the app.';
      _setStatus(VpnStatus.error, 'Shutdown failed');
      return;
    }

    if (revocationPending) {
      _errorMessage =
          'The local VPN is off, but server credential revocation is still pending.';
      _setStatus(VpnStatus.disconnected, 'Revocation pending');
      return;
    }

    _errorMessage = null;
    _setStatus(VpnStatus.disconnected, 'Tap to connect');
  }

  void _setStatus(VpnStatus s, String msg) {
    if (_disposed) return;
    _status = s;
    _statusMessage = msg;
    notifyListeners();
  }

  Future<void> _checkHealth() async {
    if (_disposed) return;
    final reachable = await HivemindService.checkHealth();
    if (_disposed) return;
    _serverReachable = reachable;
    if (_serverReachable && await CryptoService.isSessionStopPending()) {
      if (_disposed) return;
      final resolved = await HivemindService.retryPendingSessionStop();
      if (resolved && _status == VpnStatus.disconnected) {
        _errorMessage = null;
        _setStatus(VpnStatus.disconnected, 'Tap to connect');
        return;
      }
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _healthTimer?.cancel();
    // UI provider disposal is not an authenticated session stop. Do not fire
    // an unawaited native stop that can strand a live server credential.
    // Explicit disconnect and native drop own durable revoke + local cleanup.
    super.dispose();
  }
}
