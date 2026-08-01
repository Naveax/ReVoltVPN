// =============================================================================
//  app_config.example.dart — TEMPLATE FOR SERVER SETTINGS
//  ─────────────────────────────────────────────────────────────────────────────

abstract final class AppConfig {
  AppConfig._(); // static members only

  // ── Server ───────────────────────────────────────────────────────────
  /// Your server's public IP.  The VPN tunnel is pinned to this.
  static const String serverIp = '0.0.0.0';  // ◄── REPLACE

  /// API domain for session management (TLS traffic blending).
  static const String serverDomain = 'yourdomain.com';  // ◄── REPLACE

  /// Hivemind API base URL — standard TLS to the domain.
  static String get hivemindApiBase => 'https://$serverDomain/api';

  // ── Reality (VPN tunnel) ──────────────────────────────────────────────
  /// The server picks a random SNI per session from REALITY_SNI_POOL.
  /// The client does NOT hardcode one — server is always the source of truth.

  /// TLS fingerprint: chrome | firefox | safari | random
  static const String realityFp = 'chrome';

  // These are normally overridden by /session/status response fields.
  static const String vlessSecurity = 'reality';
  static const String vlessType     = 'xhttp';

  /// XHTTP path — must match the server's xhttpSettings.path.
  /// Server default: "/revolt" (hardcoded in xray_config_reality.json).
  static const String vlessPath = '/revolt';

  // ── Updates ────────────────────────────────────────────────────────────
  /// Used by the updater.
  static const String applicationId = 'com.paladinvpn.app';   // ◄── REPLACE
  static const String githubOwner   = 'YOUR_USERNAME';        // ◄── REPLACE
  static const String githubRepo    = 'revoltvpn';            // ◄── REPLACE

  /// Fallback URL if the GitHub API call fails — just opens the releases page.
  static const String githubReleasesUrl = 'https://github.com/$githubOwner/$githubRepo/releases/latest';

  // ── AdMob ──────────────────────────────────────────────────────────────
  static const String adUnitId = 'ca-app-pub-0000000000000000/0000000000'; // REPLACE
}