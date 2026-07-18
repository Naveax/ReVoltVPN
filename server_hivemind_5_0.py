#!/usr/bin/env python3
"""
Hivemind VPN Session Manager
Manages time + data quotas for AmneziaWG peers via ad rewards.
Designed for Android-only clients.

=== TABLE OF CONTENTS ===========================================================
  LINE     SECTION
   44      Configuration — ad rewards, throttle rate, check interval
   60      State & Cache — sessions dict, IP pool, server pubkey
   93      Flask Routes — /admob/callback, /session/status, /session/stop
  220      Session Logic — _start_or_extend_session (create / extend)
  295      AdMob SSV Verification — Google ECDSA signature checks
  380      Management Loop — expiry + data-quota watchdog (60 s tick)
  426      Low-Level Plumbing — awg commands, tc throttling, IP pool, peers
  567      Entry Point — daemon thread + gunicorn bootstrap
================================================================================
"""

import time
import subprocess
import threading
import json
import requests
import shlex
import re
import urllib.parse
import ipaddress
import base64
from flask import Flask, request, jsonify
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.serialization import load_der_public_key, load_pem_public_key

app = Flask(__name__)

# Compiled once at startup for performance
_WG_PUBKEY_RE = re.compile(r'^[A-Za-z0-9+/]{43}=$')

def validate_wg_pubkey(pubkey: str) -> bool:
    """Rejects any string that isn't a valid 44-char base64 WireGuard public key."""
    return bool(pubkey and _WG_PUBKEY_RE.match(pubkey))

# ==============================================================================
# CONFIGURATION
# ==============================================================================
CHECK_INTERVAL_SECONDS = 60      # Checking every 1 minute is extremely safe and uses 0% CPU.
WG_INTERFACE = "awg0"

# Main Ad Rewards
MAIN_AD_MINUTES = 60
MAIN_AD_BYTES = 2 * 1024 * 1024 * 1024     # 2 GB

# Bonus Ad Rewards
BONUS_AD_MINUTES = 30
BONUS_AD_BYTES = 1 * 1024 * 1024 * 1024    # 1 GB

THROTTLE_RATE = "1.5mbit"

# AdMob SSV verification toggle
#   True  = dev mode, accept any callback (no signature check)
#   False = prod mode, enforce Google ECDSA signature verification
#
# ⚠️  Set to False AFTER Google Play verifies your AdMob implementation is
#     working correctly with real rewarded ads.  Until then, keep True so
#     the debug fake-callback path in the Flutter app still functions.
ADMOB_BYPASS = True

# ==============================================================================
# STATE & CACHE
# ==============================================================================
sessions_lock = threading.Lock()
# Paste your Server Public Key here if dynamic fetching keeps failing
# Example: SERVER_PUBKEY_FALLBACK = "abc123xyz..."
SERVER_PUBKEY_FALLBACK = None
SERVER_PUBKEY = None

# Keyed by device_id (e.g. "esf-18fc2...")
# {
#   "device_id": {
#       "ip":             "10.8.0.100",
#       "pubkey":         "abc123xyz...",
#       "expires_at":     1716480000,
#       "quota_bytes":    2147483648,
#       "baseline_bytes": 0,
#       "is_throttled":   False,
#       "nonce":          "a7f3b2-1716480000000",
#   }
# }
active_sessions = {}

# Pre-computed pool of all available IPv4 addresses in the 10.8.0.0/16 subnet
# (10.8.0.0 through 10.8.255.255 = 65,534 host addresses).
# Initialised once at module load; allocate_ip() pops from it, release_ip() returns to it.
AVAILABLE_IPS = {str(ip) for ip in ipaddress.IPv4Network('10.8.0.0/16').hosts()}
AVAILABLE_IPS.discard('10.8.0.1')  # reserved for gateway


# ==============================================================================
# FLASK ROUTES  (API surface — what the outside world sees)
# ==============================================================================

