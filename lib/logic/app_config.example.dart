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
  static const String wgPort = '4433';

  // ── STEP 3: AmneziaWG DPI Obfuscation Settings ───────────────────────────
  // These parameters must match exactly what your amnezia-wg-easy server expects.
  static const int awgJc = 4;
  static const int awgJmin = 20;
  static const int awgJmax = 100;
  static const int awgS1 = 15;
  static const int awgS2 = 23;
  static const int awgH1 = 1;
  static const int awgH2 = 2;
  static const int awgH3 = 3;
  static const int awgH4 = 4;

  // ── STEP 4: AdMob Rewarded Video ID ──────────────────────────────────────
  static const String adUnitId = 'ca-app-pub-0000000000000000/0000000000'; // REPLACE WITH REAL AD UNIT

  // ── STEP 5: Network & Tunnel Settings ────────────────────────────────────
  static const String dnsServers = '1.1.1.1, 1.0.0.1';
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
