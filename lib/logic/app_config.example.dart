// =============================================================================
//  app_config.example.dart — TEMPLATE FOR SERVER SETTINGS
//  ─────────────────────────────────────────────────────────────────────────────
//  Rename this file to `app_config.dart` and fill in your real values.
//  Do not commit your real `app_config.dart` to GitHub!
// =============================================================================

abstract final class AppConfig {
  AppConfig._();

  // ── Server ─────────────────────────────────────────────────────────────
  static const String serverDomain = 'yourdomain.com';  // REPLACE

  static const String vlessPath = '/tunnel';             // REPLACE if different

  static String get hivemindApiBase => 'https://$serverDomain/api';

  // ── VLESS ──────────────────────────────────────────────────────────────
  static const int serverPort = 443;
  static const String vlessFlow = 'xtls-rprx-vision';
  static const String vlessSecurity = 'tls';
  static const String vlessType = 'ws';

  // ── AdMob ──────────────────────────────────────────────────────────────
  static const String adUnitId = 'ca-app-pub-0000000000000000/0000000000'; // REPLACE
}
