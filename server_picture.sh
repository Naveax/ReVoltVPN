#!/bin/bash
# PaladinVPN — Full Server Picture (VLESS era)
# Copy-paste this entire block into your SSH terminal on the Hetzner Debian box.
# Read-only — makes no changes to the system.
# Run as root or with sudo.

bash <<'REPORT'
echo "============================================================"
echo "  PaladinVPN — Server State Report"
echo "  $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "============================================================"

# ── 1. System ────────────────────────────────────────────────
echo ""; echo "=== SYSTEM ==="
echo "Hostname : $(hostname)"
echo "Uptime   : $(uptime -p)"
echo "Debian   : $(cat /etc/debian_version 2>/dev/null || echo 'N/A')"
echo "Kernel   : $(uname -r)"
echo "Arch     : $(uname -m)"
echo "Load     : $(uptime | awk -F'load average:' '{print $2}' | xargs)"
echo ""
echo "CPU:"
echo "$(lscpu | grep -E 'Model name|CPU\(s\)|Thread' | sed 's/^/  /')" 2>/dev/null
echo ""
echo "Memory:"
free -h | grep -E '^Mem:|^Swap:' | sed 's/^/  /'
echo ""
echo "Disk:"
df -h / | tail -1 | awk '{print "  Root: " $3 "/" $2 " (" $5 ")"}'

# ── 2. Network Interfaces ────────────────────────────────────
echo ""; echo "=== NETWORK INTERFACES ==="
ip -br addr 2>/dev/null || ifconfig -a 2>/dev/null
echo ""
echo "Routes:"
ip route show 2>/dev/null | grep -v '^fe80' || route -n
echo ""
echo "DNS:"
cat /etc/resolv.conf 2>/dev/null | grep -v '^#' | grep -v '^$' | sed 's/^/  /'

# ── 3. Open Ports ────────────────────────────────────────────
echo ""; echo "=== LISTENING PORTS ==="
ss -tlnp 2>/dev/null | head -30 || netstat -tlnp 2>/dev/null | head -30

# ── 4. IPv6 Status ───────────────────────────────────────────
echo ""; echo "=== IPv6 ==="
echo "Forwarding:"
sysctl net.ipv6.conf.all.forwarding 2>/dev/null
echo ""
echo "IPv6 routes:"
ip -6 route show 2>/dev/null | head -10
echo ""
echo "IPv6 NAT (ip6tables):"
ip6tables -t nat -L POSTROUTING -n 2>/dev/null | head -10 || echo "  ip6tables not available"

# ── 5. Firewall (iptables) ───────────────────────────────────
echo ""; echo "=== IPTABLES NAT ==="
iptables -t nat -L POSTROUTING -n -v 2>/dev/null | head -20 || echo "  iptables not available"

# ── 6. Services ──────────────────────────────────────────────
echo ""; echo "=== SERVICES ==="
for svc in hivemind xray nginx docker certbot; do
    if systemctl is-enabled "$svc" &>/dev/null; then
        printf "  %-12s : %s (enabled)\n" "$svc" "$(systemctl is-active "$svc")"
    elif systemctl is-active "$svc" &>/dev/null; then
        printf "  %-12s : %s (not enabled)\n" "$svc" "$(systemctl is-active "$svc")"
    else
        printf "  %-12s : not found\n" "$svc"
    fi
done
echo ""
echo "Certbot timer:"
systemctl list-timers --all 2>/dev/null | grep -i certbot || echo "  No certbot timer found"

# ── 7. Xray ──────────────────────────────────────────────────
echo ""; echo "=== XRAY ==="
if command -v xray &>/dev/null; then
    echo "Binary  : $(which xray)"
    echo "Version : $(xray version 2>&1 | head -1)"
    echo "Status  : $(systemctl is-active xray 2>/dev/null || echo 'N/A')"
    echo ""
    echo "Config file exists?"
    if [ -f /usr/local/etc/xray/config.json ]; then
        echo "  YES — $(wc -c < /usr/local/etc/xray/config.json) bytes"
        echo "  Clients: $(python3 -c "import json; c=json.load(open('/usr/local/etc/xray/config.json')); print(len(c['inbounds'][0]['settings']['clients']))" 2>/dev/null || echo 'ERROR reading config')"
    else
        echo "  NO — /usr/local/etc/xray/config.json not found"
    fi
    echo ""
    echo "Stats API:"
    curl -s --max-time 3 http://127.0.0.1:10085/stats/query -d '{"pattern":"","reset":false}' 2>/dev/null | python3 -m json.tool 2>/dev/null | head -10 || echo "  Stats API unreachable"
    echo ""
    echo "Last 5 Xray log lines:"
    journalctl -u xray --no-pager -n 5 2>/dev/null | sed 's/^/  /' || echo "  No journal entries"
else
    echo "  Xray NOT INSTALLED"
fi