@app.route('/api/admob/callback', methods=['GET'])
def admob_callback():
    """
    Google AdMob SSV callback — called server-to-server when a rewarded ad completes.
    The Android client never touches this endpoint; Google calls it directly.

    custom_data (JSON, set by the app before showing the ad):
      { "device_id": "...", "public_key": "...", "ad_type": "main_ad"|"bonus_ad", "nonce": "..." }
    """
    try:
        if ADMOB_BYPASS:
            # ── DEV: accept any callback without signature verification ──
            custom_data_str = request.args.get('custom_data')
            if not custom_data_str:
                return "OK", 200
        else:
            # ── PROD: enforce Google ECDSA signature verification ────────
            signature       = request.args.get('signature')
            key_id          = request.args.get('key_id')
            custom_data_str = request.args.get('custom_data')

            # Google sends a verification ping with signature+key_id but no custom_data
            if not custom_data_str:
                return "OK", 200

            if not all([signature, key_id]):
                return "Missing parameters", 400

            raw_qs = request.query_string.decode("utf-8")
            if not _verify_admob_signature(raw_qs, signature, key_id):
                print("[ADMOB] Rejected callback — invalid signature.")
                return "Forbidden", 403

        custom_data   = json.loads(custom_data_str)
        device_id     = custom_data.get('device_id')
        client_pubkey = custom_data.get('public_key')
        
        if not device_id or not client_pubkey:
            return "Invalid custom_data payload", 400

        ad_type       = custom_data.get('ad_type', 'main_ad')
        nonce         = custom_data.get('nonce', None)

        success, msg = _start_or_extend_session(device_id, client_pubkey, ad_type, nonce)
        return ("OK", 200) if success else (msg, 500)

    except Exception as e:
        print(f"[ADMOB] SSV Error: {e}")
        return "Internal Error", 500


@app.route('/api/session/status', methods=['GET'])
def session_status():
    """
    Query: ?device_id=esf-xxx
    Returns current session state so the Android app can construct its AmneziaWG config.
    """
    device_id = request.args.get('device_id')
    if not device_id:
        return jsonify({"error": "Missing query parameter: device_id"}), 400

    with sessions_lock:
        session = active_sessions.get(device_id)

    if not session:
        return jsonify({"active": False, "message": "No session found."}), 404

    # Bulletproof fallback: If server public key is missing, try fetching it right now
    global SERVER_PUBKEY
    if not SERVER_PUBKEY:
        pubkey = run_cmd("awg show awg0 public-key")
        if pubkey:
            SERVER_PUBKEY = pubkey
            print(f"[AWG] Dynamic Server Public Key cached from awg0: {SERVER_PUBKEY}")
        else:
            SERVER_PUBKEY = SERVER_PUBKEY_FALLBACK or "server key="

    stats          = get_wireguard_stats()
    current_bytes  = stats.get(session["ip"], {}).get("total_bytes", 0)
    used_bytes     = max(0, current_bytes - session["baseline_bytes"])
    remaining_data = max(0, session["quota_bytes"] - used_bytes)
    remaining_secs = max(0, session["expires_at"] - time.time())

    return jsonify({
        "active":             remaining_secs > 0,
        "client_ip":          session["ip"],
        "client_ipv6":        session.get("ipv6", ""),
        "server_pubkey":      SERVER_PUBKEY,
        "is_throttled":       session["is_throttled"],
        "expires_in_seconds": int(remaining_secs),
        "quota_bytes":        session["quota_bytes"],
        "used_bytes":         used_bytes,
        "remaining_bytes":    remaining_data,
        "nonce":              session.get("nonce", ""),
    })


@app.route('/api/session/stop', methods=['POST'])
def session_stop():
    """Allows the app to explicitly tear down its session on disconnect."""
    data = request.get_json(silent=True)
    device_id = data.get('device_id') if data else None
    
    if device_id:
        with sessions_lock:
            session = active_sessions.pop(device_id, None)
            if session:
                remove_wg_peer(session["pubkey"])
                if session["is_throttled"]:
                    remove_throttle(session["ip"])
                release_ip(session["ip"])
                print(f"[API] Explicit stop for {device_id}.")
                
    return jsonify({"success": True})


# ==============================================================================
# SESSION LOGIC
# ==============================================================================

