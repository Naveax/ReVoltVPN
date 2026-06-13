import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:paladinvpn/logic/app_config.dart';
import 'package:paladinvpn/logic/vpn_connection.dart';
import 'package:paladinvpn/logic/crypto_service.dart';
import 'package:paladinvpn/components/notification.dart';

/// SessionTimer is the client-side session authority for the VPN tunnel.
///
/// Polls the Hivemind API to sync remaining time, data quotas, speed, and
/// throttling status.  Rather than guessing the session length optimistically,
/// it waits for the first successful sync before the local countdown begins.
class SessionTimer extends ChangeNotifier {
  Timer? _timer;
  int _tickCount = 0;

  final VpnConnection vpnConnection;

  // ── Session State ──────────────────────────────────────────────────────────
  int _remainingSeconds = 0;
  int _quotaBytes      = 0;
  int _usedBytes       = 0;
  bool _isThrottled    = false;

  // ── Sync / Network Health ──────────────────────────────────────────────────
  bool _hasSyncedOnce       = false;
  int  _consecutiveFailures = 0;
  bool _isDisconnecting     = false;

  /// Maximum consecutive sync failures before the local countdown is paused
  /// to avoid showing a false "expired" state while the network is down.
  static const int _maxConsecutiveFailures = 3;

  /// Seconds between server polls (reduced from 3 to ease server load).
  static const int _pollIntervalSeconds = 5;

  // ── Speed State ────────────────────────────────────────────────────────────
  int    _lastUsedBytes    = 0;
  double _currentSpeedKbps = 0.0;

  // ── Notification dedup ─────────────────────────────────────────────────────
  String _lastNotifTime  = '';
  String _lastNotifSpeed = '';

  SessionTimer({required this.vpnConnection}) {
    vpnConnection.addListener(_onVpnConnectionChanged);
  }

  // ── Public Getters ─────────────────────────────────────────────────────────

  int  get remaining        => _remainingSeconds;
  bool get isRunning        => _timer != null && _timer!.isActive;
  bool get isExpired        => _remainingSeconds <= 0 && !isRunning;
  bool get hasSyncedOnce    => _hasSyncedOnce;

  int    get quotaBytes     => _quotaBytes;
  int    get usedBytes      => _usedBytes;
  int    get remainingBytes => _quotaBytes > _usedBytes ? _quotaBytes - _usedBytes : 0;
  bool   get isThrottled    => _isThrottled;
  double get currentSpeedKbps => _currentSpeedKbps;

