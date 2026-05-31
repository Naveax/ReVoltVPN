import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:paladinvpn/logic/app_config.dart';
import 'package:paladinvpn/logic/vpn_connection.dart';
import 'package:paladinvpn/logic/crypto_service.dart';
import 'package:paladinvpn/components/notification.dart';

/// SessionTimer acts as the client-side session authority for the VPN tunnel.
/// 
/// It connects to the Hivemind API on the server to sync the true remaining
/// time, data quotas, speed, and throttling status.
class SessionTimer extends ChangeNotifier {
  Timer? _timer;
  int _tickCount = 0;
  
  final VpnConnection vpnConnection;

  // ── Session State ──
  int _remainingSeconds = 0;
  int _quotaBytes = 0;
  int _usedBytes = 0;
  bool _isThrottled = false;
  
  // ── Speed State ──
  int _lastUsedBytes = 0;
  double _currentSpeedKbps = 0.0; // Total speed (RX+TX)

  SessionTimer({required this.vpnConnection});

  int get remaining => _remainingSeconds;
  bool get isRunning => _timer != null && _timer!.isActive;
  bool get isExpired => _remainingSeconds <= 0 && !isRunning;
  
  int get quotaBytes => _quotaBytes;
  int get usedBytes => _usedBytes;
  int get remainingBytes => _quotaBytes > _usedBytes ? _quotaBytes - _usedBytes : 0;
  bool get isThrottled => _isThrottled;
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
    // Max duration is generally 60 or 90 minutes. We'll base the ring purely on data usage or just standard time
    // For UI simplicity, we'll return data progress:
    if (_quotaBytes == 0) return 0.0;
    return (_quotaBytes - _usedBytes) / _quotaBytes;
  }

  Future<void> start(String adType) async {
    _remainingSeconds = 3600; // optimistic start
    _quotaBytes = 2 * 1024 * 1024 * 1024;
    _usedBytes = 0;
    _lastUsedBytes = 0;
    _currentSpeedKbps = 0.0;
    _isThrottled = false;
    _tickCount = 0;
    
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);
    
    // Kick off an immediate sync so the UI shows real data right away
    _syncWithHivemind();
  }

  void _tick(Timer t) {
    if (_remainingSeconds > 0) {
      _remainingSeconds--;
    }

    _tickCount++;
    // Poll the server every 3 seconds to get live stats
    if (_tickCount % 3 == 0) {
      _syncWithHivemind();
    }

    notifyListeners();
  }

  Future<void> _syncWithHivemind() async {
    try {
      final deviceId = await CryptoService.getDeviceId();
      final url = Uri.parse('${AppConfig.hivemindApiBase}/session/status?device_id=$deviceId');
      final response = await http.get(url).timeout(const Duration(seconds: 3));
      
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
        _quotaBytes = data['quota_bytes'] ?? _quotaBytes;
        _usedBytes = data['used_bytes'] ?? _usedBytes;
        _isThrottled = data['is_throttled'] ?? false;

        // Calculate speed over the polling interval
        final int deltaBytes = _usedBytes - _lastUsedBytes;
        if (_lastUsedBytes > 0 && deltaBytes > 0) {
          _currentSpeedKbps = (deltaBytes / 3) / 1024;
        } else {
          _currentSpeedKbps = 0.0;
        }
        _lastUsedBytes = _usedBytes;

        VpnNotificationManager.showOrUpdateStatus(
          timeLeft: formatted,
          speedKbps: '${_currentSpeedKbps.toStringAsFixed(2)} KB/s',
        );

        notifyListeners();
      } else if (response.statusCode == 404) {
        // Peer not found on server (expired/deleted natively)
        stop();
        vpnConnection.disconnect();
      }
    } catch (e) {
      debugPrint('Hivemind sync error: $e');
      // If we can't reach the server, just let the local timer run
    }
  }

  Future<void> addBonusTime() async {
    final ip = vpnConnection.internalIp;
    if (ip != null) {
      try {
        final deviceId = await CryptoService.getDeviceId();
        await http.post(
          Uri.parse('${AppConfig.hivemindApiBase}/session/start'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'ip': ip,
            'device_id': deviceId,
            'ad_type': 'bonus_ad'
          }),
        ).timeout(const Duration(seconds: 5));
        
        // Immediately sync to fetch the updated limits and un-throttled status
        _syncWithHivemind();
      } catch (e) {
        debugPrint('Failed to add bonus time with Hivemind: $e');
      }
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _remainingSeconds = 0;
    _currentSpeedKbps = 0.0;
    VpnNotificationManager.cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    VpnNotificationManager.cancel();
    super.dispose();
  }
}
