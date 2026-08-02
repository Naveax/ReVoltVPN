# ReVoltVPN — Server Deployment Guide v7.0 (XHTTP + Reality + Domain-Free)

> **Last verified:** 2026-08-02 against live Xray docs at `https://xtls.github.io/en/`
> **Transport:** XHTTP (H2 stream-up) + Reality — NOT TCP, NOT XTLS-Vision
> **Spoof target:** `www.github.com` (single site, Cloudflare-backed)
> **Client:** Domain-free — API routed through tunnel, no domain in APK. See `DOCUMENTATION-ARCHITECTURE-V2.md`.

---

## Connection Flow — End to End

### Step 0: Bootstrap (V2 — domain-free)

Before the normal session flow, the app connects with a hardcoded Reality config
bundled in the APK (`bootstrapVlessUrl`). This bootstrap client is permanently
defined in `xray_config_reality.json` with `email: "bootstrap"`. Xray routing
restricts it to `10.254.254.0/24` — only the internal API, zero internet access.

```
App → bootstrap tunnel (Reality, github.com SNI) → polls 10.254.254.1:5000
                                                      ↓
                                               Xray "api" outbound
                                               (redirect: 127.0.0.1:5000)
                                                      ↓
                                               Flask Hivemind
```

The app fetches the real per-session VLESS URL through the bootstrap tunnel,
disconnects, then reconnects with the real config. From now on, ALL API calls
(health, sync, stop) go through `10.254.254.1:5000` inside the tunnel.
**Phone never makes a connection to any domain.**

### Step 1: Client taps Connect

```
App → AdMob SSV → server creates VLESS UUID → app bootstraps → polls inside tunnel

### Step 2: Server returns session config

The `/session/status` response (from `hivemind/api.py`):

```json
{
  "active":       true,
  "vless_uuid":   "550e8400-e29b-41d4-a716-446655440000",
  "vless_ip":     "204.168.246.88",
  "vless_port":   8443,
  "reality_pbk":  "fHyNQm1UbaFD3wRQn4AAx5SdVzDCzlxm8G4xprpWymI=",
  "reality_sid":  "abc123",
  "reality_sni":  "www.github.com",
  "reality_fp":   "chrome",
  "xhttp_path":   "/revolt",
  "expires_in_seconds": 3540,
  "nonce":        "1234567890-1716480000",
  "is_throttled": false
}
```

Every Reality parameter comes from the server — client has no hardcoded SNI or path.

### Step 3: Client builds VLESS URL

From these response fields, `hivemind_service.dart` builds:

```
vless://550e8400-e29b-41d4-a716-446655440000@204.168.246.88:8443
  ?security=reality
  &type=xhttp
  &path=%2Frevolt
  &pbk=fHyNQm1UbaFD3wRQn4AAx5SdVzDCzlxm8G4xprpWymI%3D
  &sni=www.github.com
  &sid=abc123
  &fp=chrome
  #ReVoltVPN
