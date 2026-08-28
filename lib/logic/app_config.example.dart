// =============================================================================
//  app_config.example.dart — TEMPLATE FOR SERVER SETTINGS
// =============================================================================

abstract final class AppConfig {
  AppConfig._();

  // Public VPN server address used by per-session VLESS configs.
  static const String serverIp = '0.0.0.0'; // REPLACE

  // Public HTTPS control-plane base URL. It must expose at least:
  //   GET /health
  //   GET /session/status?device_id=...
  //   GET /admob/callback (AdMob SSV endpoint on the server side)
  // Do not point this at the marketing website.
  static const String hivemindApiPublic =
      'https://vpn-api.example.com'; // REPLACE

  // Legacy/bootstrap fields retained for server deployments that use them.
  static String get bootstrapVlessUrl =>
      'vless://$bootstrapUuid@$serverIp:8443'
      '?security=reality&type=xhttp&path=/revolt'
      '&pbk=$realityPbk&sni=www.github.com&sid=$realitySid&fp=chrome'
      '#ReVoltVPN';

  static const String bootstrapUuid =
      '00000000-0000-0000-0000-000000000000'; // REPLACE
  static const String realityPbk = 'REPLACE_WITH_YOUR_PUBLIC_KEY';
  static const String realitySid = 'abc123';
  static const String realityFp = 'chrome';
  static const String vlessSecurity = 'reality';
  static const String vlessType = 'xhttp';
  static const String vlessPath = '/revolt';

  static const String applicationId = 'com.paladinvpn.app';
  static const String githubOwner = 'YOUR_USERNAME';
  static const String githubRepo = 'revoltvpn';
  static const String githubReleasesUrl =
      'https://github.com/$githubOwner/$githubRepo/releases/latest';

  static const String adUnitId =
      'ca-app-pub-0000000000000000/0000000000'; // REPLACE
}
