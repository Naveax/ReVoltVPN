import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/vpn_connection.dart';
import 'package:revoltvpn/logic/crypto_service.dart';
import 'package:revoltvpn/logic/session_terminal_evidence.dart';
import 'package:revoltvpn/logic/session_status_snapshot.dart';
import 'package:revoltvpn/logic/session_sync_fence.dart';

class SessionTimer extends ChangeNotifier {
  Timer? _timer;
  int _tickCount = 0;

  final VpnConnection vpnConnection;

  int _remainingSeconds = 0;
  int _usedBytes = 0;

  bool _hasSyncedOnce = false;
  int _consecutiveFailures = 0;
  bool _isDisconnecting = false;
  final SessionSyncFence _syncFence = SessionSyncFence();
  bool _disposed = false;

  static const int _maxConsecutiveFailures = 3;
  static const int _maxOfflineSeconds = 120;
  int _offlineSeconds = 0;

  static const int _pollIntervalSeconds = 5;

  int _lastUsedBytes = 0;
  double _currentSpeedKBps = 0.0;

  SessionTimer({required this.vpnConnection}) {
    vpnConnection.addListener(_onVpnConnectionChanged);
  }

  int get remaining => _remainingSeconds;
  bool get isRunning => _timer != null && _timer!.isActive;
  bool get isExpired => _remainingSeconds <= 0 && !isRunning;
  bool get hasSyncedOnce => _hasSyncedOnce;

  int get usedBytes => _usedBytes;
  double get currentSpeedKBps => _currentSpeedKBps;

  String get formatted {
    final h = (_remainingSeconds ~/ 3600).toString().padLeft(2, '0');
    final m = ((_remainingSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (_remainingSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  void _onVpnConnectionChanged() {
    if (_disposed) return;
    // Restore timer if VPN was already running at app launch.
    if (vpnConnection.status == VpnStatus.connected &&
        !isRunning &&
        vpnConnection.isStartupRestoration) {
      _resumeTicking();
      return;
    }

    // Resume after brief tunnel disconnection.
    if (vpnConnection.status == VpnStatus.connected &&
        !isRunning &&
        !_isDisconnecting &&
        _hasSyncedOnce) {
      debugPrint('[Timer] VPN reconnected after blip — resuming.');
      _resumeTicking();
      return;
    }

    if (vpnConnection.status == VpnStatus.disconnected && !_isDisconnecting) {
      _doDisconnect('VPN tunnel dropped');
    }
  }

  Future<void> start() async {
    if (_disposed) return;
    // Responses from a prior session cannot affect this session's counters.
    _syncFence.invalidate();
    _remainingSeconds = 0;
    _usedBytes = 0;
    _lastUsedBytes = 0;
    _currentSpeedKBps = 0.0;
    _tickCount = 0;
    _hasSyncedOnce = false;
    _consecutiveFailures = 0;
    _offlineSeconds = 0;
    _isDisconnecting = false;

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);

    _notifyIfAlive();
    _syncWithHivemind();
  }

  void _tick(Timer t) {
    if (_disposed || _isDisconnecting) return;
    if (_hasSyncedOnce && _consecutiveFailures < _maxConsecutiveFailures) {
      if (_remainingSeconds > 0) {
        _remainingSeconds--;
      }
    }

    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      _offlineSeconds++;
      if (_offlineSeconds >= _maxOfflineSeconds) {
        _doDisconnect('Server unreachable');
        return;
      }
    }

    if (_hasSyncedOnce && _remainingSeconds <= 0) {
      _doDisconnect('Session expired');
      return;
    }

    _tickCount++;
    if (_tickCount % _pollIntervalSeconds == 0) {
      _syncWithHivemind();
    }

    _notifyIfAlive();
  }

  Future<void> disconnect({String reason = 'User requested'}) async {
    await _doDisconnect(reason);
  }

  Future<void> _doDisconnect(String reason) async {
    if (_isDisconnecting) return;
    _isDisconnecting = true;
    _syncFence.invalidate();
    debugPrint('[Timer] Disconnecting: $reason');

    _timer?.cancel();
    _timer = null;
    _currentSpeedKBps = 0.0;
    _remainingSeconds = 0;
    _hasSyncedOnce = false;
    _notifyIfAlive();

    await vpnConnection.disconnect();

    if (!_isDisconnecting) return;
    _isDisconnecting = false;
    _notifyIfAlive();
  }

  Future<void> _syncWithHivemind() async {
    if (_disposed || _isDisconnecting) return;
    final syncGeneration = _syncFence.beginRequest();
    if (syncGeneration == null) return;
    try {
      final deviceId = await CryptoService.getDeviceId();
      final url = Uri.parse(
          '${AppConfig.hivemindApiPublic}/session/status?device_id=$deviceId');
      final response = await HivemindService.authenticatedGet(url);
      if (_disposed || _isDisconnecting || !_syncFence.accepts(syncGeneration))
        return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        // Status must be an object with a literal boolean state. A JSON list,
        // string or malformed field cannot refresh the countdown/watchdog.
        if (data is! Map<String, dynamic> || data['active'] is! bool) {
          _markSyncFailure();
          return;
        }
        if (SessionTerminalEvidence.reportsInactive(
            response.statusCode, data)) {
          // Status alone is not Xray teardown proof. VPN disconnect persists
          // intent and revokes the exact nonce before the epoch can rotate.
          await _doDisconnect('Server ended session');
          return;
        }

        final snapshot = SessionStatusSnapshot.parseActive(data);
        if (snapshot == null ||
            (_hasSyncedOnce && snapshot.usedBytes < _usedBytes)) {
          // The authenticated Rust response requires unsigned integral fields
          // and a monotonic byte counter for the same session. Never retain an
          // old expiry or mark malformed accounting as a successful sync.
          _markSyncFailure();
          return;
        }
        if (snapshot.mustStop) {
          await _doDisconnect(snapshot.remainingSeconds == 0
              ? 'Session expired'
              : 'Data cap reached');
          return;
        }

        final int deltaBytes = snapshot.usedBytes - _lastUsedBytes;
        _currentSpeedKBps = _hasSyncedOnce && deltaBytes > 0
            ? (deltaBytes / _pollIntervalSeconds) / 1000
            : 0.0;
        _remainingSeconds = snapshot.remainingSeconds;
        _usedBytes = snapshot.usedBytes;
        _lastUsedBytes = snapshot.usedBytes;

        _consecutiveFailures = 0;
        _offlineSeconds = 0;
        _hasSyncedOnce = true;
        _notifyIfAlive();
      } else if (response.statusCode == 401) {
        // Authentication rejection can originate at an edge proxy and is not
        // evidence that the server removed this epoch's VLESS credential.
        _markSyncFailure();
      } else {
        _markSyncFailure();
      }
    } catch (e) {
      // An obsolete failed call cannot increment a new session's watchdog.
      if (!_disposed &&
          _syncFence.accepts(syncGeneration) &&
          !_isDisconnecting) {
        debugPrint('Hivemind sync error: $e');
        _markSyncFailure();
      }
    } finally {
      _syncFence.finishRequest(syncGeneration);
    }
  }

  void _markSyncFailure() {
    _consecutiveFailures++;
    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      _notifyIfAlive();
    }
  }

  void _resumeTicking() {
    if (_disposed) return;
    _syncFence.invalidate();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);
    _isDisconnecting = false;
    _syncWithHivemind();
    _notifyIfAlive();
  }

  void _notifyIfAlive() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _syncFence.invalidate();
    vpnConnection.removeListener(_onVpnConnectionChanged);
    _timer?.cancel();
    super.dispose();
  }
}
