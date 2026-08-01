# Changelog

All notable changes to the ReVoltVPN Flutter app.
Versions follow [semver](https://semver.org/): MAJOR.MINOR.PATCH

---

## [3.0.0] — 2026-08

### Protocol — TCP → XHTTP migration
- **Transport changed from TCP to XHTTP** (H2 stream-up with Reality).
  XTLS-Vision (`xtls-rprx-vision`) removed — it only applies to TCP+TLS/Reality,
  not XHTTP. XHTTP provides H2 multiplexing, CDN passthrough, and path-based
  hiding behind `/revolt`.
- **`flow` field removed from VLESS client config.** Xray falls back to standard
  TLS proxying inside the XHTTP tunnel — correct and intentional per official
  VLESS inbound docs.

### Fixed — critical server bug
- **Client hot-reload was broken.** `xray.py` called `xray api adi` (add inbounds,
  zero arguments) after writing `config.json`. This was a no-op — Xray never
  learned about new VLESS clients. Every session created since the modular
  rewrite was silently rejected at the VLESS layer.
  Fixed: `add_client()` now writes a temp JSON and calls `xray api adu`
  (add users). `remove_client()` calls `xray api rmu -tag=X email`.
  Verified against `XTLS/Xray-core` HandlerService source.

### Fixed — client
- **Missing XHTTP path in VLESS URL.** Server requires `path: "/revolt"` in
  `xhttpSettings` but the VLESS URL never included a `path` parameter.
  Fixed: `hivemind_service.dart` reads `xhttp_path` from `/session/status`,
  falls back to `AppConfig.vlessPath`.
- **`providerBundleIdentifier` mismatch.** Was `com.revoltvpn.app` — must match
  Android `applicationId` (`com.paladinvpn.app`) for VPN service registration.

### Fixed — server config
- **Reality keypair generated.** Replaced `GENERATE_ME_WITH_xray_x25519`
  placeholders in both `config.py` and `xray_config_reality.json` with a real
  X25519 keypair. Private key stays on server; public key sent to clients.
- **Throttle policy corrected.** `uplinkOnly`/`downlinkOnly` were set to
  `187500` — that's 52 hours, not 1.5 Mbps. These fields are **seconds**
  (idle timeouts), not bandwidth rate limiters (per official Policy docs).
  Set to defaults (2s / 5s). Real 1.5 Mbps cap requires Linux `tc`.
- **Fallback rate limits removed.** Live Reality docs warn fallback limiting
  *"is itself a fingerprint and is not recommended."* Ports are firewalled
  so fallback traffic is impossible anyway. Comment added for future reference.

### Added
- **`xhttp_path` in `/session/status` response.** Server now sends the XHTTP
  path to clients, same pattern as `reality_pbk`/`reality_sid`/`reality_sni`.
  `VLESS_XHTTP_PATH` constant in `config.py` is the single source of truth.
- **Updated deployment guide** (`SERVER_DEPLOYMENT.md`) — full step-by-step
  for XHTTP+Reality, verified against live Xray docs at xtls.github.io.
- **Updated cheatsheet** (`scraped/VLESS_XRAY_CHEATSHEET.md`) — all sections
  rewritten for XHTTP. Old TCP/Vision info replaced.

---

## [2.0.7] — 2026-07-31

### Fixed
- **Notification bug** — `SessionTimer.stop()` now cancels the persistent
  Android notification on user-initiated disconnect.
- **Concurrent sync guard** — `_syncInProgress` flag prevents duplicate
  HTTP requests from overlapping in `_syncWithHivemind()`.
- **Debug bypass gate** — `AppConfig.enableAdBypass` replaces `kDebugMode`
  for fake AdMob callback. Tree-shaken in release builds.

### Changed
- **Responsive layout** — main screen uses `LayoutBuilder` with proportional
  fractions. Scales to any screen size.
- **Dynamic version** — sidebar footer reads from `PackageInfo` instead of
  hardcoded string.
- **Swarm/log blocked** — nginx returns 404 for `/api/swarm` and `/api/log`.
  Monitoring runs locally via `swarm_watch.py`.

### Added
- **Update checker** in sidebar — polls GitHub Releases API.
- **Website button** in sidebar → opens `https://getrevolt.app`.
- **Timer syncing indicator** — spinner during handshake.
- Dependency: `package_info_plus`.

### Server
- `/session/stop` fetches stats BEFORE popping session (race fix).
- `XrayManager._stats_lock` for diagnostic counter thread safety.
- `ManagementLoop._start_lock` prevents TOCTOU on daemon startup.

---

## [1.0.6] — 2026-06

- Initial VLESS + Xray Reality tunnel
- 60 min session, 4 GB throttle, support top-up
- Server health dot, speed display, countdown timer
- Persistent Android notification
- Glass-morphism dark UI with yellow accent
- Right-edge sidebar with Ad Consent, Privacy, About, Discord