```

**Every parameter verified against live docs:**

| Parameter | Live doc source | Required? | Value |
|-----------|----------------|-----------|-------|
| `security=reality` | Reality docs: *"REALITY can only be used together with RAW, XHTTP, and gRPC"* | Yes | `reality` |
| `type=xhttp` | XHTTP docs: transport name | Yes | `xhttp` |
| `path=/revolt` | XHTTP docs: *"只需填 path，其它不填即可"* | Yes | server-defined |
| `pbk=...` | Reality docs: *"password: string — Required. The public key corresponding to the server private key."* | Yes | from `xray x25519` |
| `sni=...` | Reality docs: *"serverName: string — One of the server-side serverNames."* | Yes | from `REALITY_SNI_POOL` |
| `sid=...` | Reality docs: *"shortId: string — One of the server-side shortIds."* | Yes | `abc123` |
| `fp=chrome` | Reality docs: *"fingerprint: string — One of chrome, firefox, safari, random..."* | Yes | `chrome` |
| `host=` | XHTTP docs: *"建议没事别设"* (don't set unless needed) | No | intentionally omitted |
| `flow=` | VLESS docs: *"XTLS only available: TCP+TLS/REALITY"* (NOT XHTTP) | No | intentionally omitted |

### Step 4: flutter_vless generates Xray client config

`flutter_vless` 1.1.4 parses the VLESS URL and produces the equivalent of:

```json
{
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "204.168.246.88",
        "port": 8443,
        "users": [{
          "id": "550e8400-e29b-41d4-a716-446655440000",
          "encryption": "none",
          "flow": ""
        }]
      }]
    },
    "streamSettings": {
      "network": "xhttp",
      "security": "reality",
      "xhttpSettings": {
        "path": "/revolt"
      },
      "realitySettings": {
        "serverName": "www.github.com",
        "fingerprint": "chrome",
        "publicKey": "fHyNQm1UbaFD3wRQn4AAx5SdVzDCzlxm8G4xprpWymI=",
        "shortId": "abc123",
        "spiderX": ""
      }
    }
  }]
}
```

### Step 5: TLS handshake (Reality)

```
Client                              Server (Xray)
  |                                     |
  |── ClientHello ────────────────────→|
  |   SNI: www.github.com              |
  |   ALPN: h2 (H2 default w/ Reality) |
  |   random session ID                |
  |                                     |
  |←── ServerHello ────────────────────|
  |   Certificate: github.com's REAL   |
  |   cert (fetched from               |
  |   www.github.com:443 by Xray)      |
  |   Signed with Reality privateKey   |
  |                                     |
  |── auth: pbk + shortId ───────────→|
  |   (embedded in TLS extension)      |
  |                                     |
  |←── TLS 1.3 handshake complete ────|
```

To any DPI box, this looks exactly like a browser connecting to GitHub.

### Step 6: HTTP/2 + VLESS inside the TLS tunnel

```
Inside the TLS tunnel:
  ┌─────────────────────────────────┐
  │  HTTP/2 connection              │
  │  :method: POST                  │
  │  :path: /revolt                 │  ← XHTTP path matching
  │  :authority: www.github.com     │  ← Host header (SNI fallback)
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │  VLESS payload            │  │
  │  │  UUID auth: ✓             │  │
  │  │  Actual VPN traffic       │  │
  │  └───────────────────────────┘  │
  └─────────────────────────────────┘
```

### Step 7: Xray routes traffic

```
Phone → Xray Reality (8443)
           │
           ├─ dest: 10.254.254.0/24 → api outbound (redirect → Flask 127.0.0.1:5000)
           ├─ user: bootstrap, other dest → block (blackhole)
           ├─ port: 25,465,587 → block (SMTP)
           ├─ port: 135-139,445 → block (NetBIOS)
           ├─ port: 1900 → block (SSDP)
           └─ default → direct (freedom → internet)
