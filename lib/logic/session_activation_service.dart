import 'dart:async';
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

/// Fail-closed H13 boundary between public AdMob correlation and private session auth.
///
/// The private 128-bit session secret is persisted before preparation network I/O and is never
/// returned as the AdMob correlation value. Only the server-issued UUIDv4 activation id is public.
class SessionActivationService {
  static const _storage = FlutterSecureStorage();
  static const _pendingSecretKey = 'h13_pending_session_secret';
  static const _pendingActivationIdKey = 'h13_pending_activation_id';
  static const _sessionNonceHeader = 'X-RevoltVPN-Session-Nonce';

  static final RegExp _secretPattern = RegExp(r'^[0-9a-f]{32}$');
  static final RegExp _uuidV4Pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  // Serialize prepare, abandonment recovery and promotion inside one process. The server has its
  // own per-device gate; this local gate prevents the app from racing its own durable ownership
  // transitions around that server-side serialization.
  static Future<void> _tail = Future<void>.value();

  static Future<T> _serialized<T>(Future<T> Function() operation) {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    return (() async {
      await previous;
      try {
        return await operation();
      } finally {
        if (!release.isCompleted) release.complete();
      }
    })();
  }

  static Future<SessionActivationIntent?> prepare() {
    return _serialized(() async {
      if (!await _recoverPendingAbandonmentUnlocked()) return null;

      final deviceId = await CryptoService.getDeviceId();
      if (!_uuidV4Pattern.hasMatch(deviceId)) return null;

      final secret = HivemindService.newNonce();
      if (!_secretPattern.hasMatch(secret)) return null;

      // Persist ownership before sending the private secret. If the response is lost after the
      // server commits, this exact secret remains available for cancel+stop convergence.
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
          // Keep the private secret. Recovery can cancel by exact device+secret even when the
          // public response handle could not be persisted locally.
          return null;
        }

        return SessionActivationIntent(
          activationId: activationId,
          sessionSecret: secret,
        );
      } catch (_) {
        return null;
      }
    });
  }

  static Future<SessionActivationIntent?> pending() {
    return _serialized(_pendingUnlocked);
  }

  /// Converge an abandoned H13 preparation before forgetting private ownership.
  ///
  /// If active possession already equals the pending H13 secret, promotion committed and only the
  /// local marker clear was interrupted. In that case never cancel/stop the live generation.
  static Future<bool> recoverPendingAbandonment() {
    return _serialized(_recoverPendingAbandonmentUnlocked);
  }

  static Future<bool> _recoverPendingAbandonmentUnlocked() async {
    String? secret;
    try {
      secret = await _readSecret();
    } on FormatException {
      // Corrupt ownership is not equivalent to no ownership. Retain the bytes and fail closed so
      // a new generation cannot be minted while an unknown remote generation may still exist.
      return false;
    }
    if (secret == null) {
      try {
        await _storage.delete(key: _pendingActivationIdKey);
        return true;
      } catch (_) {
        return false;
      }
    }

    final activeSecret = await HivemindService.getSessionNonce();
    if (activeSecret == secret) {
      try {
        await _clearPending();
        return true;
      } catch (_) {
        return false;
      }
    }

    final deviceId = await CryptoService.getDeviceId();
    if (!_uuidV4Pattern.hasMatch(deviceId)) return false;

    if (!await _cancelIntent(deviceId, secret)) return false;
    if (!await _stopExact(deviceId, secret)) return false;

    try {
      await _clearPending();
      return true;
    } catch (_) {
      // Remote cleanup is already definitive. A stale local marker remains fail-closed and will
      // be retried on the next operation instead of being treated as a fresh capability.
      return false;
    }
  }

  /// Prove authenticated active status for the private H13 secret, persist that exact secret as
  /// current session possession, then retire only the matching H13 pending marker.
  static Future<bool> confirmAndPromote(SessionActivationIntent intent) {
    return _serialized(() async {
      if (!_uuidV4Pattern.hasMatch(intent.activationId) ||
          !_secretPattern.hasMatch(intent.sessionSecret)) {
        return false;
      }

      SessionActivationIntent? current;
      try {
        current = await _pendingUnlocked();
      } on FormatException {
        return false;
      }
      if (current == null ||
          current.activationId != intent.activationId ||
          current.sessionSecret != intent.sessionSecret) {
        return false;
      }
      if (await CryptoService.isSessionStopPending()) return false;

      final deviceId = await CryptoService.getDeviceId();
      if (!_uuidV4Pattern.hasMatch(deviceId)) return false;
      final url = _publicUrl('/session/status?device_id=$deviceId');

      const maxAttempts = 8;
      for (int attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          final response = await HivemindService.directGet(
            url,
            timeout: const Duration(seconds: 2),
            headers: <String, String>{
              _sessionNonceHeader: intent.sessionSecret,
            },
          );
          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            if (data is Map<String, dynamic> && data['active'] == true) {
              final echoed = data['nonce'];
              if (echoed != null && echoed != intent.sessionSecret) return false;

              SessionActivationIntent? stillPending;
              try {
                stillPending = await _pendingUnlocked();
              } on FormatException {
                return false;
              }
              if (stillPending == null ||
                  stillPending.activationId != intent.activationId ||
                  stillPending.sessionSecret != intent.sessionSecret ||
                  await CryptoService.isSessionStopPending()) {
                return false;
              }

              await HivemindService.setSessionNonce(intent.sessionSecret);
              await CryptoService.clearSessionStopPending();
              try {
                await _clearPending();
              } catch (_) {
                // Active possession is already durable. Recovery detects this exact equality and
                // clears only the stale H13 marker without revoking the live generation.
              }
              return true;
            }
          }
        } catch (_) {}

        if (attempt < maxAttempts) {
          await Future<void>.delayed(const Duration(milliseconds: 750));
        }
      }
      return false;
    });
  }

  static Future<SessionActivationIntent?> _pendingUnlocked() async {
    final secret = await _readSecret();
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
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.origin != base.origin) {
      throw StateError('activation API must remain on configured HTTPS origin.');
    }
    return uri;
  }
}
