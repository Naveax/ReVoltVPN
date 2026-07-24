# Xray Configuration Reference — ReVoltVPN

> Minimal production config with annotated explanations and optional upgrades.
> File lives at `/usr/local/etc/xray/config.json` on the Hetzner box.

---

## Minimal Working Config

This is what you need to deploy. Copy-paste whole.

```json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-in",
      "port": 8443,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "/tunnel" }
      }
    },
    {
      "tag": "api-in",
      "port": 10085,
      "listen": "127.0.0.1",
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ],
  "stats": {},
  "policy": {
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true
    },
    "levels": {
      "0": { "uplinkOnly": 0,   "downlinkOnly": 0   },
      "1": { "uplinkOnly": 192, "downlinkOnly": 192 }
    }
  },
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api-in"],
        "outboundTag": "direct"
      }
    ]
  }
}
```

---

## What Every Section Does

### `log`
```json
"log": { "loglevel": "warning" }
```
| Value | Behavior |
|-------|----------|
| `"none"` | Silent. Use once everything is stable. |
| `"warning"` | Only problems. Good for production. |
| `"info"` | Shows connects/disconnects. Useful for debugging. |
| `"debug"` | Every packet, every DNS query, very noisy. Use only when tracing a specific bug. |

Xray writes to stdout, which systemd captures. View with `journalctl -u xray -f`.

---

### `inbounds[0]` — VLESS tunnel entry (`vless-in`)
```json
{
  "tag": "vless-in",
  "port": 8443,
  "listen": "127.0.0.1",
  "protocol": "vless",
  "settings": {
    "clients": [],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "ws",
    "security": "none",
    "wsSettings": { "path": "/tunnel" }
  }
}
```

| Field | What it does |
|-------|--------------|
| `tag: "vless-in"` | Name used by routing rules and Python code. Must match `VLESS_INBOUND_TAG` in the server. |
| `port: 8443` | Xray listens here. nginx forwards WebSocket traffic from :443 to this port. Not exposed to the internet directly. |
| `listen: "127.0.0.1"` | Localhost only. The internet can't reach this port — nginx is the gatekeeper. |
| `protocol: "vless"` | VLESS protocol — lightweight, no built-in encryption (TLS is handled by nginx). |
| `clients: []` | Starts empty. Your Python script adds UUIDs when users watch ads via `add_vless_client()`. |
| `decryption: "none"` | VLESS-specific. Encryption is handled by the outer TLS layer (nginx + certbot). |
| `network: "ws"` | WebSocket transport — this is what makes VLESS look like regular HTTPS to DPI. |
| `security: "none"` | No internal TLS. nginx already terminated TLS. |
| `path: "/tunnel"` | The WebSocket path. Must match `VLESS_PATH` in Python and `vlessPath` in Dart. |

**Why localhost + nginx instead of exposing Xray directly?**
- nginx handles Let's Encrypt certs. Xray never touches certs.
- VLESS over WebSocket on :443 looks identical to a normal website visitor. DPI can't tell the difference.
- If Xray crashes, nginx returns 502 instead of a connection refused — cleaner for clients.

---

### `inbounds[1]` — Stats API (`api-in`)
```json
{
  "tag": "api-in",
  "port": 10085,
  "listen": "127.0.0.1",
  "protocol": "dokodemo-door",
  "settings": { "address": "127.0.0.1" }
}
```

| Field | What it does |
|-------|--------------|
| `tag: "api-in"` | Used by the routing rule to direct stats traffic. |
| `port: 10085` | Must match `XRAY_API = "http://127.0.0.1:10085"` in Python. |
| `protocol: "dokodemo-door"` | "Accept anything, just pass it through." Used because the stats API is a simple HTTP endpoint, not a proxy protocol. |
| `listen: "127.0.0.1"` | Stats API is internal only. Never expose this to the internet. |

Your Python code hits `http://127.0.0.1:10085/stats/query` to ask "how many bytes has user X used?" The response drives quota enforcement. If this port is unreachable, `get_xray_stats()` returns `{}` and quota enforcement silently stops.

---

### `outbounds`
```json
"outbounds": [
  { "protocol": "freedom", "tag": "direct" }
]
```

| Field | What it does |
|-------|--------------|
| `protocol: "freedom"` | "Send traffic to the real internet." The default outbound for all user traffic. |
| `tag: "direct"` | Name referenced by routing rules. |

