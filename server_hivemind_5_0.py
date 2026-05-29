#!/usr/bin/env python3
"""
Hivemind VPN Session Manager
Manages time + data quotas for WireGuard peers via ad rewards.
Designed for Android-only clients.
"""

import time
import subprocess
import threading
import json
import requests
import shlex
import re
import urllib.parse
from flask import Flask, request, jsonify
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.serialization import load_der_public_key, load_pem_public_key
import base64

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
WG_INTERFACE = "wg0"

# Main Ad Rewards
MAIN_AD_MINUTES = 60
MAIN_AD_BYTES = 2 * 1024 * 1024 * 1024     # 2 GB

# Bonus Ad Rewards
BONUS_AD_MINUTES = 30
BONUS_AD_BYTES = 1 * 1024 * 1024 * 1024    # 1 GB

THROTTLE_RATE = "1.5mbit"

# ==============================================================================
# STATE & CACHE
# ==============================================================================
sessions_lock = threading.Lock()
# Paste your Server Public Key here if Docker dynamic fetching keeps failing
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
#       "is_throttled":   False
#   }
# }
active_sessions = {}

# Simple IP pool allocation (100 to 250)
IP_POOL_START = 100
IP_POOL_END = 250


# ==============================================================================
# SYSTEM COMMAND HELPERS
# ==============================================================================
def run_cmd(cmd, ignore_errors=False):
    """Executes a shell command safely without shell=True."""
    if cmd.startswith("wg ") or cmd.startswith("tc ") or cmd.startswith("ip ") or cmd.startswith("iptables "):
        cmd = f"sudo docker exec wg-easy {cmd}"

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

    pubkey = run_cmd(f"wg show {WG_INTERFACE} public-key")
    if pubkey:
        SERVER_PUBKEY = pubkey
        print(f"[WG] Server Public Key cached: {SERVER_PUBKEY}")
    else:
        print("[WG] WARNING: Could not fetch Server Public Key!")


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
    """Returns { "10.8.0.2": {"pubkey": "...", "total_bytes": 1234}, ... }"""
    output = run_cmd(f"wg show {WG_INTERFACE} dump")
    if not output:
        return {}

    stats = {}
    lines = output.splitlines()[1:]
    for line in lines:
        parts = line.split('\t')
        if len(parts) >= 8:
            pubkey      = parts[0]
            allowed_ips = parts[3].split('/')[0]
            rx          = int(parts[5])
            tx          = int(parts[6])
            stats[allowed_ips] = {
                "pubkey":      pubkey,
                "total_bytes": rx + tx
            }
    return stats


import ipaddress

# ==============================================================================
# IP POOL MANAGEMENT
# ==============================================================================
# The server subnet is 10.8.0.0/16, giving ~65,530 IPs for public use.
#60 THOUSAND OR 64 THOUSAND ARGUEMENT GOES HERE
AVAILABLE_IPS = {str(ip) for ip in ipaddress.IPv4Network('10.8.0.0/16').hosts()}
AVAILABLE_IPS.discard('10.8.0.1')

# We need a fallback if we somehow exhaust them, though unlikely
def allocate_ip():
    """Pops an available IP from the pre-generated pool."""
    if not AVAILABLE_IPS:
        return None
    return AVAILABLE_IPS.pop()

def release_ip(ip):
    """Returns an IP back to the available pool."""
    if ip:
        AVAILABLE_IPS.add(ip)

def add_wg_peer(pubkey, ip):
    """Dynamically adds an ephemeral peer to WireGuard."""
    # Remove it first just in case it exists to avoid conflicts
    run_cmd(f"wg set {WG_INTERFACE} peer {pubkey} remove", ignore_errors=True)
    run_cmd(f"awg set awg0 peer {pubkey} remove", ignore_errors=True)
    res = run_cmd(f"wg set {WG_INTERFACE} peer {pubkey} allowed-ips {ip}/32")
    run_cmd(f"awg set awg0 peer {pubkey} allowed-ips {ip}/32")
    if res is not None:
        print(f"[WG] Ephemeral peer added: {pubkey[:8]}... -> {ip}")


def remove_wg_peer(pubkey):
    """Removes an ephemeral peer from WireGuard."""
    if pubkey:
        run_cmd(f"wg set {WG_INTERFACE} peer {pubkey} remove", ignore_errors=True)
        run_cmd(f"awg set awg0 peer {pubkey} remove", ignore_errors=True)
        print(f"[WG] Ephemeral peer removed: {pubkey[:8]}...")


