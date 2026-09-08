<p align="center">
  <img src="screenshots/feature_graphic.png" alt="ReVoltVPN banner" width="100%"/>
</p>

# ReVoltVPN

A free VPN app for Android. Open-source client, transparent infrastructure. Watch an ad, get 2 hours of full-speed traffic — no account or subscription required, and no browsing-traffic logging is intended by the service design.

---

## How it works

1. Watch a short rewarded ad
2. Server creates a temporary VLESS session (2 hours / 10 GB)
3. Your traffic routes through a single server in Finland at full speed
4. When time or data runs out, session ends — watch another ad to continue
5. No throttling, no slow lane, no mid-session punishment

No email. No password. No payment. The ad pays for the server.

---

## Protocol

- **Transport** — VLESS over XHTTP. The client accepts session credentials and Reality parameters from the control plane while keeping the tunnel destination pinned in the app.
- **Camouflage** — Xray REALITY is used to make the transport resemble ordinary TLS traffic. Its effectiveness depends on the network and DPI implementation; the client does not claim universal DPI invisibility.
- **Encryption** — The tunnel uses Xray's VLESS + REALITY transport. ReVolt does not rely on a user-managed certificate/domain for the tunnel endpoint.
- **Control plane** — Session/status traffic uses a separate configured HTTPS origin. The client rejects cleartext or cross-origin control-plane requests and pins the VLESS tunnel destination independently. The control plane remains a security boundary for session issuance and must not be treated as "DoS only" if compromised.

---

## Stack

| Layer | Technology |
|-------|-----------|
| App | Flutter (Android) |
| VPN | VLESS + Xray REALITY + XHTTP |
| Backend | Hivemind control plane — session management, quotas, stats |
| Ads | Google AdMob rewarded, verified server-side |
| Server | Debian, single Hetzner box in Finland |

---

## Limitations

- One server, one location (Finland)
- 2 vCPU / 4 GB RAM — not built for thousands of concurrent users
- Android only
- True Android always-on/lockdown support is not currently advertised; the native service keeps that capability disabled until protected bootstrap and device acceptance are complete

---

## Privacy

The client is designed not to create Xray browsing/access logs locally, and its tunnel destination is separate from the HTTPS session control plane. The service still has operational/session metadata needed for quota and reliability handling. See [`PRIVACY_POLICY.md`](PRIVACY_POLICY.md) for the stated data handling and retention behavior; production deployment behavior should be verified against that policy before release claims are treated as audited guarantees.

---

*ReVoltVPN is not affiliated with any VPN company.*
