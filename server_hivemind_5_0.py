#!/usr/bin/env python3
"""
Hivemind VPN Session Manager
Manages VLESS Reality sessions via ad rewards — 60 min, throttle at 4 GB.
Designed for Android-only clients.

=== TABLE OF CONTENTS ===========================================================
   Configuration — ad rewards, Reality constants, Xray paths
   State & Cache — sessions dict, stats failure counter
   Flask Routes — /admob/callback, /session/status, /session/stop
   Session Logic — _start_or_extend_session, _extend_session
   AdMob SSV Verification — Google ECDSA signature checks
   Management Loop — expiry + throttle watchdog (60 s tick)
   Low-Level Plumbing — add/remove users, Xray stats
   Entry Point — daemon thread + gunicorn bootstrap
================================================================================
"""

import time
import subprocess
import threading
import json
import os
import random
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


# ── Stdout passthrough ──────────────────────────────────────────────────
# Ensures print() works inside gunicorn workers by forwarding to the real
# stdout.  (The log buffer + /api/log endpoint were removed — monitoring
# now lives on a separate internal-only server.)
import sys

class _TeeStdout:
    def __init__(self, original):
        self.original = original
    def write(self, s):
        self.original.write(s)
        self.original.flush()
    def flush(self):
        self.original.flush()

sys.stdout = _TeeStdout(sys.stdout)


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

# Support Ad Rewards (top-up)
SUPPORT_AD_MINUTES = 30

REALITY_SNI_POOL = [
    "www.microsoft.com",
    "www.cloudflare.com",
    "www.google.com",
    "www.amazon.com",
    "www.yandex.ru",
]
VLESS_SERVER_IP     = "204.168.246.88"
VLESS_REALITY_PORT  = 8443
REALITY_PUBLIC_KEY  = "GENERATE_ME_WITH_xray_x25519"
REALITY_SHORT_ID    = "abc123"

# ── Persistent swarm total (survives restarts) ──────────────────────────
SWARM_TOTAL_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "swarm_total.json")
_persistent_total_gb = 0.0
REALITY_FINGERPRINT = "chrome"

# ── Xray paths ───────────────────────────────────────────────────────────
XRAY_CONFIG = "/usr/local/etc/xray/config.json"
XRAY_API    = "http://127.0.0.1:10085"
VLESS_REALITY_TAG           = "vless-reality"
VLESS_REALITY_THROTTLED_TAG = "vless-reality-throttled"

THROTTLE_BYTES = 4 * 1024 * 1024 * 1024   # 4 GB

# AdMob SSV verification toggle
#   True  = dev mode, accept any callback (no signature check)
#   False = prod mode, enforce Google ECDSA signature verification
#
# ⚠️  Set to False AFTER Google Play verifies your AdMob implementation is
#     working correctly with real rewarded ads.  Until then, keep True so
#     the debug fake-callback path in the Flutter app still functions.
ADMOB_BYPASS = True

def _load_persistent_total():
    """Read the running total GB from disk.  Returns 0.0 if file missing/corrupt."""
    try:
        with open(SWARM_TOTAL_FILE, 'r') as f:
            data = json.load(f)
            return float(data.get("total_gb", 0.0))
    except Exception:
        return 0.0


def _save_persistent_total():
    """Write the running total GB to disk atomically."""
    _atomic_write_json(SWARM_TOTAL_FILE, {"total_gb": _persistent_total_gb})


# Load at module init — survives Hivemind restarts.
_persistent_total_gb = _load_persistent_total()


# ==============================================================================
# STATE & CACHE
# ==============================================================================
sessions_lock = threading.Lock()

# Consecutive Xray stats API failures — reset to 0 on first success.
# Used to rate-limit log spam when the stats endpoint is unreachable.
_xray_stats_failures = 0

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

        nonce   = custom_data.get('nonce', None)
        ad_type = custom_data.get('ad_type', 'main')

        if ad_type == 'support':
            success, msg = _extend_session(device_id, nonce)
        else:
            success, msg = _start_or_extend_session(device_id, nonce)
        return ("OK", 200) if success else (msg, 500)

    except Exception as e:
        print(f"[ADMOB] SSV Error: {e}")
        return "Internal Error", 500


@app.route('/api/health')
def health():
    return jsonify({"ok": True})


