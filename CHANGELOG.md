# Changelog

All notable changes to the ReVoltVPN Flutter app.
Versions follow [semver](https://semver.org/): MAJOR.MINOR.PATCH

---

## [3.2.2] — 2026-08-08

### Fixed
- Updated Discord invite link.

## [3.2.1] — 2026-08-08

### Google Play compliance
- Added first-launch data disclosure dialog ("Before you connect") explaining
  that connection duration and data usage are logged for quota enforcement, and
  that traffic content is never monitored.

## [3.2.0] — 2026-08-08

### DPI hardening
- Spoof Chrome-on-Android User-Agent on all API calls instead of `Dart/3.x`.
- Renamed domain from `getrevolt.app` to `userevolt.app`.

### Branding
- App name changed from "REVOLT VPN" to "Revolt VPN" across manifest, splash,
  notification, and VLESS URL remark.

### Notification
- Removed duplicate `flutter_local_notifications` notification. Only the
  Android VPN foreground-service notification remains — non-swipeable.
- Patched `flutter_vless` native code to use custom notification icon
  (`@drawable/notification_icon`) with dark background (`#0D1117`).

### Connection reliability
- Merged five separate disconnect paths into a single idempotent
  `_doDisconnect()` gate. Eliminated race between timer ticks and VPN
  teardown where the countdown could briefly show -1.
- `stopVless()` timeout (5 s) now correctly shows an error instead of
  silently pretending the VPN disconnected while the tunnel was still alive.

### AdMob bypass
- `kDebugMode` guard removed — the debug AdMob callback now fires in release
  builds so release APKs can create sessions without real ads during testing.
  The real gate is `ADMOB_BYPASS` on the server.

### Fixed
- **Notification icon:** Replaced five density-specific `ic_launcher.png`
  files with `notification_icon.png`, then reverted to avoid changing the
  home-screen icon. The custom icon is now injected through flutter_vless's
  `initializeVless()` parameters.

## [3.1.0] — 2026-08-06

### Architecture — domain-free client
- **Zero domain strings in APK.** RKN has nothing to DNS-block. API calls go
  through the Reality tunnel to `10.254.254.1:5000`, redirected to Flask by
  Xray's `api` freedom outbound (`redirect: 127.0.0.1:5000`).
- **Bootstrap tunnel.** Bundled Reality config in APK → connect → fetch real
  per-session VLESS URL from inside the tunnel → reconnect. Bootstrap client
  permanently in `xray_config_reality.json`, restricted by Xray routing to
  internal API only.
- `serverDomain` removed from `AppConfig`. `fetchConfigThroughTunnel()`
  replaces `fetchConfigWithPolling()`. `connect()` rewritten.

### Protocol — TCP to XHTTP
- Transport: TCP → XHTTP (H2 stream-up with Reality). No more XTLS-Vision,
  no `flow` field. Path-hidden behind `/revolt`.

### Fixed
- **RenderFlex overflow** — status bar text wrapped in `Flexible` with
  `TextOverflow.ellipsis` to prevent overflow on narrow screens (≤360dp).
- **Circular import** — removed `import 'package:revoltvpn/main.dart'` from
  `sidebar_drawer.dart`. `SidebarDrawer` converted to `StatefulWidget`;
  version footer loaded via `PackageInfo.fromPlatform()`.
- Client hot-reload was silently broken — `xray api adi` no-op. Fixed:
  `adu`/`rmu` commands per Xray HandlerService spec.
- Missing XHTTP `path` param in VLESS URL — now reads `xhttp_path` from
  `/session/status`.
- `providerBundleIdentifier` was `com.revoltvpn.app` — must match
  `com.paladinvpn.app` for VPN service registration.
- Reality keypair generated (was placeholder). Throttle `uplinkOnly`/`downlinkOnly`
  corrected (seconds, not bytes/sec). Fallback rate limits removed (fingerprint).

### Added
- **Settings screen** — reached from a new sidebar row (between Website and
  Check for updates). Slide-from-right navigation via `PageRouteBuilder`.
  Folder: `lib/screens/settings/` with one file per feature in `in_settings/`.
- **Haptic feedback toggle** — on/off switch in Settings for `lightImpact()`
  vibration on successful connect/disconnect. Default: off. Uses sync-bool
  pattern (no await on tap, no SharedPreferences in connect button).
- **Rain/Lightning effect toggles** — two switches in Settings to control
  the animated background effects. Default: on. Effects detect the toggle
  within one frame (no Provider/notifier needed).

### Changed
- **Timer box spinner removed** — the "Connecting…"/"Syncing…" spinner under
  the countdown was redundant with the connect button's spinner. Timer card
  is now a clean countdown only (gray '00:00:00' when idle).
- **Sidebar** now has 7 rows (added Settings). `FRONTEND_POLISH_REVIEW.md`
  fully triaged: 4 items fixed, 11 skipped.

### Server
- `api` outbound + 3 routing rules in `xray_config_reality.json` (bootstrap
  isolation + API routing). Permanent bootstrap client. Hivemind unchanged.
- `xhttp_path` in `/session/status` response.
- Full deployment guide: `SERVER_DEPLOYMENT.md`.

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
- **Website button** in sidebar → opens `https://userevolt.app`.
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