# ── 8. Hivemind ──────────────────────────────────────────────
echo ""; echo "=== HIVEMIND ==="
echo "Status : $(systemctl is-active hivemind 2>/dev/null || echo 'N/A')"
echo "Config : $(systemctl cat hivemind 2>/dev/null | grep -i execstart | sed 's/^/  /')"
echo ""
echo "Active sessions:"
python3 -c "
import sys; sys.path.insert(0, '/root')
try:
    from server_hivemind_5_0 import active_sessions, sessions_lock
    with sessions_lock:
        count = len(active_sessions)
        throttled = sum(1 for s in active_sessions.values() if s.get('is_throttled'))
    print(f'  Total: {count}  Throttled: {throttled}')
except Exception as e:
    print(f'  Could not read sessions: {e}')
" 2>/dev/null || echo "  Could not import hivemind module"
echo ""
echo "Hivemind script:"
if [ -f /root/server_hivemind_5_0.py ]; then
    echo "  /root/server_hivemind_5_0.py — $(wc -l < /root/server_hivemind_5_0.py) lines"
elif [ -f /root/server_hivemind_* ]; then
    ls -la /root/server_hivemind_* 2>/dev/null | sed 's/^/  /'
else
    echo "  No hivemind script found in /root"
fi
echo ""
echo "Last 10 Hivemind log lines:"
journalctl -u hivemind --no-pager -n 10 2>/dev/null | sed 's/^/  /' || echo "  No journal entries"

# ── 9. Nginx ─────────────────────────────────────────────────
echo ""; echo "=== NGINX ==="
if command -v nginx &>/dev/null; then
    echo "Binary  : $(which nginx)"
    echo "Version : $(nginx -v 2>&1)"
    echo "Status  : $(systemctl is-active nginx 2>/dev/null || echo 'N/A')"
    echo ""
    echo "Config test:"
    nginx -t 2>&1 | sed 's/^/  /'
    echo ""
    echo "Sites enabled:"
    ls -la /etc/nginx/sites-enabled/ 2>/dev/null | sed 's/^/  /'
    echo ""
    echo "/tunnel location block exists?"
    grep -r "location /tunnel" /etc/nginx/sites-enabled/ 2>/dev/null | sed 's/^/  /' || echo "  NOT FOUND"
    echo ""
    echo "/api location block exists?"
    grep -r "location /api" /etc/nginx/sites-enabled/ 2>/dev/null | sed 's/^/  /' || echo "  NOT FOUND"
else
    echo "  NGINX NOT INSTALLED"
fi

# ── 10. SSL ──────────────────────────────────────────────────
echo ""; echo "=== SSL CERTIFICATES ==="
if command -v certbot &>/dev/null; then
    certbot certificates 2>/dev/null | sed 's/^/  /' || echo "  No certificates found"
    echo ""
    echo "Certificate files:"
    ls -la /etc/letsencrypt/live/ 2>/dev/null | sed 's/^/  /' || echo "  /etc/letsencrypt/live/ not found"
else
    echo "  certbot not installed"
fi

# ── 11. Docker ────────────────────────────────────────────────
echo ""; echo "=== DOCKER ==="
if command -v docker &>/dev/null; then
    echo "Running containers:"
    docker ps --format '  {{.Names}}  {{.Image}}  {{.Status}}  {{.Ports}}' 2>/dev/null || echo "  None"
else
    echo "  Docker not installed"
fi

# ── 12. Traffic Control (tc) ─────────────────────────────────
echo ""; echo "=== TRAFFIC CONTROL (tc) ==="
if command -v tc &>/dev/null; then
    for iface in $(ip -br link 2>/dev/null | awk '{print $1}'); do
        rules=$(tc qdisc show dev "$iface" 2>/dev/null | grep -v "noqueue\|fq_codel\|pfifo_fast" | head -5)
        if [ -n "$rules" ]; then
            echo "  Interface $iface:"
            echo "$rules" | sed 's/^/    /'
        fi
    done
    echo "  (no custom tc rules found unless listed above)"
else
    echo "  tc not available"
fi

# ── 13. AWG leftovers ────────────────────────────────────────
echo ""; echo "=== AWG LEFTOVERS ==="
echo "awg0 interface : $([ -d /sys/class/net/awg0 ] && echo 'STILL EXISTS' || echo 'gone ✓')"
echo "awg binary     : $(command -v awg 2>/dev/null && echo 'STILL INSTALLED' || echo 'gone ✓')"
echo "wg-easy docker : $(docker ps -a --filter 'name=wg-easy' --format '{{.Names}}' 2>/dev/null || echo 'gone ✓')"
echo "iptables 10.8.x: $(iptables -t nat -L POSTROUTING 2>/dev/null | grep '10\.8\.' | head -3 || echo 'gone ✓')"

# ── 14. Recent Errors ────────────────────────────────────────
echo ""; echo "=== RECENT ERRORS (last 50 journal lines, filtered) ==="
journalctl -u hivemind -u xray -u nginx --no-pager -n 50 --since "1 hour ago" 2>/dev/null | grep -iE 'error|fail|warn|exception|cannot|denied|timeout' | tail -10 | sed 's/^/  /' || echo "  No recent errors"

echo ""; echo "============================================================"
echo "  Report complete — $(date '+%H:%M:%S')"
echo "============================================================"
REPORT