  String get formatted {
    final h = (_remainingSeconds ~/ 3600).toString().padLeft(2, '0');
    final m = ((_remainingSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (_remainingSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String get formattedDataRemaining {
    if (_quotaBytes == 0) return '0.00 GB';
    final gb = remainingBytes / (1024 * 1024 * 1024);
    return '${gb.toStringAsFixed(2)} GB';
  }

  String get formattedDataUsed {
    if (_usedBytes == 0) return '0.00 MB';
    if (_usedBytes > 1024 * 1024 * 1024) {
      final gb = _usedBytes / (1024 * 1024 * 1024);
      return '${gb.toStringAsFixed(2)} GB';
    }
    final mb = _usedBytes / (1024 * 1024);
    return '${mb.toStringAsFixed(2)} MB';
  }

  double get progress {
    if (_quotaBytes == 0) return 0.0;
    return (_quotaBytes - _usedBytes) / _quotaBytes;
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Fires whenever VpnConnection state changes.
  /// Only auto-restarts the timer during startup restoration —
  /// normal connects are driven by [ConnectButton].
  void _onVpnConnectionChanged() {
    if (vpnConnection.status == VpnStatus.connected &&
        !isRunning &&
        vpnConnection.isStartupRestoration) {
      start('resume');
    }
  }

  /// Starts the local countdown and begins server polling.
  ///
  /// Values are initialised at 0 — the UI shows "Syncing…" until the first
  /// successful [_syncWithHivemind] returns real data.
  Future<void> start(String adType) async {
    _remainingSeconds    = 0;
    _quotaBytes          = 0;
    _usedBytes           = 0;
    _lastUsedBytes       = 0;
    _currentSpeedKbps    = 0.0;
    _isThrottled         = false;
    _tickCount           = 0;
    _hasSyncedOnce       = false;
    _consecutiveFailures = 0;
    _isDisconnecting     = false;

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);

    notifyListeners();

    // Kick off the first sync — the UI will show real data as soon as it lands.
    _syncWithHivemind();
  }

  void _tick(Timer t) {
    // Only decrement the local clock after the first successful sync
    // and while we are not in a network-blackout window.
    if (_hasSyncedOnce && _consecutiveFailures < _maxConsecutiveFailures) {
      if (_remainingSeconds > 0) {
        _remainingSeconds--;
      }
    }

    _tickCount++;
    if (_tickCount % _pollIntervalSeconds == 0) {
      _syncWithHivemind();
    }

    notifyListeners();
  }

  // ── Server Sync ────────────────────────────────────────────────────────────

  Future<void> _syncWithHivemind() async {
    // Never sync while the user is explicitly disconnecting.
    if (_isDisconnecting) return;

    try {
      final deviceId = await CryptoService.getDeviceId();
      final url = Uri.parse(
          '${AppConfig.hivemindApiBase}/session/status?device_id=$deviceId');
      final response = await http.get(url).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        final bool active = data['active'] ?? false;
        if (!active) {
          // Server killed the session!
          stop();
          vpnConnection.disconnect();
          return;
        }

        _remainingSeconds = data['expires_in_seconds'] ?? _remainingSeconds;
        _quotaBytes       = data['quota_bytes']       ?? _quotaBytes;
        _usedBytes        = data['used_bytes']        ?? _usedBytes;
        _isThrottled      = data['is_throttled']      ?? false;

        // ── Speed calculation over the polling interval ────────────────────
        final int deltaBytes = _usedBytes - _lastUsedBytes;
        if (_hasSyncedOnce && deltaBytes > 0) {
          _currentSpeedKbps = (deltaBytes / _pollIntervalSeconds) / 1024;
        } else if (!_hasSyncedOnce) {
          _currentSpeedKbps = 0.0;
        }
        _lastUsedBytes = _usedBytes;

        // ── Network is healthy — reset failure counter ─────────────────────
        _consecutiveFailures = 0;
        _hasSyncedOnce = true;

        // ── Update notification (only when values actually change) ─────────
        final speedText = _currentSpeedKbps > 0.5
            ? '${_currentSpeedKbps.toStringAsFixed(1)} KB/s'
            : 'Idle';
        if (formatted != _lastNotifTime || speedText != _lastNotifSpeed) {
          _lastNotifTime  = formatted;
          _lastNotifSpeed = speedText;
          VpnNotificationManager.showOrUpdateStatus(
            timeLeft: formatted,
            speedKbps: speedText,
          );
        }

        notifyListeners();
      } else if (response.statusCode == 404) {
        // Peer not found on server (expired / deleted natively)
        stop();
        vpnConnection.disconnect();
      } else {
        _markSyncFailure();
      }
    } catch (e) {
      debugPrint('Hivemind sync error: $e');
      _markSyncFailure();
    }
  }

  /// Increments the failure counter; pauses the local countdown after
  /// [_maxConsecutiveFailures] to avoid displaying a false "expired" clock.
  void _markSyncFailure() {
    _consecutiveFailures++;
    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      notifyListeners(); // let the UI show "Reconnecting…"
    }
  }

  // ── Bonus Time ─────────────────────────────────────────────────────────────

  /// Called after the user watches a bonus rewarded ad.
  ///
  /// The actual session extension is handled server-side via the AdMob SSV
  /// callback.  This method simply re-syncs so the UI picks up the new
  /// limits and un-throttled status.
  ///
  /// Returns `true` if the sync succeeded, so the UI can decide whether to
  /// show a success snackbar.
  Future<bool> addBonusTime() async {
    try {
      await _syncWithHivemind();
      return _hasSyncedOnce;
    } catch (e) {
      debugPrint('Bonus-time sync error: $e');
      return false;
    }
  }

  // ── Stop ───────────────────────────────────────────────────────────────────

  void stop() {
    _isDisconnecting = true;
    _timer?.cancel();
    _timer = null;
    // Keep _remainingSeconds visible so the UI doesn't flash 00:00:00
    // while the tunnel is tearing down.  The VpnConnection will drive the
    // UI transition, and dispose() will do final cleanup.
    _currentSpeedKbps = 0.0;
    VpnNotificationManager.cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    vpnConnection.removeListener(_onVpnConnectionChanged);
    _timer?.cancel();
    VpnNotificationManager.cancel();
    super.dispose();
  }
}