def _start_or_extend_session(device_id, client_pubkey, ad_type, nonce=None):
    """Core logic to provision or extend a session.
    
    nonce -- client-generated random token; stored in session and echoed
             back in /session/status so the client can reject stale sessions.
    """
    if not re.match(r"^[A-Za-z0-9+/=]{43,44}$", client_pubkey):
        return False, "Invalid WireGuard public key format"

    now = time.time()
    
    with sessions_lock:
        if device_id in active_sessions and ad_type == 'bonus_ad':
            # Extend existing session
            session = active_sessions[device_id]
            session["expires_at"]  += (BONUS_AD_MINUTES * 60)
            session["quota_bytes"] += BONUS_AD_BYTES
            
            if session["is_throttled"]:
                remove_throttle(session["ip"])
                session["is_throttled"] = False
                
                stats = get_wireguard_stats()
                current_bytes = stats.get(session["ip"], {}).get("total_bytes", 0)
                session["baseline_bytes"] = current_bytes
            
            print(f"[SESSION] Bonus time added for {device_id} (IP: {session['ip']}).")
            return True, "Bonus time and data added."
        
        else:
            # Create a brand new session (Main Ad)
            if not validate_wg_pubkey(client_pubkey):
                print(f"[SESSION] Rejected invalid pubkey from {device_id[:8]}...")
                return False, "Invalid public key format."

            existing = active_sessions.get(device_id)
            if existing:
                if existing["is_throttled"]:
                    remove_throttle(existing["ip"])
                remove_wg_peer(existing["pubkey"])
                release_ip(existing["ip"])
            
            ipv4 = allocate_ip()
            if not ipv4:
                return False, "Server full! No available IP addresses."
            
            ipv6 = ipv4_to_ipv6(ipv4)
            add_wg_peer(client_pubkey, ipv4, ipv6)
            
            # Fetch immediate stats to set baseline
            # (Though brand new peers usually start at 0)
            stats = get_wireguard_stats()
            current_bytes = stats.get(ipv4, {}).get("total_bytes", 0)

            active_sessions[device_id] = {
                "ip":             ipv4,
                "ipv6":           ipv6,
                "pubkey":         client_pubkey,
                "expires_at":     now + (MAIN_AD_MINUTES * 60),
                "quota_bytes":    MAIN_AD_BYTES,
                "baseline_bytes": current_bytes,
                "is_throttled":   False,
                "nonce":          nonce,
            }
            print(f"[SESSION] Main session started for {device_id} (IP: {ipv4} / {ipv6}).")
            return True, "Main session active."





# ==============================================================================
# ADMOB SERVER-TO-SERVER (SSV) VERIFICATION
# ==============================================================================
ADMOB_KEYS_URL = "https://www.gstatic.com/admob/reward/verifier-keys.json"

# Cache: { key_id_str: EllipticCurvePublicKey }
# Refreshed at most once every 24 hours so we don't hammer Google's CDN.
_admob_key_cache       = {}
_admob_keys_fetched_at = 0.0
_ADMOB_KEY_TTL         = 86400  # seconds


def _get_admob_public_key(key_id: str):
    """
    Returns the Google ECDSA public-key object for the given key_id.
    Fetches and caches the key list from gstatic; refreshes every 24h.
    Returns None if the key_id is unknown.
    """
    global _admob_key_cache, _admob_keys_fetched_at

    now = time.time()
    if now - _admob_keys_fetched_at > _ADMOB_KEY_TTL or not _admob_key_cache:
        try:
            resp = requests.get(ADMOB_KEYS_URL, timeout=5)
            resp.raise_for_status()
            data = resp.json()

            new_cache = {}
            for entry in data.get("keys", []):
                kid = str(entry["keyId"])
                pem = entry["pem"].encode()
                new_cache[kid] = load_pem_public_key(pem)

            _admob_key_cache       = new_cache
            _admob_keys_fetched_at = now
            print(f"[ADMOB] Refreshed {len(new_cache)} public key(s) from Google.")

        except Exception as e:
            print(f"[ADMOB] WARNING: Could not refresh public keys: {e}")
            # Fall through with stale cache rather than rejecting all valid callbacks

    return _admob_key_cache.get(key_id)


def _verify_admob_signature(raw_query_string: str, signature_b64url: str, key_id: str) -> bool:
    """
    Verifies an AdMob SSV ECDSA-SHA256 signature.
    Google signs all query params EXCEPT 'signature' and 'key_id', in original order.
    """
    try:
        public_key = _get_admob_public_key(key_id)
        if not public_key:
            print("[ADMOB] Unknown key_id — rejecting callback.")
            return False

        # Reconstruct the signed payload by stripping signature + key_id from raw qs
        parsed = urllib.parse.parse_qs(raw_query_string, keep_blank_values=True)

        # Google signs query params in the exact order they appear in the URL.
        # Use the raw string to preserve ordering — parse_qs loses it.
        ordered_pairs = []
        for pair in raw_query_string.split('&'):
            if '=' not in pair:
                continue
            k, v = pair.split('=', 1)
            if k in ('signature', 'key_id'):
                continue
            ordered_pairs.append(f"{k}={v}")
        payload = '&'.join(ordered_pairs).encode('utf-8')

        # Google uses URL-safe base64 (no padding) for the signature
        sig_bytes = base64.urlsafe_b64decode(signature_b64url + '==')

        public_key.verify(
            sig_bytes,
            payload,
            ec.ECDSA(hashes.SHA256())
        )
        return True

    except Exception as e:
        print(f"[ADMOB] Signature verification failed: {e}")
        return False


