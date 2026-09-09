class SessionAccounting {
  final int expiresInSeconds;
  final int usedBytes;
  final int hardCapBytes;
  final bool capExhausted;

  const SessionAccounting._({
    required this.expiresInSeconds,
    required this.usedBytes,
    required this.hardCapBytes,
    required this.capExhausted,
  });

  factory SessionAccounting.fromActiveStatus(Map<String, dynamic> json) {
    if (json['active'] != true) {
      throw const FormatException('Session accounting requires an active status');
    }

    final expiresInSeconds = _requiredInteger(
      json,
      'expires_in_seconds',
      minimum: 0,
    );
    final usedBytes = _requiredInteger(json, 'used_bytes', minimum: 0);
    final hardCapBytes = _requiredInteger(json, 'hard_cap_bytes', minimum: 1);
    final capExhausted = json['cap_exhausted'];
    if (capExhausted is! bool) {
      throw const FormatException('Invalid session boolean: cap_exhausted');
    }

    return SessionAccounting._(
      expiresInSeconds: expiresInSeconds,
      usedBytes: usedBytes,
      hardCapBytes: hardCapBytes,
      capExhausted: capExhausted,
    );
  }

  bool get expired => expiresInSeconds <= 0;
  bool get dataCapReached => capExhausted || usedBytes >= hardCapBytes;
  bool get exhausted => expired || dataCapReached;

  static int _requiredInteger(
    Map<String, dynamic> json,
    String key, {
    required int minimum,
  }) {
    final value = json[key];
    if (value is! int || value < minimum) {
      throw FormatException('Invalid session integer: $key');
    }
    return value;
  }
}
