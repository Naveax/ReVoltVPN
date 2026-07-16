// =============================================================================
//  app_config.example.dart — TEMPLATE FOR SERVER SETTINGS
//  ─────────────────────────────────────────────────────────────────────────────
//  Rename this file to `app_config.dart` and fill in your real values below.
//  Do not commit your real `app_config.dart` to GitHub!
// =============================================================================

class AppConfig {
  // ── STEP 1: Paste your Hetzner server IP here ─────────────────────────────
  static const String serverIp = '127.0.0.1'; // REPLACE WITH REAL IP

  // ── STEP 2: WireGuard UDP traffic port (default: 51820) ───────────────────
  static const String wgPort = '51820'; // REPLACE WITH REAL PORT

  // ── STEP 3: AmneziaWG DPI Obfuscation Settings ───────────────────────────
  // Copy these from your real app_config.dart or your amnezia-wg-easy server.
  // All zeros = AmneziaWG obfuscation disabled (no DPI protection).
  static const int awgJc = 0;   // REPLACE
  static const int awgJmin = 0; // REPLACE
  static const int awgJmax = 0; // REPLACE
  static const int awgS1 = 0;   // REPLACE
  static const int awgS2 = 0;   // REPLACE
  static const int awgH1 = 0;   // REPLACE
  static const int awgH2 = 0;   // REPLACE
  static const int awgH3 = 0;   // REPLACE
  static const int awgH4 = 0;   // REPLACE

  // ── STEP 4: AdMob IDs ───────────────────────────────────────────────────
  // Also create android/admob.properties from the template in that folder.
  static const String admobAppId = 'ca-app-pub-0000000000000000~0000000000'; // REPLACE
  static const String adUnitId = 'ca-app-pub-0000000000000000/0000000000'; // REPLACE

  // ── STEP 5: Network & Tunnel Settings ────────────────────────────────────
  static const String dnsServers = '1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001';
  static const String allowedIps = '0.0.0.0/0, ::/0';
  static const int mtu = 1280;
  static const int persistentKeepalive = 25;
  static const int hivemindPort = 5000;

  // ─────────────────────────────────────────────────────────────────────────
  //  Nothing below this line needs to be changed.
  // ── STEP 1: Hivemind Server API ──────────────────────────────────────────
  static String get hivemindApiBase => 'https://yourdomain.duckdns.org/api'; // REPLACE WITH REAL DOMAIN

  /// The full server address passed to the WireGuard tunnel (IP:port).
  static String get serverEndpoint => '$serverIp:$wgPort';
}
