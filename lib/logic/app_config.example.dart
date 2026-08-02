// =============================================================================
//  app_config.example.dart — TEMPLATE FOR SERVER SETTINGS
//  ─────────────────────────────────────────────────────────────────────────────

abstract final class AppConfig {
  AppConfig._(); // static members only

  // ── Server ───────────────────────────────────────────────────────────
  /// Your server's public IP.  The VPN tunnel is pinned to this.
  static const String serverIp = '0.0.0.0';  // ◄── REPLACE

  /// API base — routed through the tunnel to Flask via Xray "api" outbound.
  static const String hivemindApiBase = 'http://10.254.254.1:5000/api';

  // ── Bootstrap (first-connect config fetch) ────────────────────────────
  /// Hardcoded Reality config.  App connects with this, fetches the real
  /// per-session VLESS URL through the tunnel, then reconnects.
  static String get bootstrapVlessUrl =>
      'vless://$bootstrapUuid@$serverIp:8443'
      '?security=reality&type=xhttp&path=/revolt'
      '&pbk=$realityPbk&sni=www.github.com&sid=$realitySid&fp=chrome'
      '#ReVoltVPN';

  /// Generate with `xray uuid` on the server.  Must match xray_config_reality.json.
  static const String bootstrapUuid = '00000000-0000-0000-0000-000000000000';  // ◄── REPLACE

  /// Server's Reality public key (from `xray x25519`).
  static const String realityPbk = 'REPLACE_WITH_YOUR_PUBLIC_KEY';

  /// Must be in xray_config_reality.json shortIds[].
  static const String realitySid = 'abc123';

  // ── Reality (VPN tunnel) ──────────────────────────────────────────────
  /// The server picks a random SNI per session from REALITY_SNI_POOL.
  /// The client does NOT hardcode one — server is always the source of truth.

  /// TLS fingerprint: chrome | firefox | safari | random
  static const String realityFp = 'chrome';

  // These are normally overridden by /session/status response fields.
  static const String vlessSecurity = 'reality';
  static const String vlessType     = 'xhttp';

  /// XHTTP path — must match xray_config_reality.json xhttpSettings.path.
  static const String vlessPath = '/revolt';

  // ── Updates ────────────────────────────────────────────────────────────
  /// Used by the updater.
  static const String applicationId = 'com.paladinvpn.app';   // ◄── REPLACE
  static const String githubOwner   = 'YOUR_USERNAME';        // ◄── REPLACE
  static const String githubRepo    = 'revoltvpn';            // ◄── REPLACE

  /// Fallback URL if the GitHub API call fails.
  static const String githubReleasesUrl = 'https://github.com/$githubOwner/$githubRepo/releases/latest';

  // ── AdMob ──────────────────────────────────────────────────────────────
  static const String adUnitId = 'ca-app-pub-0000000000000000/0000000000'; // REPLACE
}
