import 'dart:convert';

/// Public, short-lived correlation handle returned by the H13 control-plane.
///
/// This object deliberately does not contain the private session authorization
/// secret. Only public correlation material may cross the AdMob SSV trust
/// boundary.
class SessionActivationIntent {
  static final RegExp _activationIdPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static final RegExp _deviceIdPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  static const int maxLifetimeSeconds = 300;

  final String activationId;
  final int expiresInSeconds;

  const SessionActivationIntent._({
    required this.activationId,
    required this.expiresInSeconds,
  });

  factory SessionActivationIntent.fromJson(Map<String, dynamic> json) {
    final activationId = json['activation_id'];
    if (activationId is! String ||
        !_activationIdPattern.hasMatch(activationId)) {
      throw const FormatException('Invalid activation_id.');
    }

    final expiresInSeconds = json['expires_in_seconds'];
    if (expiresInSeconds is! int ||
        expiresInSeconds <= 0 ||
        expiresInSeconds > maxLifetimeSeconds) {
      throw const FormatException('Invalid activation intent lifetime.');
    }

    return SessionActivationIntent._(
      activationId: activationId,
      expiresInSeconds: expiresInSeconds,
    );
  }

  /// Exact first-phase H13 main-session SSV compatibility envelope.
  ///
  /// The backend still parses the legacy `device_id` / `nonce` shape during
  /// migration, but `nonce` now carries only the public activation UUID. The
  /// private 32-hex session secret is never serialized here.
  String toMainSsvCustomData(String deviceId) {
    if (!_deviceIdPattern.hasMatch(deviceId)) {
      throw const FormatException('Invalid device_id.');
    }
    return jsonEncode(<String, String>{
      'device_id': deviceId,
      'ad_type': 'main',
      'nonce': activationId,
    });
  }
}
