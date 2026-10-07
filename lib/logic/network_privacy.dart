abstract final class NetworkPrivacy {
  static const int _defaultVlessPort = 443;

  /// Returns a URI-authority-safe literal host that is safe for the managed
  /// tunnel transport boundary.
  ///
  /// Hostnames are deliberately rejected: the transport endpoint comes from the
  /// authenticated ReVoltVPN status response and must remain an IP literal so
  /// connecting the tunnel cannot silently introduce an OS-DNS bootstrap path.
  /// Only public/global-unicast endpoint ranges are accepted; LAN, CGNAT,
  /// documentation, benchmark, transition and other special-use ranges fail closed.
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
    final a = octets[0];
    final b = octets[1];
    final c = octets[2];

    // Production transport endpoints must be public Internet unicast, not merely
    // syntactically valid literals. Otherwise a malformed/authenticated response
    // could make the protected socket escape toward LAN, CGNAT or a special-use
    // range on the physical network.
    if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
    if (a == 100 && b >= 64 && b <= 127) return false; // RFC 6598 CGNAT.
    if (a == 169 && b == 254) return false; // Link-local.
    if (a == 172 && b >= 16 && b <= 31) return false; // RFC 1918.
    if (a == 192 && b == 0 && c == 0) return false; // IETF special-use /24.
    if (a == 192 && b == 0 && c == 2) return false; // TEST-NET-1.
    if (a == 192 && b == 88 && c == 99) return false; // Deprecated 6to4 relay.
    if (a == 192 && b == 168) return false; // RFC 1918.
    if (a == 198 && (b == 18 || b == 19)) return false; // Benchmarking.
    if (a == 198 && b == 51 && c == 100) return false; // TEST-NET-2.
    if (a == 203 && b == 0 && c == 113) return false; // TEST-NET-3.
    return true;
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
    // Public IPv6 unicast is allocated from 2000::/3. This automatically
    // excludes ULA, link-local, multicast, mapped/compatible and other local
    // scopes before the narrower special-use exclusions below.
    if ((words[0] & 0xe000) != 0x2000) return false;

    if (words[0] == 0x2001) {
      if (words[1] == 0x0000) return false; // Teredo 2001::/32.
      if (words[1] == 0x0002 && words[2] == 0) {
        return false; // Benchmarking 2001:2::/48.
      }
      if (words[1] == 0x0db8) return false; // Documentation 2001:db8::/32.
      if ((words[1] & 0xfff0) == 0x0010) {
        return false; // ORCHIDv1 2001:10::/28.
      }
      if ((words[1] & 0xfff0) == 0x0020) {
        return false; // ORCHIDv2 2001:20::/28.
      }
    }
    if (words[0] == 0x2002) return false; // Deprecated 6to4 2002::/16.
    if (words[0] == 0x3fff && (words[1] & 0xf000) == 0) {
      return false; // Documentation 3fff::/20.
    }

    return true;
  }
}
