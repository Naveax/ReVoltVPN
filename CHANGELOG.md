# Changelog

All notable changes to the ReVoltVPN Flutter app.
Versions follow [semver](https://semver.org/): MAJOR.MINOR.PATCH

---

## [3.3.0] — Unreleased

### Added
- Session countdown in the VPN notification, updated each second while connected.

### Fixed
- **Session-expiry desync** — the app could show "Online" with no internet after
  the server ended the session. The countdown no longer freezes when a poll fails.
- **Notification Disconnect button** disappeared a second after connecting.
  Re-posting the foreground notification replaces it wholesale, so the action,
  colour and tap-intent flutter_vless sets are now rebuilt rather than dropped.
- **Speed readout** divided the byte delta by the nominal poll interval instead of
  the real time between polls — wrong by up to 6x around every background switch.
- **Settings toggles** now apply at launch. Rain, lightning and haptics were only
  read from disk when Settings mounted, so an effect turned off came back — ticker
  and all — on every relaunch, and haptic feedback did nothing until Settings had
  been opened at least once.
- **Haptic feedback** now fires `mediumImpact()` instead of `lightImpact()` (which
  is imperceptible on many Android devices), wrapped best-effort so a platform
  vibration failure cannot fail a connect/disconnect, with a preview tap when the
  toggle is switched on.
- First-launch disclosure dialog said data was linked to "your account". It is
  linked to a randomly generated device ID, and the policy is in the sidebar, not
  on a website.
- Sidebar "Settings" and "Check for updates" used the drawer's context after
  `Navigator.pop()` — a defunct context. They now capture the root navigator (and
  messenger) before closing the drawer. *(Fix ported from Naveax's review.)*

### Performance
- Rain overlay ticks only while enabled, repaints through a scoped `Listenable`
  instead of rebuilding every frame, and precomputes drop colours.
- Lightning no longer fires strikes while disabled.
- Connect button pulse pauses when backgrounded; brand image hoisted out of the
  per-frame rebuild.
- Server poll drops to 30 s while backgrounded (5 s foreground), with an immediate
  re-sync on resume. The 1 s countdown keeps running.
- Health probe runs only while disconnected, and pauses in the background.
- Speed and support widgets rebuild on value change instead of every second.
- Notification channel is created once per process, not once per second.

### Changed
- VLESS engine initializes under the splash screen; the intro waits on
  `VpnConnection.ready` (8 s cap) before showing the main screen.
- AdMob SDK init moved off the blocking pre-`runApp()` path so startup cannot hang
  on an unreachable Google endpoint.
- `app_config.example.dart` drops the dead bootstrap fields and documents
  `hivemindApiPublic` in their place.
- `.gitignore` reorganized around type and directory rules; the enumerated
  filename list is gone (redundant with the type rules) and `.claude/` is now
  ignored.

### Security
- Update checker pins the release URL to this repo's path on `github.com`, not just
  the host. Anything else falls back to the releases page.
- Notification timer updates are gated on a live tunnel, so a late tick cannot leave
  an ongoing notification with no foreground service behind it.
- Dropped `READ_EXTERNAL_STORAGE`, which `flutter_vless` pulls in but the app never uses
  (least privilege).
- Pinned the Gradle 8.14 distribution SHA-256; `validateDistributionUrl` enabled
  (supply-chain integrity).

### Build & tooling (ported from Naveax)
- Removed the deprecated `android.enableR8` flag.
- Added `analysis_options.yaml` (flutter_lints, `local_packages/**` excluded, `avoid_print`).
- Added `.gitattributes` to pin LF line endings repo-wide.
- Credit: reviewed and ported from **Naveax**.

### Docs
- Privacy policy: disclosed that the server sees the connecting IP, corrected the
  "stored in memory" claim, and documented consent being changeable from the sidebar.

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