# ==============================================================================
# MANAGEMENT LOOP  (The Hivemind — expiry + data-quota watchdog)
# ==============================================================================
def management_loop():
    print(f"[HIVEMIND] Started. Tick every {CHECK_INTERVAL_SECONDS}s.")
    init_wireguard()

    while True:
        try:
            stats = get_wireguard_stats()
            now   = time.time()

            with sessions_lock:
                expired_devices = []

                for device_id, session in list(active_sessions.items()):
                    ip = session["ip"]

                    # ── 1. Check expiry ───────────────────────────────────────
                    if now > session["expires_at"]:
                        print(f"[HIVEMIND] Session expired for {device_id} ({ip}). Removing peer.")
                        if session["is_throttled"]:
                            remove_throttle(ip)
                        remove_wg_peer(session["pubkey"])
                        release_ip(ip)
                        expired_devices.append(device_id)
                        continue

                    # ── 2. Check data quota ───────────────────────────────────
                    if ip in stats:
                        used_bytes = stats[ip]["total_bytes"] - session["baseline_bytes"]

                        if used_bytes > session["quota_bytes"] and not session["is_throttled"]:
                            print(f"[HIVEMIND] Data cap reached for {ip} ({used_bytes/1e9:.2f} GB used). Throttling.")
                            apply_throttle(ip)
                            session["is_throttled"] = True

                for device_id in expired_devices:
                    del active_sessions[device_id]

        except Exception as e:
            print(f"[HIVEMIND] Unhandled error: {e}")

        time.sleep(CHECK_INTERVAL_SECONDS)


# ==============================================================================
# LOW-LEVEL PLUMBING  (awg, tc, IP pool, peer management)
# ==============================================================================

