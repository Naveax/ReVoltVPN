import 'dart:math';

/// Canonical authorization format shared with the Rust control-plane.
abstract final class SessionAuth {
  SessionAuth._();

  static const String headerName = 'x-revoltvpn-session-nonce';
  static final RegExp _noncePattern = RegExp(r'^[0-9a-f]{32}$');

  /// 128 bits rendered as exactly 32 lowercase hexadecimal characters.
  static String newNonce({Random? random}) {
    final source = random ?? Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(source.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static bool isValidNonce(String value) => _noncePattern.hasMatch(value);

  static Map<String, String> headers(String nonce) {
    if (!isValidNonce(nonce)) {
      throw const FormatException('Invalid session authorization nonce.');
    }
    return <String, String>{headerName: nonce};
  }
}
