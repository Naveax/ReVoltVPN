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
  /// TLS camouflage — which site the Reality tunnel impersonates.
  /// Server overrides this per session from REALITY_SNI_POOL.
  ///   www.microsoft.com  — classic, never blocked
  ///   cloudflare.com     — CDN, clean TLS
  ///   yandex.ru          — Russian, absolutely never blocked in Russia
  static const String realitySni = 'www.microsoft.com';  // ◄── REPLACE

  /// TLS fingerprint: chrome | firefox | safari | random
  static const String realityFp = 'chrome';

  // These are normally overridden by /session/status response fields.
  // The constants below serve as fallbacks if the server doesn't provide them.
  static const String vlessSecurity = 'reality';
  static const String vlessType     = 'tcp';
  static const String vlessFlow     = 'xtls-rprx-vision';

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