```

---

## Will it work? — Answer

**Yes, if these 5 things are true on the server:**

1. ✅ `xray_config_reality.json` deployed to `/usr/local/etc/xray/config.json` with the real private key
2. ✅ `hivemind/config.py` has the matching public key in `REALITY_PUBLIC_KEY`
3. ✅ Bootstrap UUID generated (`xray uuid`) and placed in BOTH `xray_config_reality.json` AND `app_config.dart`
4. ✅ Xray restarted after config deploy
5. ✅ Firewall allows inbound 8443 (and 8444 for throttled)

**The config is internally consistent.** Every parameter flows from a single source:
- `config.py` → API → client → `flutter_vless` → Xray client config
- `config.json` → Xray server inbound

If those match (and they do in this repo), the tunnel will establish.

---

## Server Setup (clean deploy)

### 1. Install Xray

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

### 2. Generate Reality keypair

```bash
xray x25519
# Output:
# Private key: <44-char base64>   ← goes in xray_config_reality.json
# Public key:  <44-char base64>   ← goes in hivemind/config.py
```

### 3. Generate bootstrap UUID

```bash
xray uuid
# Output: 6ba7b810-9dad-11d1-80b4-00c04fd430c8
```

Put this UUID in TWO places:
1. `xray_config_reality.json` — replace `BOOTSTRAP-UUID-REPLACE-ME` in the bootstrap client's `"id"` field
2. `lib/logic/app_config.dart` — replace `BOOTSTRAP-UUID-GOES-HERE` in `bootstrapUuid`

### 4. Deploy Xray config

Copy `xray_config_reality.json` from this repo → `/usr/local/etc/xray/config.json` on the server.

Replace the private key with the one you just generated:
```json
"privateKey": "YOUR_GENERATED_PRIVATE_KEY"
```

```bash
chmod 600 /usr/local/etc/xray/config.json
systemctl restart xray
systemctl status xray   # verify: active (running)
```

### 5. Verify Xray is listening

```bash
ss -tlnp | grep -E '8443|8444'
# Should show:
# LISTEN  0.0.0.0:8443   (Xray — full speed)
# LISTEN  0.0.0.0:8444   (Xray — throttled)
```

### 6. Verify the spoof cert is reachable

```bash
xray tls ping www.github.com:443
# Should show: certificate size > 3500 bytes (good for Reality)
```

### 7. Deploy Python Hivemind

Upload to `/root/`:
```
server_hivemind_5_0.py        ← entry point
hivemind/                     ← package (8 files)
  ├── config.py               ← EDIT: public key, server IP
  ├── sessions.py
  ├── xray.py
  ├── admob.py
  ├── management.py
  ├── api.py
  ├── main.py
  └── __init__.py
```

### 8. Edit hivemind/config.py

```python
REALITY_PUBLIC_KEY  = "YOUR_GENERATED_PUBLIC_KEY"   # from xray x25519
VLESS_SERVER_IP     = "YOUR_SERVER_IP"              # Hetzner/VPS IP
REALITY_SNI_POOL    = ["www.github.com"]            # spoof target
VLESS_XHTTP_PATH    = "/revolt"                     # must match config.json
```

### 9. Install Python dependencies

```bash
pip install flask requests
```

### 10. Create systemd unit

`/etc/systemd/system/hivemind.service`:
```ini
[Unit]
Description=ReVoltVPN Hivemind
After=network.target xray.service

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/usr/bin/python3 -m gunicorn -w 1 -b 127.0.0.1:5000 hivemind.main:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now hivemind
systemctl status hivemind
```

### 11. Firewall

```bash
# Only open what's needed
ufw allow 443/tcp    # nginx HTTPS (API)
ufw allow 8443/tcp   # Xray Reality (full speed)
ufw allow 8444/tcp   # Xray Reality (throttled)
ufw allow 80/tcp     # certbot HTTP challenge
ufw enable

