abstract final class NetworkPrivacy {
  static const int _defaultVlessPort = 443;

  /// Returns a URI-authority-safe literal host.
  ///
  /// Hostnames are deliberately rejected: the transport endpoint comes from the
  /// authenticated ReVoltVPN status response and must remain an IP literal so
  /// connecting the tunnel cannot silently introduce an OS-DNS bootstrap path.
  static String vlessAuthorityHost(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value != value.trim() ||
        value.contains('%') ||
        value.contains('[') ||
        value.contains(']')) {
      throw const FormatException('VLESS endpoint must be a bare IP literal.');
    }

    if (_isCanonicalIpv4(value)) return value;
    if (_isIpv6Literal(value)) return '[$value]';

    throw const FormatException(
        'VLESS endpoint must be an IPv4 or IPv6 literal.');
  }

  static int vlessPort(Object? value) {
    final candidate = value ?? _defaultVlessPort;
    if (candidate is! int || candidate < 1 || candidate > 65535) {
      throw const FormatException('VLESS port must be an integer in 1..65535.');
    }
    return candidate;
  }

  static bool _isCanonicalIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;

    for (final part in parts) {
      if (part.isEmpty ||
          part.length > 3 ||
          (part.length > 1 && part.startsWith('0')) ||
          !RegExp(r'^[0-9]+$').hasMatch(part)) {
        return false;
      }
      final octet = int.tryParse(part);
      if (octet == null || octet > 255) return false;
    }
    return true;
  }

  static bool _isIpv6Literal(String value) {
    if (!value.contains(':') || !RegExp(r'^[0-9A-Fa-f:.]+$').hasMatch(value)) {
      return false;
    }

    try {
      final parsed = Uri.parse('http://[$value]/');
      return parsed.scheme == 'http' &&
          parsed.userInfo.isEmpty &&
          parsed.host.contains(':') &&
          parsed.path == '/' &&
          parsed.query.isEmpty &&
          parsed.fragment.isEmpty;
    } on FormatException {
      return false;
    }
  }
}
