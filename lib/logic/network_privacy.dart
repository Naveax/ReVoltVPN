abstract final class NetworkPrivacy {
  static const int _defaultVlessPort = 443;

  /// Returns a URI-authority-safe literal host that is safe for the managed
  /// tunnel transport boundary.
  ///
  /// Hostnames are deliberately rejected: the transport endpoint comes from the
  /// authenticated ReVoltVPN status response and must remain an IP literal so
  /// connecting the tunnel cannot silently introduce an OS-DNS bootstrap path.
  /// Unspecified, loopback, link-local, multicast and IPv4 broadcast endpoints
  /// are also rejected as defense in depth against a malformed server response.
  static String vlessAuthorityHost(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value != value.trim() ||
        value.contains('%') ||
        value.contains('[') ||
        value.contains(']')) {
      throw const FormatException('VLESS endpoint must be a bare IP literal.');
    }

    final ipv4 = _parseCanonicalIpv4(value);
    if (ipv4 != null) {
      if (!_allowedIpv4(ipv4)) {
        throw const FormatException(
            'VLESS IPv4 endpoint is not routable here.');
      }
      return value;
    }

    final ipv6 = _parseIpv6Words(value);
    if (ipv6 != null) {
      if (!_allowedIpv6(ipv6)) {
        throw const FormatException(
            'VLESS IPv6 endpoint is not routable here.');
      }
      return '[$value]';
    }

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

  static List<int>? _parseCanonicalIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return null;

    final octets = <int>[];
    for (final part in parts) {
      if (part.isEmpty ||
          part.length > 3 ||
          (part.length > 1 && part.startsWith('0')) ||
          !RegExp(r'^[0-9]+$').hasMatch(part)) {
        return null;
      }
      final octet = int.tryParse(part);
      if (octet == null || octet > 255) return null;
      octets.add(octet);
    }
    return octets;
  }

  static bool _allowedIpv4(List<int> octets) {
    final unspecified = octets.every((octet) => octet == 0);
    final loopback = octets[0] == 127;
    final linkLocal = octets[0] == 169 && octets[1] == 254;
    final multicast = octets[0] >= 224 && octets[0] <= 239;
    final broadcast = octets.every((octet) => octet == 255);
    return !(unspecified || loopback || linkLocal || multicast || broadcast);
  }

  static List<int>? _parseIpv6Words(String value) {
    if (!value.contains(':') || !RegExp(r'^[0-9A-Fa-f:.]+$').hasMatch(value)) {
      return null;
    }

    var normalized = value;
    if (normalized.contains('.')) {
      final lastColon = normalized.lastIndexOf(':');
      if (lastColon < 0) return null;
      final ipv4 = _parseCanonicalIpv4(normalized.substring(lastColon + 1));
      if (ipv4 == null) return null;
      final high = (ipv4[0] << 8) | ipv4[1];
      final low = (ipv4[2] << 8) | ipv4[3];
      normalized =
          '${normalized.substring(0, lastColon + 1)}${high.toRadixString(16)}:${low.toRadixString(16)}';
    }

    final compression = normalized.indexOf('::');
    if (compression >= 0 && normalized.indexOf('::', compression + 2) >= 0) {
      return null;
    }

    List<String> left;
    List<String> right;
    if (compression >= 0) {
      final leftText = normalized.substring(0, compression);
      final rightText = normalized.substring(compression + 2);
      left = leftText.isEmpty ? const [] : leftText.split(':');
      right = rightText.isEmpty ? const [] : rightText.split(':');
    } else {
      left = normalized.split(':');
      right = const [];
    }

    List<int>? parseWords(List<String> parts) {
      final words = <int>[];
      for (final part in parts) {
        if (part.isEmpty || part.length > 4) return null;
        final word = int.tryParse(part, radix: 16);
        if (word == null || word > 0xffff) return null;
        words.add(word);
      }
      return words;
    }

    final leftWords = parseWords(left);
    final rightWords = parseWords(right);
    if (leftWords == null || rightWords == null) return null;

    if (compression < 0) {
      return leftWords.length == 8 ? leftWords : null;
    }

    final explicitWords = leftWords.length + rightWords.length;
    if (explicitWords >= 8) return null;
    return <int>[
      ...leftWords,
      ...List<int>.filled(8 - explicitWords, 0),
      ...rightWords,
    ];
  }

  static bool _allowedIpv6(List<int> words) {
    final unspecified = words.every((word) => word == 0);
    final loopback = words.take(7).every((word) => word == 0) && words[7] == 1;
    final multicast = (words[0] & 0xff00) == 0xff00;
    final linkLocal = (words[0] & 0xffc0) == 0xfe80;
    if (unspecified || loopback || multicast || linkLocal) return false;

    // Also apply the IPv4 safety floor to IPv4-compatible/mapped literals.
    final compatible = words.take(6).every((word) => word == 0);
    final mapped =
        words.take(5).every((word) => word == 0) && words[5] == 0xffff;
    if (compatible || mapped) {
      final ipv4 = <int>[
        words[6] >> 8,
        words[6] & 0xff,
        words[7] >> 8,
        words[7] & 0xff,
      ];
      return _allowedIpv4(ipv4);
    }

    return true;
  }
}