This is the exit door. User traffic comes in through `vless-in`, gets processed, and leaves through `direct` to the internet. Simple setups only need one outbound. Advanced setups might have multiple (see "additions" below).

---

### `stats`
```json
"stats": {}
```
Enables Xray's internal byte counter. Without this, `get_xray_stats()` always returns `{"stat":[]}` — no quota enforcement, no per-user tracking. Required.

---

### `policy`
```json
"policy": {
  "system": {
    "statsInboundUplink": true,
    "statsInboundDownlink": true
  },
  "levels": {
    "0": { "uplinkOnly": 0,   "downlinkOnly": 0   },
    "1": { "uplinkOnly": 192, "downlinkOnly": 192 }
  }
}
```

| Field | What it does |
|-------|--------------|
| `statsInboundUplink` | Count upload bytes per user. Required for quota. |
| `statsInboundDownlink` | Count download bytes per user. Required for quota. |
| `levels.0` | Unlimited (0 = no cap). Default for new sessions. |
| `levels.1` | 192 KB/s up + down ≈ 1.5 Mbps. Applied when user exceeds 2 GB. |

**This is your throttling system.** When a user hits their quota, Python calls `set_vless_client_level(device_id, 1)`. Xray enforces the cap instantly at the protocol level — no `tc` commands, no per-IP kernel rules. When they watch a bonus ad, Python calls `set_vless_client_level(device_id, 0)` to restore full speed.

Each user gets their `level` field set when `add_vless_client()` creates their entry in the `clients` array. Level changes take effect on the next Xray hot-reload (`xray api adi`).

---

### `routing`
```json
"routing": {
  "rules": [
    {
      "type": "field",
      "inboundTag": ["api-in"],
      "outboundTag": "direct"
    }
  ]
}
```

| Field | What it does |
|-------|--------------|
| `type: "field"` | Match traffic by field (inbound tag, domain, protocol, etc). |
| `inboundTag: ["api-in"]` | "This rule applies to traffic arriving on the api-in inbound." |
| `outboundTag: "direct"` | "Send it out through the direct outbound." |

Traffic on `vless-in` (user VPN traffic) uses the default route — also `direct`, since it's the only outbound. This explicit rule for `api-in` prevents Xray from getting confused about where to send stats queries.

---

## Verification Commands

After deploying the config:

```bash
# Restart Xray
sudo systemctl restart xray

# Check it's running
sudo systemctl status xray

# Test stats API
curl http://127.0.0.1:10085/stats/query -d '{"pattern":"","reset":false}'
# Should return: {"stat":[]}

# Watch logs
sudo journalctl -u xray -f

# Test WebSocket upgrade through nginx (run after nginx config is updated)
curl -v -H "Upgrade: websocket" -H "Connection: Upgrade" https://YOURDOMAIN.com/tunnel
# Should return 101 Switching Protocols
```

---

## Optional Additions — Cherry-Pick What You Want

### 1. DNS — Stop DNS Leaks
```json
"dns": {
  "servers": [
    "1.1.1.1",
    "8.8.8.8",
    "localhost"
  ]
}
```
Xray resolves domains itself instead of using the server's system DNS. Prevents DNS leaks. The `"localhost"` fallback means "use the server's DNS if Cloudflare/Google are unreachable."

---

### 2. Connection Limits — Prevent Dead Sessions
Add to `policy.levels` entries:
```json
"0": {
  "uplinkOnly": 0,
  "downlinkOnly": 0,
  "connIdle": 300
},
"1": {
  "uplinkOnly": 192,
  "downlinkOnly": 192,
  "connIdle": 300
}
```
`connIdle: 300` = close the connection if no traffic for 5 minutes. Prevents sessions from lingering forever with the WebSocket open but idle. Saves server resources.

---

### 3. Buffer Size — Smoother Throttled Browsing
Add to throttled level:
```json
"1": {
  "uplinkOnly": 192,
  "downlinkOnly": 192,
  "bufferSize": 512
}
```
Allows short bursts up to 512 bytes above the cap before throttling kicks in. Makes throttled browsing feel less sluggish — pages load in small bursts. Without this, every single packet is capped, which feels awful at 192 KB/s.

---

### 4. Sniffing — Better App Compatibility
```json
"sniffing": {
  "enabled": true,
  "destOverride": ["http", "tls"]
}
```
Xray inspects the first few bytes of each connection to detect the real protocol (HTTP, TLS, etc.) and routes accordingly. Fixes issues with apps that don't play nice with transparent proxying. Low overhead, generally safe to enable.

