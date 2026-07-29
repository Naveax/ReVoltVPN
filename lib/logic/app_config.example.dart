// =============================================================================
//  app_config.example.dart — TEMPLATE FOR SERVER SETTINGS
//  ─────────────────────────────────────────────────────────────────────────────

abstract final class AppConfig {
  AppConfig._();

  // ── Server (API) ──────────────────────────────────────────────────────
  static const String serverDomain = 'yourdomain.com'; 

  static String get hivemindApiBase => 'https://$serverDomain/api';

  // ── Reality (VPN tunnel) ──────────────────────────────────────────────
  // These are fallbacks — normally overridden by /session/status response.
  static const String realitySni = 'www.microsoft.com';
  static const String realityFp  = 'chrome';

  // These are authoritative — never sent by the server.
  static const String vlessSecurity = 'reality';
  static const String vlessType     = 'tcp';
  static const String vlessFlow     = 'xtls-rprx-vision';

  // ── Updates ────────────────────────────────────────────────────────────
  /// Used by the updater.
  static const String applicationId = 'com.paladinvpn.app';  
  static const String githubOwner   = 'YOUR_USERNAME';       
  static const String githubRepo    = 'revoltvpn';          

  /// Fallback URL if the GitHub API call fails.
  static const String githubReleasesUrl = 'https://github.com/$githubOwner/$githubRepo/releases/latest';

  // ── AdMob ──────────────────────────────────────────────────────────────
  static const String adUnitId = 'ca-app-pub-0000000000000000/0000000000'; // REPLACE
}