# ── Swarm / log endpoints REMOVED (2026-07-29) ──────────────────────────
# These exposed internal monitoring on the same domain as the public API.
# Moved to a separate internal-only server.  See backups/swarm_watch.py.
#
# @app.route('/api/swarm')
# def swarm_status():
#     return jsonify(get_swarm_status())
#
# @app.route('/api/log')
# def log_tail():
#     return jsonify(list(_log_buffer))


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
    remaining_secs = max(0, session["expires_at"] - time.time())

    return jsonify({
        "active":             remaining_secs > 0,
        "vless_uuid":         session["vless_uuid"],
        "vless_ip":           VLESS_SERVER_IP,
        # NOTE: assumes throttled port = normal port + 1. If you change the
        # throttled port in xray_config_reality.json, update this logic too.
        "vless_port":         VLESS_REALITY_PORT + 1 if session.get("throttled") else VLESS_REALITY_PORT,
        "reality_pbk":        REALITY_PUBLIC_KEY,
        "reality_sid":        REALITY_SHORT_ID,
        "reality_sni":        session.get("_sni", REALITY_SNI_POOL[0]),
        "reality_fp":         REALITY_FINGERPRINT,
        "expires_in_seconds": int(remaining_secs),
        "used_bytes":         used_bytes,
        "nonce":              session.get("nonce", ""),
        "is_throttled":       session.get("throttled", False),
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
            # Add final bytes to persistent odometer.
            stats = get_xray_stats()
            used = stats.get(device_id, {}).get("total_bytes", 0)
            if used > 0:
                global _persistent_total_gb
                _persistent_total_gb += used / 1_000_000_000
                _save_persistent_total()
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

        # Pick a random SNI for this session so every user looks
        # like they're connecting to a different real website.
        sni = random.choice(REALITY_SNI_POOL)

        active_sessions[device_id] = {
            "vless_uuid":   vless_uuid,
            "expires_at":   now + (MAIN_AD_MINUTES * 60),
            "nonce":        nonce,
            "throttled":    False,
            "_created_at":  now,
            "_prev_bytes":  0,
            "_sni":         sni,
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
        add_vless_client(arg, device_id, inbound_tag=VLESS_REALITY_TAG)
        return True, "Session active."
    elif op == "add":
        add_vless_client(arg, device_id, inbound_tag=VLESS_REALITY_TAG)
        return True, "Session active."
    else:
        raise RuntimeError(
            f"BUG: _start_or_extend_session got unexpected xray_action op={op!r}. "
            f"Expected one of: replace, add.  "
            f"This is a code bug — add the new op to the if-chain."
        )


def _extend_session(device_id, nonce=None):
    """Top-up an EXISTING session — adds time without replacing the UUID.

    Used by the 'Support us' rewarded ad.  Does NOT touch the throttle state
    or move the user between inbounds.
    """
    with sessions_lock:
        session = active_sessions.get(device_id)
        if not session:
            print(f"[SESSION] Extend failed — no active session for {device_id}.")
            return False, "No active session to extend"

        session["expires_at"]  += SUPPORT_AD_MINUTES * 60
        session["nonce"]        = nonce

        print(f"[SESSION] Extended for {device_id}: +{SUPPORT_AD_MINUTES} min")

    return True, "Session extended"


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
# MANAGEMENT LOOP  (The Hivemind — expiry + throttle watchdog)
# ==============================================================================
def management_loop():
    global _persistent_total_gb
    print(f"[HIVEMIND] Started. Tick every {CHECK_INTERVAL_SECONDS}s.")

    while True:
        try:
            stats = get_xray_stats()
            now   = time.time()

            with sessions_lock:
                to_remove            = []
                to_throttle_add      = []
                to_throttle_cleanup  = []

                for device_id, session in list(active_sessions.items()):

                    if now > session["expires_at"]:
                        print(f"[HIVEMIND] Session expired for {device_id}.")
                        to_remove.append(device_id)
                        continue

                    used_bytes = stats.get(device_id, {}).get("total_bytes", 0)
                    session["_prev_bytes"] = used_bytes

                    just_throttled = False
                    if used_bytes > THROTTLE_BYTES and not session.get("throttled", False):
                        print(f"[HIVEMIND] Throttling {device_id} ({used_bytes/1e9:.2f} GB used).")
                        session["throttled"] = True
                        just_throttled = True
                        to_throttle_add.append((device_id, session["vless_uuid"]))

                    if (session.get("throttled") and not just_throttled
                            and not session.get("_cleaned_normal")):
                        to_throttle_cleanup.append(device_id)
                        session["_cleaned_normal"] = True

                for device_id in to_remove:
                    # Add final used bytes to the persistent odometer before culling.
                    used = stats.get(device_id, {}).get("total_bytes", 0)
                    if used > 0:
                        _persistent_total_gb += used / 1_000_000_000
                        _save_persistent_total()
                    del active_sessions[device_id]

            for device_id in to_remove:
                remove_vless_client(device_id)

            for device_id, uuid in to_throttle_add:
                add_vless_client(uuid, device_id, level=1, inbound_tag=VLESS_REALITY_THROTTLED_TAG)

            for device_id in to_throttle_cleanup:
                remove_vless_client_from(device_id, VLESS_REALITY_TAG)

        except Exception as e:
            print(f"[HIVEMIND] Unhandled error: {e}")

        time.sleep(CHECK_INTERVAL_SECONDS)


# ##############################################################################
# SWARM INTELLIGENCE  (drone status — sorted data for TUI / API consumers)
# ##############################################################################
#   get_swarm_status() returns a list of dicts sorted by GB used (highest first).
#   Callers (CLI tools, TUI dashboards, /api/swarm endpoint) consume this.
#   It snapshots active_sessions under lock and reads Xray stats — no side effects.
# ##############################################################################

def get_swarm_status():
    """Return sorted drone list + aggregate totals for external monitoring.

    Returns a dict:
        {
            "drones": [ {...}, {...}, ... ],   # sorted by gb descending
            "swarm_gb": 7.3,                   # total GB across all drones
            "active_count": 3,                 # sessions still alive
        }

    Each drone dict:
        {
            "id":           "a1b2c3d4",       # first 8 chars of device_id
            "uptime_min":   23,                # minutes since session created
            "gb":           2.14,              # data used (GB, 2 decimal places)
            "throttled":    false,             # over quota?
            "active":       true,              # had traffic in the last tick?
            "remaining_min": 37,               # minutes until expiry
        }
    """
    now   = time.time()
    stats = get_xray_stats()

    with sessions_lock:
        drones = []
        for device_id, session in active_sessions.items():
            used_bytes = stats.get(device_id, {}).get("total_bytes", 0)
            gb = round(used_bytes / 1_000_000_000, 2)
            uptime_min = int((now - session.get("_created_at", session.get("expires_at", now) - MAIN_AD_MINUTES * 60)) / 60)
            remaining_min = max(0, int((session["expires_at"] - now) / 60))
            prev_bytes = session.get("_prev_bytes", 0)
            active = used_bytes > prev_bytes

            drones.append({
                "id":            device_id[:8],
                "uptime_min":    max(0, uptime_min),
                "gb":            gb,
                "throttled":     session.get("throttled", False),
                "active":        active,
                "remaining_min": remaining_min,
            })

    # Sort: highest data usage first — abusers float to the top.
    drones.sort(key=lambda d: d["gb"], reverse=True)

    swarm_gb = round(sum(d["gb"] for d in drones), 2)

    return {
        "drones":       drones,
        "swarm_gb":     swarm_gb,
        "total_gb":     round(_persistent_total_gb + swarm_gb, 2),
        "active_count": len(drones),
    }


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


def add_vless_client(uuid, email, level=0, inbound_tag=VLESS_REALITY_TAG):
    """Add a client UUID to the Xray inbound config and hot-reload.

    level       -- Xray policy level for bandwidth limits: 0 = default.
    inbound_tag -- which inbound to add the client to (default: VLESS_REALITY_TAG).
    """
    with open(XRAY_CONFIG, 'r') as f:
        config = json.load(f)

    for inbound in config["inbounds"]:
        if inbound.get("tag") == inbound_tag:
            inbound["settings"]["clients"].append({
                "id": uuid,
                "email": email,
                "level": level,
                "flow": "xtls-rprx-vision"
            })
            break

    _atomic_write_json(XRAY_CONFIG, config)
    run_cmd("xray api adi --server=127.0.0.1:10085")
    print(f"[VLESS] User added to {inbound_tag}: {email[:16]}...")


def remove_vless_client(email):
    """Remove a client from ALL VLESS inbounds and hot-reload."""
    with open(XRAY_CONFIG, 'r') as f:
        config = json.load(f)

    for inbound in config["inbounds"]:
        if inbound.get("tag") in (VLESS_REALITY_TAG, VLESS_REALITY_THROTTLED_TAG):
            clients = inbound["settings"]["clients"]
            inbound["settings"]["clients"] = [
                c for c in clients if c.get("email") != email
            ]

    _atomic_write_json(XRAY_CONFIG, config)
    run_cmd("xray api adi --server=127.0.0.1:10085")
    print(f"[VLESS] User removed: {email[:16]}...")


def remove_vless_client_from(email, inbound_tag):
    """Remove a client from one specific inbound and hot-reload."""
    with open(XRAY_CONFIG, 'r') as f:
        config = json.load(f)

    for inbound in config["inbounds"]:
        if inbound.get("tag") == inbound_tag:
            clients = inbound["settings"]["clients"]
            inbound["settings"]["clients"] = [
                c for c in clients if c.get("email") != email
            ]
            break

    _atomic_write_json(XRAY_CONFIG, config)
    run_cmd("xray api adi --server=127.0.0.1:10085")
    print(f"[VLESS] User removed from {inbound_tag}: {email[:16]}...")


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
