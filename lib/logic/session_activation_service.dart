import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/crypto_service.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';

class SessionActivationIntent {
  const SessionActivationIntent({
    required this.activationId,
    required this.sessionSecret,
  });

  final String activationId;
  final String sessionSecret;
}

/// H13 capability boundary for main rewarded-ad activation.
///
/// The private 128-bit session secret is persisted before any preparation
/// request leaves the device. Only the public UUIDv4 activation id is suitable
/// for AdMob custom_data. This service is intentionally not wired into the ad
/// flow yet; it establishes the fail-closed preparation/recovery primitive for
/// a later reviewed cutover.
class SessionActivationService {
  static const _storage = FlutterSecureStorage();
  static const _pendingSecretKey = 'h13_pending_session_secret';
  static const _pendingActivationIdKey = 'h13_pending_activation_id';
  static const _sessionNonceHeader = 'X-RevoltVPN-Session-Nonce';

  static final RegExp _secretPattern = RegExp(r'^[0-9a-f]{32}$');
  static final RegExp _uuidV4Pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  static Future<SessionActivationIntent?> prepare() async {
    if (!await recoverPendingAbandonment()) return null;

    final deviceId = await CryptoService.getDeviceId();
    if (!_uuidV4Pattern.hasMatch(deviceId)) return null;

    final secret = HivemindService.newNonce();
    if (!_secretPattern.hasMatch(secret)) return null;

    // Persist ownership before the request. If the response is lost, the exact
    // secret needed to cancel/revoke remains available after process restart.
    try {
      await _storage.write(key: _pendingSecretKey, value: secret);
      await _storage.delete(key: _pendingActivationIdKey);
    } catch (_) {
      return null;
    }

    try {
      final response = await HivemindService.directPost(
        _publicUrl('/session/activation-intents'),
        body: jsonEncode(<String, Object>{
          'device_id': deviceId,
          'session_secret': secret,
        }),
        timeout: const Duration(seconds: 4),
      );
      if (response.statusCode != 201) return null;
      if (!_isNoStore(response.headers['cache-control'])) return null;

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) return null;
      final activationId = data['activation_id'];
      final expiresInSeconds = data['expires_in_seconds'];
      if (activationId is! String ||
          !_uuidV4Pattern.hasMatch(activationId) ||
          expiresInSeconds != 300) {
        return null;
      }

      try {
        await _storage.write(
          key: _pendingActivationIdKey,
          value: activationId,
        );
      } catch (_) {
        // Secret ownership remains durable, so recovery can still converge by
        // exact device+secret without trusting the lost public handle.
        return null;
      }

      return SessionActivationIntent(
        activationId: activationId,
        sessionSecret: secret,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<SessionActivationIntent?> pending() async {
    String? secret;
    try {
      secret = await _readSecret();
    } on FormatException {
      return null;
    }
    if (secret == null) return null;

    final activationId = await _storage.read(key: _pendingActivationIdKey);
    if (activationId == null || !_uuidV4Pattern.hasMatch(activationId)) {
      if (activationId != null) {
        await _storage.delete(key: _pendingActivationIdKey);
      }
      return null;
    }
    return SessionActivationIntent(
      activationId: activationId,
      sessionSecret: secret,
    );
  }

  /// Converge an abandoned H13 preparation before forgetting ownership.
  /// Cancellation must be proven first; then authenticated stop resolves the
  /// opposite race where Google callback activation won the device gate first.
  static Future<bool> recoverPendingAbandonment() async {
    String? secret;
    try {
      secret = await _readSecret();
    } on FormatException {
      // Corrupt ownership is not equivalent to no ownership. Retain the bytes and
      // fail closed so a new generation cannot be minted while remote state may exist.
      return false;
    }
    if (secret == null) {
      await _storage.delete(key: _pendingActivationIdKey);
      return true;
    }

    final deviceId = await CryptoService.getDeviceId();
    if (!_uuidV4Pattern.hasMatch(deviceId)) return false;

    final cancelled = await _cancelIntent(deviceId, secret);
    if (!cancelled) return false;

    final stopped = await _stopExact(deviceId, secret);
    if (!stopped) return false;

    await _clearPending();
    return true;
  }

  /// Clear H13 pending ownership only after the caller has promoted this exact
  /// secret into durable active-session authorization following authenticated
  /// active status proof.
  static Future<bool> clearAfterPromotion(
    String activationId,
    String sessionSecret,
  ) async {
    if (!_uuidV4Pattern.hasMatch(activationId) ||
        !_secretPattern.hasMatch(sessionSecret)) {
      return false;
    }
    final current = await pending();
    if (current == null ||
        current.activationId != activationId ||
        current.sessionSecret != sessionSecret) {
      return false;
    }
    await _clearPending();
    return true;
  }

  static Future<bool> _cancelIntent(String deviceId, String secret) async {
    try {
      final response = await HivemindService.directPost(
        _publicUrl('/session/activation-intents'),
        body: jsonEncode(<String, Object>{
          'device_id': deviceId,
          'session_secret': secret,
          'cancel': true,
        }),
        timeout: const Duration(seconds: 4),
      );
      if (response.statusCode != 200) return false;
      if (!_isNoStore(response.headers['cache-control'])) return false;
      final data = jsonDecode(response.body);
      return data is Map<String, dynamic> && data['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _stopExact(String deviceId, String secret) async {
    try {
      final response = await HivemindService.directPost(
        _publicUrl('/session/stop'),
        body: jsonEncode(<String, String>{'device_id': deviceId}),
        timeout: const Duration(seconds: 4),
        headers: <String, String>{_sessionNonceHeader: secret},
      );
      if (response.statusCode == 401) return true;
      if (response.statusCode != 200) return false;
      final data = jsonDecode(response.body);
      return data is Map<String, dynamic> && data['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _readSecret() async {
    final value = await _storage.read(key: _pendingSecretKey);
    if (value == null) return null;
    if (!_secretPattern.hasMatch(value)) {
      throw const FormatException('Corrupt H13 pending ownership state');
    }
    return value;
  }

  static Future<void> _clearPending() async {
    await _storage.delete(key: _pendingActivationIdKey);
    await _storage.delete(key: _pendingSecretKey);
  }

  static bool _isNoStore(String? value) {
    if (value == null) return false;
    return value
        .split(',')
        .map((part) => part.trim().toLowerCase())
        .contains('no-store');
  }

  static Uri _publicUrl(String path) {
    if (!path.startsWith('/') || path.startsWith('//')) {
      throw ArgumentError.value(path, 'path', 'expected absolute API path');
    }
    final base = Uri.tryParse(AppConfig.hivemindApiPublic.trim());
    if (base == null ||
        base.scheme != 'https' ||
        !base.hasAuthority ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.query.isNotEmpty ||
        base.fragment.isNotEmpty) {
      throw StateError('hivemindApiPublic must be a canonical HTTPS base URL.');
    }
    final text = base.toString().endsWith('/')
        ? base.toString().substring(0, base.toString().length - 1)
        : base.toString();
    final uri = Uri.parse('$text$path');
    if (uri.origin != base.origin || uri.userInfo.isNotEmpty) {
      throw StateError('activation API must remain on configured HTTPS origin.');
    }
    return uri;
  }
}
