#!/usr/bin/env python3
from pathlib import Path

PATH = Path("lib/logic/session_timer.dart")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


text = PATH.read_text()
old = '''        final active = data['active'] == true;
        if (!active) {
          await _doDisconnect('Server ended session');
          return;
        }

        _remainingSeconds = _readNonNegativeInt(
          data['expires_in_seconds'],
          _remainingSeconds,
        );
        _usedBytes = _readNonNegativeInt(data['used_bytes'], _usedBytes);
'''
new = '''        final activeValue = data['active'];
        if (activeValue is! bool) {
          // A malformed HTTP 200 payload is not an authoritative command to
          // tear down a healthy VPN. Count it as a sync failure instead.
          debugPrint('[Timer] Session payload missing boolean active state.');
          _markSyncFailure();
          return;
        }
        if (!activeValue) {
          // Explicit server revocation remains authoritative.
          await _doDisconnect('Server ended session');
          return;
        }

        final expiresValue = data['expires_in_seconds'];
        if (expiresValue is! num ||
            !expiresValue.isFinite ||
            expiresValue < 0) {
          // Do not turn a missing/malformed TTL into zero and disconnect one
          // tick later. Only a real zero returned by the server means expiry.
          debugPrint('[Timer] Session payload has invalid expiry.');
          _markSyncFailure();
          return;
        }
        _remainingSeconds = expiresValue.toInt();
        _usedBytes = _readNonNegativeInt(data['used_bytes'], _usedBytes);
'''
text = replace_once(text, old, new, "session authority parsing")
PATH.write_text(text)
print("Applied SessionTimer malformed-payload self-stop fix")