# ==============================================================================
# BACKGROUND MANAGEMENT LOOP  (The Hivemind)
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
# SESSION LOGIC
# ==============================================================================
def _start_or_extend_session(device_id, client_pubkey, ad_type):
    """Core logic to provision or extend a session."""
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
            
            ip = allocate_ip()
            if not ip:
                return False, "Server full! No available IP addresses."
            
            add_wg_peer(client_pubkey, ip)
            
            # Fetch immediate stats to set baseline
            # (Though brand new peers usually start at 0)
            stats = get_wireguard_stats()
            current_bytes = stats.get(ip, {}).get("total_bytes", 0)

            active_sessions[device_id] = {
                "ip":             ip,
                "pubkey":         client_pubkey,
                "expires_at":     now + (MAIN_AD_MINUTES * 60),
                "quota_bytes":    MAIN_AD_BYTES,
                "baseline_bytes": current_bytes,
                "is_throttled":   False,
            }
            print(f"[SESSION] Main session started for {device_id} (IP: {ip}).")
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
        # 1. Rebuild the signed message: all params except signature & key_id
        params   = urllib.parse.parse_qsl(raw_query_string, keep_blank_values=True)
        filtered = [(k, v) for k, v in params if k not in ("signature", "key_id")]
        message  = urllib.parse.urlencode(filtered).encode("utf-8")

        # 2. Base64url-decode the signature (add missing padding if needed)
        padding   = 4 - len(signature_b64url) % 4
        sig_bytes = base64.urlsafe_b64decode(signature_b64url + ("=" * (padding % 4)))

        # 3. Fetch the matching public key
        pub_key = _get_admob_public_key(key_id)
        if pub_key is None:
            print(f"[ADMOB] Unknown key_id: {key_id}. Rejecting.")
            return False

        # 4. Verify — raises InvalidSignature on failure
        pub_key.verify(sig_bytes, message, ec.ECDSA(hashes.SHA256()))
        return True

    except Exception as e:
        print(f"[ADMOB] Signature verification failed: {e}")
        return False


@app.route('/api/admob/callback', methods=['GET'])
def admob_callback():
    """
    Google AdMob SSV callback — called server-to-server when a rewarded ad completes.
    The Android client never touches this endpoint; Google calls it directly.

    custom_data (JSON, set by the app before showing the ad):
      { "device_id": "...", "public_key": "...", "ad_type": "main_ad"|"bonus_ad" }
    """
    try:
        signature       = request.args.get('signature')
        key_id          = request.args.get('key_id')
        custom_data_str = request.args.get('custom_data')

        # Google sends a verification ping with signature+key_id but no custom_data
        if not custom_data_str:
            return "OK", 200  # Verification ping from Google dashboard

        if not all([signature, key_id]):
            return "Missing parameters", 400

        # ⚠️ TEMP: Signature verification disabled for Play Store submission testing
        # TODO: Uncomment before going live with real ad traffic
        # raw_qs = request.query_string.decode("utf-8")
        # if not _verify_admob_signature(raw_qs, signature, key_id):
        #     print("[ADMOB] Rejected callback — invalid signature.")
        #     return "Forbidden", 403

        custom_data   = json.loads(custom_data_str)
        device_id     = custom_data.get('device_id')
        client_pubkey = custom_data.get('public_key')
        
        with sessions_lock:
            ad_type = 'bonus_ad' if device_id in active_sessions else 'main_ad'

        if not device_id or not client_pubkey:
            return "Invalid custom_data payload", 400

        success, msg = _start_or_extend_session(device_id, client_pubkey, ad_type)
        return ("OK", 200) if success else (msg, 500)

    except Exception as e:
        print(f"[ADMOB] SSV Error: {e}")
        return "Internal Error", 500


# ==============================================================================
# FLASK API (APP POLLING)
# ==============================================================================

@app.route('/api/session/status', methods=['GET'])
def session_status():
    """
    Query: ?device_id=esf-xxx
    Returns current session state so the Android app can construct its WireGuard config.
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
        pubkey = run_cmd(f"wg show {WG_INTERFACE} public-key")
        if pubkey:
            SERVER_PUBKEY = pubkey
            print(f"[WG] Dynamic Server Public Key cached: {SERVER_PUBKEY}")
        else:
            # Absolute fallback if docker exec is broken on this host
            SERVER_PUBKEY = SERVER_PUBKEY_FALLBACK or "YOUR_SERVER_PUBLIC_KEY_HERE"

    stats          = get_wireguard_stats()
    current_bytes  = stats.get(session["ip"], {}).get("total_bytes", 0)
    used_bytes     = max(0, current_bytes - session["baseline_bytes"])
    remaining_data = max(0, session["quota_bytes"] - used_bytes)
    remaining_secs = max(0, session["expires_at"] - time.time())

    return jsonify({
        "active":             remaining_secs > 0,
        "client_ip":          session["ip"],
        "server_pubkey":      SERVER_PUBKEY,
        "is_throttled":       session["is_throttled"],
        "expires_in_seconds": int(remaining_secs),
        "quota_bytes":        session["quota_bytes"],
        "used_bytes":         used_bytes,
        "remaining_bytes":    remaining_data,
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
# ENTRY POINT
# ==============================================================================
# Start background thread before first request (for Gunicorn compatibility)
@app.before_request
def _start_daemon():
    if not hasattr(app, '_daemon_started'):
        app._daemon_started = True
        daemon = threading.Thread(target=management_loop, daemon=True)
        daemon.start()

if __name__ == '__main__':
    # When running directly with Flask, the before_request hook handles it
    app.run(host='0.0.0.0', port=5000)