---

### 5. Per-Outbound Metrics — Server-Wide Dashboard
```json
"metrics": {
  "tag": "metrics-out"
}
```
Adds total server-wide upload/download to the stats API response. Not per-user, just aggregate. Useful for a dashboard like "served 42 GB today across all users."

---

### 6. Multiple Outbounds — Future-Proofing
```json
"outbounds": [
  { "protocol": "freedom", "tag": "direct" },
  { "protocol": "blackhole", "tag": "block" }
]
```
Adds a `block` outbound that silently drops traffic. Later you could add routing rules to block specific domains (torrent trackers, malware, etc.) by routing them to `block` instead of `direct`.

With a routing rule like:
```json
{
  "type": "field",
  "domain": ["geosite:torrent"],
  "outboundTag": "block"
}
```

---

### 7. Log to File Instead of stdout
```json
"log": {
  "loglevel": "warning",
  "access": "/var/log/xray/access.log",
  "error": "/var/log/xray/error.log"
}
```
Writes access and error logs to files instead of systemd journal. Easier to grep. Make sure the directory exists and Xray can write to it:
```bash
sudo mkdir -p /var/log/xray
sudo chown xray:xray /var/log/xray
```

---

### 8. IPv6 Outbound
```json
"outbounds": [
  {
    "protocol": "freedom",
    "tag": "direct",
    "settings": {
      "domainStrategy": "UseIP"
    }
  }
]
```
`domainStrategy: "UseIP"` means "use whichever IP version the DNS returns." If you enable IPv6 on the server later, this lets Xray use it automatically. Options: `"UseIP"`, `"UseIPv4"`, `"UseIPv6"`.

---

### 9. Full Config with All Cherry-Picks Applied
```json
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": ["1.1.1.1", "8.8.8.8", "localhost"]
  },
  "inbounds": [
    {
      "tag": "vless-in",
      "port": 8443,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "/tunnel" }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    {
      "tag": "api-in",
      "port": 10085,
      "listen": "127.0.0.1",
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": { "domainStrategy": "UseIP" }
    },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "stats": {},
  "metrics": { "tag": "metrics-out" },
  "policy": {
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true
    },
    "levels": {
      "0": {
        "uplinkOnly": 0,
        "downlinkOnly": 0,
        "connIdle": 300
      },
      "1": {
        "uplinkOnly": 192,
        "downlinkOnly": 192,
        "connIdle": 300,
        "bufferSize": 512
      }
    }
  },
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api-in"],
        "outboundTag": "direct"
      }
    ]
  }
}
```

---

## Config ↔ Python Code Reference

| Config value | Python constant | What breaks if mismatched |
|---|---|---|
| `inbounds[0].tag = "vless-in"` | `VLESS_INBOUND_TAG = "vless-in"` | `add_vless_client()` can't find the inbound |
| `inbounds[0].port = 8443` | nginx `proxy_pass http://127.0.0.1:8443` | nginx can't forward to Xray |
| `inbounds[1].port = 10085` | `XRAY_API = "http://127.0.0.1:10085"` | Stats queries fail silently |
| `wsSettings.path = "/tunnel"` | `VLESS_PATH = "/tunnel"` | nginx 404s because path doesn't match |
| `policy.levels.1 = 192` | `THROTTLE_RATE_KBPS = 192` | Throttle speed doesn't match documentation |
| Config file path | `XRAY_CONFIG = "/usr/local/etc/xray/config.json"` | Server can't find the config at all |

---

## Troubleshooting Cheat Sheet

| Symptom | Check |
|---------|-------|
| `[CMD FAIL] xray api adi` | Is Xray running? `systemctl status xray` |
| Stats always return `{}` | `curl http://127.0.0.1:10085/stats/query -d '{"pattern":"","reset":false}'` |
| Clients can't connect | `curl -v -H "Upgrade: websocket" -H "Connection: Upgrade" https://DOMAIN/tunnel` |
| Clients connect but no internet | `sudo journalctl -u xray -f`, check for routing errors |
| Config changes not taking effect | `sudo systemctl restart xray` (hot-reload via API sometimes needs a restart) |
| "Address already in use" on Xray start | Port 8443 or 10085 is taken. `sudo ss -tlnp \| grep -E '8443\|10085'` |