# Keep these internal-only
# 5000 — Flask (localhost only, via nginx)
# 10085 — Xray API (localhost only)
```

### 12. nginx (AdMob SSV + website)

nginx now serves only two purposes — the app itself never connects to it:
- AdMob SSV callbacks (`/api/admob/callback`) — Google → your server, not phone → server
- Branding website at the root — user's browser, manually

Xray handles all app-to-server traffic through the Reality tunnel.

`/etc/nginx/sites-available/revolt`:
```nginx
server {
    listen 443 ssl http2;
    server_name YOUR_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/YOUR_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/YOUR_DOMAIN/privkey.pem;

    location /api/ {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location / {
        root /var/www/revolt;
        index index.html;
    }
}

server {
    listen 80;
    server_name YOUR_DOMAIN;
    return 301 https://$host$request_uri;
}
```

### 13. certbot (Let's Encrypt)

```bash
apt install certbot python3-certbot-nginx
certbot --nginx -d YOUR_DOMAIN
```

---

## Smoke Test

### From the server:

```bash
# 1. Is Xray running?
systemctl status xray

# 2. Is Hivemind running?
systemctl status hivemind

# 3. Can Hivemind reach Xray API?
curl http://127.0.0.1:10085/stats/query -d '{"pattern":"","reset":false}'

# 4. Is Flask alive internally?
curl http://127.0.0.1:5000/api/health
# → {"ok": true}

# 5. Does the API route through Xray work? (simulate tunnel → 10.254.254.1 → Flask)
curl http://10.254.254.1:5000/api/health
# → should fail (only reachable through Xray tunnel, not directly)

# 6. Does the spoof target work?
xray tls ping www.github.com:443
```

### From a client (after building the Flutter app):

The app no longer hits any domain. All API calls go through the tunnel.
Verify by building and running the app in debug mode (`ADMOB_BYPASS=True`).

```bash
# 7. Tap Connect → app bootstraps → polls inside tunnel → reconnects → timer starts
# 8. Health dot turns green (API reachable through tunnel)
# 9. Session timer syncs (5 second countdown updates)
# 10. Tap Disconnect → timer stops → cleanup POST goes through tunnel → tunnel drops
```

### Full integration test:

```
11. Trigger 4 GB → timer shows port-swap → reconnects through bootstrap → speed reduced
12. Support ad top-up → +30 min +2 GB → timer updates without reconnect
13. Kill app while connected → reopen → timer resumes (startup restoration)
```

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| App says "Connecting..." forever | Server firewall blocking 8443? `ufw status` |
| App connects but no internet | Xray routing broken? Check `journalctl -u xray -f` |
| `/session/status` returns 500 | Hivemind crashed? `systemctl status hivemind` |
| `xray tls ping` fails | Server can't reach GitHub? DNS? IPv6? |
| Stats show 0 bytes | Users missing `email` field? Check `xray.py:add_client()` |
| Tunnel starts but immediately dies | `providerBundleIdentifier` mismatch? Must be `com.paladinvpn.app` |
| "Session not activated" in app | ADMOB_BYPASS not True? Or SSV callback not firing |
| App stuck on "Establishing secure channel…" | Bootstrap UUID mismatch between APK and xray_config? |
| Health dot gray after tunnel connects | `api` outbound not working? Check Xray routing rules |
| Bootstrap tunnel starts but no config | Hivemind not running on 127.0.0.1:5000? `systemctl status hivemind` |

---

## Changing the spoof target

If you ever want to switch from GitHub to another site:

1. Edit `REALITY_SNI_POOL` in `hivemind/config.py`
2. Edit `serverNames` in **both** inbounds in `config.json` (add site + root domain)
3. Update `dest` in `config.json` to the new target
4. Verify: `xray tls ping NEW_TARGET:443` — cert must be > 3500 bytes
5. `systemctl restart xray`

---

## Differences from old TCP/Vision setup

| What | Old (SERVER_SETUP.md) | New (this doc) |
|------|----------------------|----------------|
| Transport | `tcp` | `xhttp` |
| Flow | `xtls-rprx-vision` | (none — XTLS doesn't work with XHTTP) |
| Spoof target | `www.microsoft.com` | `www.github.com` |
| Path | (none — TCP) | `/revolt` (XHTTP path) |
| Rate limiting | `uplinkOnly: 187500` (wrong) | `uplinkOnly: 2` (correct seconds), real cap via `tc` |
| shortIds | 3 entries | 1 entry matching `REALITY_SHORT_ID` |
| Fallback limits | Not present | Intentionally omitted (fingerprint risk per live docs) |
| `xhttp_path` in API | Not present | Server sends path, client reads it |
| `providerBundleIdentifier` | `com.revoltvpn.app` | `com.paladinvpn.app` |
| API transport | HTTPS to domain | Tunnel-internal to `10.254.254.1:5000` |
| Domain in APK | `getrevolt.app` | **None** — zero domain strings |
| Bootstrap | None (external API polling) | Hardcoded Reality config, tunnel-only API fetch |
| Xray outbounds | `direct` + `block` | `direct` + `block` + `api` (redirect → Flask) |
