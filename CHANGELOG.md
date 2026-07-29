# Changelog

All notable changes to the ReVoltVPN Flutter app.
Versions follow [semver](https://semver.org/): MAJOR.MINOR.PATCH

---

## [2.0.7] — Unreleased

### Added
- **Manual update checker** — "Check for updates" button in sidebar
  - Uses GitHub Releases API to find the latest version
  - Up to date → snackbar "✓ Up to date"
  - Update available → opens Play Store or GitHub releases page immediately
- **Website button** in sidebar → opens `https://getrevolt.app`
- **Timer syncing indicator** — shows "Connecting…" / "Syncing…" spinner during handshake

### Changed
- Sidebar now has 6 rows: Ad Consent, Privacy Policy, About, Discord, Website, Check for updates
- API uses domain with proper TLS validation (traffic blends in with normal HTTPS)
- VPN tunnel destination pinned to hardcoded server IP (domain compromise = DoS only)

### Security
- 6 new security audits (#8 through #12) covering domain exposure, network transit, server hardening, and pentesting
- SNI rotation per session — 5 spoofed sites instead of 1
- Outbound abuse ports blocked (SMTP, NetBIOS, SSDP)
- Xray `flow: xtls-rprx-vision` properly set server-side

### Dependencies
- `package_info_plus` added

---

## [1.0.6] — Previous release

- VLESS + Xray Reality tunnel with XTLS-Vision
- 60 min session, 4 GB throttle
- Support top-up: +30 min +2 GB via rewarded ad
- Server health dot, speed display, countdown timer
- Persistent Android notification
- Glass-morphism dark UI with yellow accent
- Right-edge sidebar with Ad Consent, Privacy, About, Discord
