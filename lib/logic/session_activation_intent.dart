import 'dart:convert';

/// Public, short-lived correlation handle returned by the H13 control-plane.
///
/// This object deliberately does not contain the private session authorization
/// secret. Only [activationId] may cross the AdMob SSV trust boundary.
class SessionActivationIntent {
  static final RegExp _activationIdPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
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

  /// Exact main-session SSV payload. No device identifier, nonce or private
  /// session secret is permitted into third-party custom data.
  String toMainSsvCustomData() => jsonEncode(<String, String>{
        'activation_id': activationId,
        'ad_type': 'main',
      });
}
