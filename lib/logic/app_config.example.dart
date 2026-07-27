// =============================================================================
//  app_config.example.dart — TEMPLATE FOR SERVER SETTINGS
//  ─────────────────────────────────────────────────────────────────────────────
//  Rename this file to `app_config.dart` and fill in your real values.
//  Do not commit your real `app_config.dart` to GitHub!
//
//  Most Reality tunnel fields (vless_ip, vless_port, reality_pbk, reality_sid,
//  reality_sni, reality_fp) come from the server's /session/status response.
//  The constants below are fallbacks — the server is the source of truth.
// =============================================================================

abstract final class AppConfig {
  AppConfig._();

  // ── Server (API) ──────────────────────────────────────────────────────
  static const String serverDomain = 'yourdomain.com';  // ◄── REPLACE

  static String get hivemindApiBase => 'https://$serverDomain/api';

  // ── Reality (VPN tunnel) ──────────────────────────────────────────────
  // These are fallbacks — normally overridden by /session/status response.
  static const String realitySni = 'www.microsoft.com';
  static const String realityFp  = 'chrome';

  // These are authoritative — never sent by the server.
  static const String vlessSecurity = 'reality';
  static const String vlessType     = 'tcp';
  static const String vlessFlow     = 'xtls-rprx-vision';

  // ── AdMob ──────────────────────────────────────────────────────────────
  static const String adUnitId = 'ca-app-pub-0000000000000000/0000000000'; // REPLACE
}
