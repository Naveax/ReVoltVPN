<p align="center">
  <img src="screenshots/feature_graphic.png" alt="ReVoltVPN banner" width="100%"/>
</p>

# ReVoltVPN

ReVoltVPN is an Android VLESS client under active hardening. The current source checkpoint focuses on authenticated local ingress, fail-closed runtime ownership, server-authoritative sessions, explicit control-plane boundaries, and reproducible release evidence. It is **not yet a production-ready release claim**.

---

## Current connection model

1. The Android client obtains a server-authoritative session through the configured HTTPS control plane.
2. The server returns temporary VLESS/REALITY/XHTTP session parameters while the tunnel destination remains pinned in the app.
3. Android starts the hardened Xray/tun2socks runtime and arms the server-derived session deadline.
4. Session status and stop requests use the current per-generation authorization credential.
5. Expiry, quota exhaustion, explicit stop, or fail-closed enforcement revoke the active server credential.

Session duration and quota are server-authoritative and are deliberately not advertised here as fixed product constants.

---

## Protocol and trust boundaries

- **Transport** — VLESS over XHTTP with Xray REALITY.
- **Tunnel destination** — pinned independently in the client; control-plane data cannot silently redirect the tunnel to an arbitrary host.
- **Control plane** — separate configured HTTPS origin. Cleartext, cross-origin, userinfo-bearing, fragmented, and invalid control-plane URLs are rejected by the hardened client path.
- **Local SOCKS ingress** — hardened source requires an authenticated loopback SOCKS5 listener and validates UDP support/relay binding. Local SOCKS readiness is not considered proof of internet UDP reachability.
- **Session authorization** — current status/stop traffic uses a per-generation credential. The backend status route deliberately returns a privacy-preserving no-session projection for missing, malformed, or mismatched credentials; stop remains authorization-enforced.
- **Fail-closed behavior** — ambiguous native shutdown, controller teardown ambiguity, and backend fail-closed state are treated as security failures rather than optimistic success.

---

## Current source state

| Layer | Current implementation |
|---|---|
| App | Flutter / Android |
| Tunnel | VLESS + REALITY + XHTTP |
| Runtime | Xray + tun2socks |
| Backend | Rust control plane with durable session/accounting state |
| Local proxy | Authenticated loopback SOCKS5 |
| Ads | Integration exists, but rewarded ads are disabled in the current client checkpoint |
| Always-on / lockdown | Intentionally not advertised; capability remains disabled pending protected bootstrap and device acceptance |

The repository contains Google AdMob SSV integration and legacy compatibility paths, but current production activation semantics remain a release blocker until the ad/callback path and session-authorization trust boundary are finalized and verified end to end.

---

## Verified CI scope

The current hardening branch has passed Android CI through:

- Flutter analyze and tests
- native Kotlin regression tests and JUnit evidence checks
- Android lint
- fail-closed release configuration checks
- runtime secret-transport checks
- always-on capability guard
- Android data/network-security policy checks
- cold and warm APK builds
- release R8 smoke build
- tracked/vendored input immutability checks

CI proves the exercised source/build contracts. It does **not** replace physical-device network tests, production backend deployment validation, signing/provenance acceptance, or published-APK verification.

---

## Still required before production acceptance

- real Android IPv4/IPv6 TCP and UDP roundtrips
- DNS UDP/TCP and Android Private DNS behavior
- Wi-Fi/LTE transition and direct-fallback/leak tests
- Xray/tun2socks crash behavior
- process/activity/service lifecycle and permission-revoke tests
- session expiry and quota-exhaustion device tests
- Discord voice/video, WebRTC, QUIC, and other UDP-heavy application checks
- production signed APK provenance/attestation
- backend H13 contract CI/deployment evidence
- a production-safe session activation flow that does not depend on enabling the legacy AdMob bypass
- separation or otherwise justified treatment of AdMob callback correlation data versus session authorization credentials

---

## Privacy

The client hardening path disables local Xray access logging and the managed public nginx boundary disables access logging on public API routes. The Rust backend retains durable session/accounting state and operational services may write service-journal events. Rewarded ads are disabled in the current client checkpoint; if Google AdMob is enabled in a future release, Google may process ad and verification data.

See [`PRIVACY_POLICY.md`](PRIVACY_POLICY.md) for the current source-backed disclosure. Production deployment, host retention, Xray/server logging, signing, and artifact provenance must still be verified before stronger privacy claims are treated as audited guarantees.

---

*ReVoltVPN is not affiliated with any VPN company.*
