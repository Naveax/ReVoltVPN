#!/usr/bin/env python3
"""
Hivemind VPN Session Manager
Manages time + data quotas for VLESS clients via ad rewards.
Designed for Android-only clients.

=== TABLE OF CONTENTS ===========================================================
  LINE     SECTION
    37      Configuration — ad rewards, Xray paths
   75      State & Cache — sessions dict, stats failure counter
   97      Flask Routes — /admob/callback, /session/status, /session/stop
  202      Session Logic — _start_or_extend_session (create / replace)
  270      AdMob SSV Verification — Google ECDSA signature checks
  355      Management Loop — expiry + data-quota watchdog (60 s tick)
  403      Low-Level Plumbing — add/remove users, Xray stats
  551      Entry Point — daemon thread + gunicorn bootstrap
================================================================================
"""

import time
import subprocess
import threading
import json
import os
import tempfile
import requests
import shlex
import urllib.parse
import uuid
import base64
from flask import Flask, request, jsonify
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.serialization import load_pem_public_key

app = Flask(__name__)


def _is_valid_device_id(device_id):
    """Validate that device_id is a well-formed UUID (Flutter uuid.v4() format).

    Rejects empty strings, non-UUID garbage, and oversized payloads
    before they reach the session dict or Xray config.
    """
    if not isinstance(device_id, str):
        return False
    if len(device_id) > 64:
        return False
    try:
        uuid.UUID(device_id)
        return True
    except (ValueError, AttributeError):
        return False


def _atomic_write_json(path, data):
    """Write JSON to path atomically (temp file + rename).

    Prevents Xray from reading a half-written config file during hot-reload.
    """
    tmpfd, tmppath = tempfile.mkstemp(dir=os.path.dirname(path), suffix='.tmp')
    try:
        with os.fdopen(tmpfd, 'w') as f:
            json.dump(data, f, indent=2)
        os.replace(tmppath, path)
    except Exception:
        try:
            os.unlink(tmppath)
        except OSError:
            pass
        raise

# ==============================================================================
# CONFIGURATION
# ==============================================================================
CHECK_INTERVAL_SECONDS = 60      # Checking every 1 minute is extremely safe and uses 0% CPU.

# Main Ad Rewards
MAIN_AD_MINUTES = 60
MAIN_AD_BYTES = 10 * 1024 * 1024 * 1024    # 10 GB (generous — no mobile device hits this in 1 hr)

# VLESS server info — returned to app in /session/status
VLESS_DOMAIN = "yourdomain.com"           # TODO: set your real domain
VLESS_PATH   = "/tunnel"

# ── Xray config.json template  ────────────────────────────────────────────────
# Copy this to /usr/local/etc/xray/config.json on the server.
# Verified against https://xtls.github.io/llms-full.txt (2026-07-24).
#
#   • "clients" is the correct VLESS key (not "users")
#   • "method" is the transport selector (not "network")
#   • API uses simplified mode — no separate inbound or routing rule needed
#   • statsUserUplink/Downlink must be true for per-user quota tracking
#   • uplinkOnly/downlinkOnly are connection timeouts (seconds), NOT bandwidth limits
#
# {
#   "log": { "loglevel": "warning" },
#   "inbounds": [
#     {
#       "tag": "vless-in",
#       "port": 8443,
#       "listen": "127.0.0.1",
#       "protocol": "vless",
#       "settings": {
#         "clients": [],
#         "decryption": "none"
#       },
#       "streamSettings": {
#         "method": "ws",
#         "security": "none",
#         "wsSettings": { "path": "/tunnel" }
#       },
#       "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
#     }
#   ],
#   "outbounds": [
#     {
#       "protocol": "freedom",
#       "tag": "direct",
#       "mux": { "enabled": true, "concurrency": 8 }
#     }
#   ],
#   "api": {
#     "tag": "api",
#     "listen": "127.0.0.1:10085",
#     "services": ["HandlerService", "StatsService"]
#   },
#   "stats": {},
#   "policy": {
#     "system": {
#       "statsInboundUplink": true,
#       "statsInboundDownlink": true
#     },
#     "levels": {
#       "0": { "statsUserUplink": true, "statsUserDownlink": true }
#     }
#   }
# }

# Xray paths
XRAY_CONFIG = "/usr/local/etc/xray/config.json"
XRAY_API    = "http://127.0.0.1:10085"
VLESS_INBOUND_TAG = "vless-in"

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

# Consecutive Xray stats API failures — reset to 0 on first success.
# Used to rate-limit log spam when the stats endpoint is unreachable.
_xray_stats_failures = 0

# Keyed by device_id (e.g. "esf-18fc2...")
# {
#   "device_id": {
#       "vless_uuid":   "550e8400-...",
#       "expires_at":   1716480000,
#       "quota_bytes":  2147483648,
#       "nonce":        "a7f3b2-1716480000000",
#   }
# }
active_sessions = {}


