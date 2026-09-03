<p align="center">
  <img src="screenshots/feature_graphic.png" alt="ReVoltVPN banner" width="100%"/>
</p>

# ReVoltVPN

A free VPN app for Android. Open-source client, transparent infrastructure. Watch an ad, get 2 hours of full-speed traffic — no accounts, no logs, no subscriptions.

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

- **Transport** — VLESS over XHTTP (HTTP/2 multiplexed, path-hidden behind `/revolt`)
- **Obfuscation** — Xray Reality spoofs `some website's` TLS. To any DPI box, your tunnel looks like a browser visiting that website
- **Encryption** — TLS 1.3 with borrowed certificate (Reality). No certbot, no domain ownership required
- **API** — Standard HTTPS to a separate domain. Tunnel destination is IP-pinned — domain compromise is DoS only

---

## Stack

| Layer | Technology |
|-------|-----------|
| App | Flutter (Android) |
| VPN | VLESS + Xray Reality + XHTTP |
| Backend | Python Flask ("Hivemind") — session management, quotas, stats |
| Ads | Google AdMob rewarded, verified server-side |
| Server | Debian, single Hetzner box in Finland |

---

## Limitations

- One server, one location (Finland)
- 2 vCPU / 4 GB RAM — not built for thousands of concurrent users
- Android only

---

## Privacy

Your traffic routes through Finland. We don't log it, inspect it, or sell it. Hivemind tracks only session liveness and byte counters for quota enforcement — no packet contents, no destination IPs, no DNS queries.

Full privacy policy: [`PRIVACY_POLICY.md`](PRIVACY_POLICY.md)

---

*ReVoltVPN is not affiliated with any VPN company.*