def run_cmd(cmd, ignore_errors=False):
    """Executes a shell command directly on the host (no Docker middleman)."""
    # All commands run directly on the host against awg0.
    # The only sudo requirement is for awg/tc/iptables — already handled via
    # the hivemind systemd unit running as root or via sudoers rules.

    args = shlex.split(cmd)
    try:
        result = subprocess.run(
            args, shell=False, check=not ignore_errors,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        if not ignore_errors:
            print(f"[CMD FAIL] {cmd}\n  stderr: {e.stderr.strip()}")
        return None


def init_wireguard():
    """Initialises traffic control and fetches the server's public key."""
    global SERVER_PUBKEY
    print(f"[TC] Initialising traffic control on {WG_INTERFACE}...")
    run_cmd(f"tc qdisc del dev {WG_INTERFACE} root", ignore_errors=True)
    run_cmd(f"tc qdisc add dev {WG_INTERFACE} root handle 1: htb default 999")
    print("[TC] Root qdisc ready.")

    print(f"[IP] Expanding routing table for /16 subnet...")
    run_cmd(f"ip route add 10.8.0.0/16 dev {WG_INTERFACE}", ignore_errors=True)
    
    print(f"[NAT] Applying masquerade for /16 subnet...")
    run_cmd(f"iptables -t nat -A POSTROUTING -s 10.8.0.0/16 -j MASQUERADE", ignore_errors=True)

    print(f"[IP] Adding IPv6 route for fd42::/80...")
    run_cmd(f"ip -6 route add fd42::/80 dev {WG_INTERFACE}", ignore_errors=True)

    print(f"[NAT] Applying IPv6 masquerade for fd42::/80...")
    run_cmd(f"ip6tables -t nat -A POSTROUTING -s fd42::/80 -j MASQUERADE", ignore_errors=True)

    # The phone connects to awg0 on port 4433.
    pubkey = run_cmd("awg show awg0 public-key")
    if pubkey:
        SERVER_PUBKEY = pubkey
        print(f"[AWG] Server Public Key cached from awg0: {SERVER_PUBKEY}")
    else:
        print("[AWG] WARNING: Could not fetch awg0 public key! Check that awg is installed on host.")


def _class_id(ip):
    # Combine 3rd and 4th octet for uniqueness across /16
    # e.g. "10.8.3.5" -> "773" (3*256+5), avoids collisions
    parts = ip.split('.')
    return str(int(parts[2]) * 256 + int(parts[3]))


def apply_throttle(ip):
    cid = _class_id(ip)
    print(f"[TC] Throttling {ip} -> class 1:{cid} @ {THROTTLE_RATE}")
    run_cmd(f"tc class add dev {WG_INTERFACE} parent 1: classid 1:{cid} htb rate {THROTTLE_RATE}")
    run_cmd(f"tc filter add dev {WG_INTERFACE} protocol ip parent 1:0 prio 1 u32 match ip dst {ip}/32 flowid 1:{cid}")


def remove_throttle(ip):
    cid = _class_id(ip)
    print(f"[TC] Removing throttle from {ip} (class 1:{cid})")
    run_cmd(f"tc class del dev {WG_INTERFACE} classid 1:{cid}", ignore_errors=True)


def get_wireguard_stats():
    """Returns { "10.8.X.Y": {"pubkey": "...", "total_bytes": 1234}, ... }
    Reads directly from the host's awg0 interface.
    Uses two separate commands to avoid AmneziaWG dump column-layout differences.
    """
    # Step 1: pubkey -> (rx_bytes, tx_bytes)
    transfer_out = run_cmd("awg show awg0 transfer")
    # Step 2: pubkey -> ip/32
    allowed_out  = run_cmd("awg show awg0 allowed-ips")

    if not transfer_out or not allowed_out:
        return {}

    # Build pubkey -> IP map from allowed-ips
    pubkey_to_ip = {}
    for line in allowed_out.splitlines():
        parts = line.split('\t')
        if len(parts) >= 2:
            pubkey_to_ip[parts[0]] = parts[1].split('/')[0]

    # Build IP -> stats from transfer bytes
    stats = {}
    for line in transfer_out.splitlines():
        parts = line.split('\t')
        if len(parts) >= 3:
            pubkey = parts[0]
            ip     = pubkey_to_ip.get(pubkey)
            if ip:
                stats[ip] = {
                    "pubkey":      pubkey,
                    "total_bytes": int(parts[1]) + int(parts[2])
                }
    return stats


def ipv4_to_ipv6(ipv4):
    """Map 10.8.X.Y → fd42::X:Y (ULA for internal VPN routing, no NAT64 needed)."""
    parts = ipv4.split('.')
    return f"fd42::{parts[2]}:{parts[3]}"


def allocate_ip():
    """Pops an available IP from the pre-generated pool."""
    if not AVAILABLE_IPS:
        return None
    return AVAILABLE_IPS.pop()

def release_ip(ip):
    """Returns an IP back to the available pool."""
    if ip:
        AVAILABLE_IPS.add(ip)

def add_wg_peer(pubkey, ipv4, ipv6):
    """Dynamically adds an ephemeral dual-stack peer to AmneziaWG."""
    # Remove it first just in case it exists to avoid conflicts
    run_cmd(f"awg set awg0 peer {pubkey} remove", ignore_errors=True)
    res = run_cmd(f"awg set awg0 peer {pubkey} allowed-ips {ipv4}/32,{ipv6}/128")
    time.sleep(0.2)  # Let AmneziaWG register the peer before baseline snapshot
    if res is not None:
        print(f"[AWG] Ephemeral peer added: {pubkey[:8]}... -> {ipv4} / {ipv6}")


def remove_wg_peer(pubkey):
    """Removes an ephemeral peer from AmneziaWG."""
    if pubkey:
        run_cmd(f"awg set awg0 peer {pubkey} remove", ignore_errors=True)
        print(f"[AWG] Ephemeral peer removed: {pubkey[:8]}...")


# ==============================================================================
# ENTRY POINT
# ==============================================================================
# Start management daemon at module load (gunicorn-safe, runs once per process)
_daemon_thread = threading.Thread(target=management_loop, daemon=True)
_daemon_thread.start()

if __name__ == '__main__':
    # When running directly with Flask, the before_request hook handles it
    app.run(host='0.0.0.0', port=5000)
