# Changelog

All notable changes to the ReVoltVPN Flutter app.
Versions follow [semver](https://semver.org/): MAJOR.MINOR.PATCH

---

## [1.0.7] — Unreleased

### Added
- **Manual update checker** — "Check for updates" button in sidebar
  - Uses GitHub Releases API to find the latest version
  - Up to date → snackbar "✓ Up to date (v1.0.7)"
  - Update available → opens Play Store or GitHub releases page immediately (no dialogs)
- **Website button** in sidebar → opens `https://getrevolt.app`

### Changed
- Sidebar now has 6 rows: Ad Consent, Privacy Policy, About, Discord, Website, Check for updates

### Dependencies
- `package_info_plus` added to pubspec — for reading the local version from the app bundle

---

## [1.0.6] — Previous release

- VLESS + Xray Reality tunnel with XTLS-Vision
- 60 min session, 4 GB throttle
- Support top-up: +30 min +2 GB via rewarded ad
- Server health dot, speed display, countdown timer
- Persistent Android notification
- Glass-morphism dark UI with yellow accent
- Right-edge sidebar with Ad Consent, Privacy, About, Discord