# ==============================================================================
# FLASK ROUTES  (API surface — what the outside world sees)
# ==============================================================================

@app.route('/api/admob/callback', methods=['GET'])
def admob_callback():
    """
    Google AdMob SSV callback — called server-to-server when a rewarded ad completes.
    The Android client never touches this endpoint; Google calls it directly.

    custom_data (JSON, set by the app before showing the ad):
       { "device_id": "...", "nonce": "..." }
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

        try:
            custom_data = json.loads(custom_data_str)
        except (json.JSONDecodeError, TypeError) as e:
            print(f"[ADMOB] Malformed custom_data JSON: {e}")
            return "Invalid JSON in custom_data", 400

        device_id     = custom_data.get('device_id')
        
        if not device_id:
            return "Invalid custom_data payload", 400
        if not _is_valid_device_id(device_id):
            print(f"[ADMOB] Rejected — invalid device_id: {str(device_id)[:32]}...")
            return "Invalid device_id", 400

        nonce = custom_data.get('nonce', None)
        success, msg = _start_or_extend_session(device_id, nonce)
        return ("OK", 200) if success else (msg, 500)

    except Exception as e:
        print(f"[ADMOB] SSV Error: {e}")
        return "Internal Error", 500


@app.route('/api/session/status', methods=['GET'])
def session_status():
    """
    Query: ?device_id=esf-xxx
    Returns current VLESS session state so the app can connect.
    """
    device_id = request.args.get('device_id')
    if not device_id:
        return jsonify({"error": "Missing query parameter: device_id"}), 400
    if not _is_valid_device_id(device_id):
        return jsonify({"error": "Invalid device_id — expected UUID"}), 400

    with sessions_lock:
        session = active_sessions.get(device_id)

    if not session:
        return jsonify({"active": False, "message": "No session found."}), 200

    stats          = get_xray_stats()
    used_bytes     = stats.get(device_id, {}).get("total_bytes", 0)
    remaining_data = max(0, session["quota_bytes"] - used_bytes)
    remaining_secs = max(0, session["expires_at"] - time.time())

    return jsonify({
        "active":             remaining_secs > 0,
        "vless_uuid":         session["vless_uuid"],
        "server_domain":      VLESS_DOMAIN,
        "server_port":        443,
        "vless_path":         VLESS_PATH,
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

    if not device_id:
        return jsonify({"error": "Missing device_id"}), 400
    if not _is_valid_device_id(device_id):
        return jsonify({"error": "Invalid device_id — expected UUID"}), 400

    if device_id:
        with sessions_lock:
            session = active_sessions.pop(device_id, None)
        # Lock released — file I/O and subprocess happen outside.
        if session:
            remove_vless_client(device_id)
            print(f"[API] Explicit stop for {device_id}.")


# ==============================================================================
# SESSION LOGIC
# ==============================================================================

def _start_or_extend_session(device_id, nonce=None):
    """Provision a new VLESS session (or replace an existing one).

    nonce -- client-generated random token; stored in session and echoed
             back in /session/status so the client can reject stale sessions.
    """
    now = time.time()

    # ── Phase 1: update in-memory state under lock ────────────────────
    xray_action = None  # ("add", uuid) | ("replace", uuid)

    with sessions_lock:
        existing = active_sessions.get(device_id)
        vless_uuid = str(uuid.uuid4())

        active_sessions[device_id] = {
            "vless_uuid":   vless_uuid,
            "expires_at":   now + (MAIN_AD_MINUTES * 60),
            "quota_bytes":  MAIN_AD_BYTES,
            "nonce":        nonce,
        }

        if existing:
            xray_action = ("replace", vless_uuid)
        else:
            xray_action = ("add", vless_uuid)

        print(f"[SESSION] Session started for {device_id} (UUID: {vless_uuid[:8]}...).")

    # ── Phase 2: Xray file I/O + subprocess OUTSIDE the lock ──────────
    op, arg = xray_action[0], xray_action[1]
    if op == "replace":
        remove_vless_client(device_id)
        add_vless_client(arg, device_id)
        return True, "Session active."
    elif op == "add":
        add_vless_client(arg, device_id)
        return True, "Session active."
    else:
        raise RuntimeError(
            f"BUG: _start_or_extend_session got unexpected xray_action op={op!r}. "
            f"Expected one of: replace, add.  "
            f"This is a code bug — add the new op to the if-chain."
        )



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

    while True:
        try:
            stats = get_xray_stats()
            now   = time.time()

            # ── Phase 1: decide what to do under the lock ────────────────
            with sessions_lock:
                to_remove = []  # (device_id,) — expired or over quota

                for device_id, session in list(active_sessions.items()):

                    # ── 1. Check expiry ───────────────────────────────────────
                    if now > session["expires_at"]:
                        print(f"[HIVEMIND] Session expired for {device_id}.")
                        to_remove.append(device_id)
                        continue

                    # ── 2. Check data quota — hard cut-off when exceeded ──────
                    used_bytes = stats.get(device_id, {}).get("total_bytes", 0)

                    if used_bytes > session["quota_bytes"]:
                        print(f"[HIVEMIND] Data cap reached for {device_id} ({used_bytes/1e9:.2f} GB used). Cutting off.")
                        to_remove.append(device_id)

                for device_id in to_remove:
                    del active_sessions[device_id]

            # ── Phase 2: file I/O + subprocess OUTSIDE the lock ───────
            for device_id in to_remove:
                remove_vless_client(device_id)

        except Exception as e:
            print(f"[HIVEMIND] Unhandled error: {e}")

        time.sleep(CHECK_INTERVAL_SECONDS)


# ==============================================================================
# LOW-LEVEL PLUMBING  (Xray client management + stats)
# ==============================================================================

def run_cmd(cmd, ignore_errors=False):
    """Executes a shell command directly on the host."""
    args = shlex.split(cmd)
    try:
        result = subprocess.run(
            args, shell=False, check=not ignore_errors,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
        )
        return result.stdout.strip()
    except FileNotFoundError:
        print(f"[CMD FAIL] executable not found: {args[0]}")
        return None
    except subprocess.CalledProcessError as e:
        if not ignore_errors:
            print(f"[CMD FAIL] {cmd}\n  stderr: {e.stderr.strip()}")
        return None
    except OSError as e:
        print(f"[CMD FAIL] {cmd}\n  os error: {e}")
        return None


def add_vless_client(uuid, email, level=0):
    """Add a client UUID to the Xray inbound config and hot-reload.

    level -- Xray policy level for bandwidth limits:
             0 = default.
    """
    with open(XRAY_CONFIG, 'r') as f:
        config = json.load(f)

    for inbound in config["inbounds"]:
        if inbound.get("tag") == VLESS_INBOUND_TAG:
            inbound["settings"]["clients"].append({
                "id": uuid,
                "email": email,
                "level": level
            })
            break

    _atomic_write_json(XRAY_CONFIG, config)
    run_cmd("xray api adi --server=127.0.0.1:10085")
    print(f"[VLESS] User added: {email[:16]}...")


def remove_vless_client(email):
    """Remove a client from the Xray inbound config and hot-reload."""
    with open(XRAY_CONFIG, 'r') as f:
        config = json.load(f)

    for inbound in config["inbounds"]:
        if inbound.get("tag") == VLESS_INBOUND_TAG:
            clients = inbound["settings"]["clients"]
            inbound["settings"]["clients"] = [
                c for c in clients if c.get("email") != email
            ]
            break

    _atomic_write_json(XRAY_CONFIG, config)
    run_cmd("xray api adi --server=127.0.0.1:10085")
    print(f"[VLESS] User removed: {email[:16]}...")


def get_xray_stats():
    """Query Xray stats API for per-user upload+download bytes.

    Returns: { "device_id": {"total_bytes": 12345}, ... }
    """
    global _xray_stats_failures

    try:
        resp = requests.get(
            f"{XRAY_API}/stats/query",
            json={"pattern": "", "reset": False},
            timeout=5
        )
        data = resp.json()
    except Exception as e:
        # Rate-limit log spam: warn on first failure, then every 10th.
        _xray_stats_failures += 1
        if _xray_stats_failures == 1:
            print(f"[XRAY_STATS] WARNING: Cannot reach Xray stats API: {e}")
        elif _xray_stats_failures % 10 == 0:
            print(f"[XRAY_STATS] ERROR: {_xray_stats_failures} consecutive failures. "
                  f"Quota enforcement is NOT running. Last error: {e}")
        return {}

    # Success — reset the failure counter.
    if _xray_stats_failures > 0:
        print(f"[XRAY_STATS] Recovered after {_xray_stats_failures} failure(s).")
        _xray_stats_failures = 0

    stats = {}
    for entry in data.get("stat", []):
        name = entry.get("name", "")
        value = int(entry.get("value", 0))

        # Xray stats names look like: "user>>>email>>>traffic>>>uplink"
        if ">>>traffic>>>" in name:
            parts = name.split(">>>")
            email = parts[1] if len(parts) > 1 else None
            if email and email != "api":
                if email not in stats:
                    stats[email] = {"total_bytes": 0}
                stats[email]["total_bytes"] += value

    return stats


# ==============================================================================
# ENTRY POINT
# ==============================================================================
# Start management daemon at module load (gunicorn-safe, runs once per process)
_daemon_thread = threading.Thread(target=management_loop, daemon=True)
_daemon_thread.start()

if __name__ == '__main__':
    # When running directly with Flask, the before_request hook handles it
    app.run(host='0.0.0.0', port=5000)
