# PaladinVPN — Technical Audit & UX Bug Report

**Date:** 2025-07-15  
**Scope:** Full codebase — Flutter client (`lib/`), Android native layer (`android/`, `local_packages/wireguard_flutter/`), Python Hivemind server (`server_hivemind_5_0.py`)

---

## 🔴 Critical Blockers
*Things that will crash the app, break the VPN, or get the app rejected by Google Play.*

---

### 1. Conflicting `build.gradle.kts` — Dual `applicationId` Declaration

**Files:** `android/build.gradle.kts` (root) vs `android/app/build.gradle.kts` (app-level)

The **root** `build.gradle.kts` incorrectly applies `com.android.application` and declares:
- `namespace = "com.esefcloud.vpn"`
- `applicationId = "com.esefcloud.vpn"`

The **app-level** `build.gradle.kts` correctly declares:
- `namespace = "com.paladinvpn.app"`
- `applicationId = "com.paladinvpn.app"`

The root project should NOT apply `com.android.application`. This causes merge conflicts, duplicate `AndroidManifest` merging, and can unpredictably override the `applicationId`. If the package name doesn't match your Play Console listing, Google Play **will reject** the upload. AdMob is also tied to the application ID.

**Fix:** Remove the `com.android.application` plugin and the `android {}` block from the root `build.gradle.kts`. Those belong only in `android/app/build.gradle.kts`.

---

### 2. Missing Foreground Service Type Declaration (Android 14+) — **REJECTION RISK**

**Files:** `android/app/src/main/AndroidManifest.xml`, `local_packages/wireguard_flutter/android/src/main/AndroidManifest.xml`

Your manifest declares:
```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE"/>
```

But there is **no `<service>` element** declaring `android:foregroundServiceType`. Android 14 (API 34) **requires** every foreground service to declare a type (e.g., `dataSync`, `connectedDevice`, `specialUse`). The AmneziaWG library starts a VPN foreground service internally — without the type declaration in the merged manifest, the service **will crash on launch** on Android 14+ devices.

Additionally, `FOREGROUND_SERVICE_SPECIAL_USE` triggers a Google Play review requirement: you must submit a written justification. VPN apps typically don't need this permission — the `VpnService` API includes its own persistent notification mechanism that is exempt from the foreground service type requirement. Consider removing `FOREGROUND_SERVICE_SPECIAL_USE` entirely.

The wireguard_flutter plugin's manifest at `local_packages/wireguard_flutter/android/src/main/AndroidManifest.xml` is **completely empty** — it must include the VpnService declaration or ensure the AmneziaWG AAR ships its own.

**Fix:** Verify whether the AmneziaWG AAR declares the VpnService in its own manifest. If not, add it to the plugin manifest with the proper `foregroundServiceType`.

---

### 3. AdMob SSV Completely Bypassed — Both Client and Server

**Files:** `lib/logic/hivemind_service.dart` (lines 21–29), `server_hivemind_5_0.py` (lines 424–438)

**Client-side** — `hivemind_service.dart` fires a **fake AdMob ping** on every connection:
```dart
// ── TEMPORARY AD BYPASS HACK FOR TESTING ──
final fakeAdmobPingUrl = Uri.parse(
    '${AppConfig.hivemindApiBase}/admob/callback?signature=test&key_id=test&custom_data=...');
await http.get(fakeAdmobPingUrl).timeout(const Duration(seconds: 8));
```
The error is swallowed (`catch (_) {}`), so even if the server is unreachable the app proceeds to poll.

**Server-side** — `server_hivemind_5_0.py` has the **entire** ECDSA signature verification block commented out:
```python
# ⚠️ ADMOB BYPASS (TEMPORARY FOR APP REVIEW)
# DELETE THIS ENTIRE BLOCK WHEN YOU WANT TO ENABLE REAL ADS
```
The `/api/admob/callback` endpoint processes **all** requests unconditionally.

**Impact:** Anyone can `curl https://paladinvpn.duckdns.org/api/admob/callback?custom_data=...` and create unlimited 60-minute/2GB sessions without watching an ad. Google Play reviewers or automated testing will detect that the ad flow is non-functional. This is grounds for **immediate rejection** under the "Deceptive Behavior" policy.

**Fix:** Remove both bypasses. Enable real SSV signature verification on the server. Remove the fake ping from `hivemind_service.dart` — the actual connection flow must wait for Google's server-to-server callback, not a client-side fake.

---

### 4. `app_config.dart` Contains Production Secrets — Verify Git Tracking

**File:** `lib/logic/app_config.dart`

The `.gitignore` lists `lib/logic/app_config.dart`, and an example template exists at `app_config.example.dart`. However, the **real file exists in the working tree** with:
- Production server IP: `204.168.246.88`
- Production AdMob unit ID: `ca-app-pub-5671224884648691/9198987725`
- Production AdMob app ID: `ca-app-pub-5671224884648691~1007152454` (in AndroidManifest)
- Production DuckDNS domain: `paladinvpn.duckdns.org`

**Run immediately:**
```powershell
git ls-files lib/logic/app_config.dart
```
If it returns the file, it IS tracked — meaning these secrets are in your git history forever. You would need to:
1. Rotate the AdMob IDs (create new ad units)
2. Change the server IP or accept it's public
3. Use `git filter-branch` or `BFG Repo-Cleaner` to scrub history

---

### 5. `/api/session/start` Endpoint Does Not Exist — Bonus Ads Are Broken

**Files:** `lib/logic/session_timer.dart` → `addBonusTime()`, `server_hivemind_5_0.py`

The `addBonusTime()` method in SessionTimer does an HTTP POST to:
```
POST ${AppConfig.hivemindApiBase}/session/start
```

The server has **no such route**. The server only has:
- `GET  /api/session/status` — status polling
- `POST /api/session/stop`  — session cleanup
- `GET  /api/admob/callback` — SSV (bypassed)

The intended flow is: user watches ad → Google calls your server via SSV → server extends the session. But since SSV is bypassed AND the endpoint is missing, **bonus ads do absolutely nothing**. The user watches a 30-second ad, the `showAd()` returns `true`, the snackbar says "+30 minutes added!", but the server session is never extended. After the current session expires, the user is throttled/disconnected regardless.

**Fix:** Either add the `/api/session/start` endpoint to the server, or — the correct approach — enable real SSV and have the server extend sessions inside the `/api/admob/callback` handler (which it already does for both `main_ad` and `bonus_ad` types). Then `addBonusTime()` only needs to re-sync, not create a session.

---

### 6. Server Public Key Fallback Is a Hardcoded Invalid String

**File:** `server_hivemind_5_0.py` (~line 480)

When the server can't fetch the WireGuard public key from `awg0`:
```python
SERVER_PUBKEY = SERVER_PUBKEY_FALLBACK or "server key="
```

The string `"server key="` is not a valid base64 WireGuard key. If this fallback is ever hit, every client connection will fail with an invalid config. The `SERVER_PUBKEY_FALLBACK` is `None` by default, so the fallback-to-fallback string is always used. Either set a real fallback key or fail gracefully with a clear error log.

---

## 🟡 Warnings — Architecture & Reliability
*Race conditions, edge cases, and architecture flaws that could cause a bad user experience.*

---

### 7. Race Condition: Optimistic Client State Before Server Confirmation

**File:** `lib/logic/session_timer.dart` → `start()`

```dart
_remainingSeconds = 3600; // optimistic start
_quotaBytes = 2 * 1024 * 1024 * 1024;
```

The UI immediately renders "01:00:00" and "2.00 GB" before the first server sync completes (~1–3 seconds). If the server allocated a different duration (e.g., 45 minutes from a previous session that wasn't properly cleaned), the UI flashes wrong data then jumps to the correct value. Users perceive this as a glitch.

**Fix:** Set initial values to 0 or show a loading state until the first sync returns. Display "Calculating…" or a shimmer placeholder until real data arrives.

---

### 8. Race Condition: In-Flight HTTP Callback During Disconnect

**File:** `lib/logic/session_timer.dart`

`_syncWithHivemind()` fires on a `Timer.periodic` every 1 second (sync every 3rd tick). When the user disconnects:
1. `vpn.disconnect()` is called
2. `timer.stop()` cancels the timer
3. But an in-flight `_syncWithHivemind()` HTTP request may still be pending
4. When it completes, it sees `!active` → calls `stop()` and `vpnConnection.disconnect()` again

The double-disconnect is mostly harmless since `disconnect()` guards against re-entry, but it could cause the cleanup HTTP call (`disconnectAndCleanup()`) to fire twice, and the notification to be cancelled/restored in a flicker.

**Fix:** Add an `_isDisconnecting` flag checked at the top of `_syncWithHivemind()`.

---

### 9. No Graceful Recovery From Temporary Network Drops

**File:** `lib/logic/session_timer.dart` → `_tick()` and `_syncWithHivemind()`

The local `_tick` decrements `_remainingSeconds` **every second regardless of sync status**. If the server is unreachable for 60 seconds:
- The UI countdown hits `00:00:00`
- The user sees "expired" 
- But the server session is still valid (it has its own expiry clock)
- When the network returns, the next sync jumps the timer back up — confusing the user

The catch block silently logs and does nothing:
```dart
} catch (e) {
  debugPrint('Hivemind sync error: $e');
  // If we can't reach the server, just let the local timer run
}
```

This is **not** "just letting the local timer run" — the local timer is actively decrementing, creating a growing drift from reality.

**Fix:** Track consecutive sync failures. After 3 failures, pause the local countdown and show "Reconnecting…" in the UI. Resume when sync succeeds.

---

### 10. Permission Dialog + Immediate Failure = Broken UX

**File:** `local_packages/wireguard_flutter/.../WireguardFlutterPlugin.kt` → `connect()`

```kotlin
if (!havePermission) {
    checkPermission()  // launches system VPN permission dialog
    throw Exception("Permissions are not given")  // immediately fails
}
```

`checkPermission()` fires an intent that shows the Android VPN permission dialog. But the code **immediately throws an exception** — before the user even sees the dialog. The Flutter side receives the error, sets status to `VpnStatus.error` with "Tunnel error", and the user sees a failure message. Meanwhile, the system permission dialog is still on screen. The user grants permission, returns to the app, sees "Tunnel error", and must tap Connect again.

**Fix:** Make `connect()` wait for the permission result (use `startActivityForResult` with a callback/completer pattern) instead of throwing.

---

### 11. 3-Second Polling Per Client — Server Scalability Issue

**File:** `lib/logic/session_timer.dart` → `_syncWithHivemind()`

Every connected client hits your Flask server every 3 seconds. With 100 concurrent users, that's ~33 requests/second. Flask's development server is single-threaded — it will queue requests and time out. Even with gunicorn, this is expensive.

**Fix:** Increase the poll interval to 5–10 seconds. Better: use Server-Sent Events (SSE) or a lightweight WebSocket so the server pushes updates rather than the client polling.

---

### 12. `isVpnChecked` Flag — Single-Use, State Desync on App Restoration

**File:** `local_packages/wireguard_flutter/.../WireguardFlutterPlugin.kt`

The `isVpnChecked` flag is set only in the `"start"` method and reset only in `onDetachedFromEngine`. If the Flutter engine is killed and recreated (process death), the flag is `false` but the VPN may still be running. On restart, `VpnConnection._init()` calls `_wireguard.stage()` to detect the running tunnel — this path works, but the native plugin's internal state tracking is fragile.

---

### 13. Server: `management_loop` Blocks on Subprocess Calls

**File:** `server_hivemind_5_0.py` → `management_loop()`

The loop calls `get_wireguard_stats()` every 60 seconds, which spawns two Docker exec subprocesses:
```python
transfer_out = run_cmd("awg show awg0 transfer")
allowed_out  = run_cmd("awg show awg0 allowed-ips")
```

Each `run_cmd` calls `subprocess.run()` synchronously. If Docker is slow or the system is under load, these calls can take seconds. The management loop is single-threaded — during this time, expired sessions are not cleaned up and the Flask server (if running single-process) may be blocked on the GIL.

**Fix:** Use `subprocess.Popen` with a timeout, or cache stats more aggressively.

---

### 14. Server: `tc filter` Cleanup Is Never Done on Expiry — Possible tc Rule Leak

**File:** `server_hivemind_5_0.py` → `management_loop()`

When a session expires in the management loop, the code does:
```python
expired_devices.append(device_id)
```
Then later:
```python
for device_id in expired_devices:
    del active_sessions[device_id]
```

But the associated `tc` throttle rules are **never removed** on expiry. The `remove_throttle()` + `remove_wg_peer()` + `release_ip()` calls only happen in `session_stop()` (explicit disconnect from the app). If the app crashes or the user force-stops, expired sessions leave orphaned tc filter/class rules. Over weeks, the tc qdisc accumulates hundreds of dead rules, degrading network performance.

**Fix:** In the expiry cleanup block, call `remove_throttle()`, `remove_wg_peer()`, and `release_ip()` for each expired device.

---

### 15. No ProGuard/R8 Rules for AmneziaWG Native Library

**File:** `android/app/build.gradle.kts`

There is no `minifyEnabled`, no ProGuard configuration, and no keep rules for the `org.amnezia.awg` native library. Release builds may strip JNI bindings, causing `UnsatisfiedLinkError` crashes.

**Fix:** Add a `proguard-rules.pro` with keep rules for `org.amnezia.awg.backend.*` and `org.amnezia.awg.crypto.*`, and enable minification in `buildTypes { release { ... } }`.

---

## 🟢 Polish & Best Practices
*Minor code cleanliness, structural improvements, and maintenance issues.*

---

### 16. `build.gradle.kts` Root Duplicates `flutter {}` and Kotlin Config

The root `build.gradle.kts` redundantly declares `flutter { source = "../.." }` and `kotlin { compilerOptions { ... } }` which are already in the app-level file. This is dead config that causes confusion.

---

### 17. `AppConfig` Is Instantiable Despite Being Static-Only

**File:** `lib/logic/app_config.dart`

```dart
class AppConfig {
  static const String serverIp = '...';
  // ...
}
```

Nothing prevents `AppConfig()` from being instantiated. Mark it:
```dart
abstract final class AppConfig {
  AppConfig._();
  // ...
}
```

---

### 18. Debug Banner Disabled Unconditionally

**File:** `lib/main.dart`

```dart
debugShowCheckedModeBanner: false,
```

This disables the debug banner even during development. Consider:
```dart
debugShowCheckedModeBanner: false,  // acceptable for this app's dark theme
```

Not a bug, but the debug banner is useful during development for catching accidental release-mode testing.

---

### 19. Privacy Policy Links to GitHub Raw `.md` — May Render Poorly

**File:** `lib/components/privacy_policy_button.dart`

```dart
final Uri url = Uri.parse('https://github.com/esefxdz/PaladinVPN/blob/main/PRIVACY_POLICY.md');
```

Google Play requires your privacy policy to be a properly hosted URL. GitHub raw links are generally accepted, but a `.md` file renders as raw text in a browser. Use GitHub Pages or a simple HTML page.

---

### 20. `url_launcher` on Android 11+ Requires `<queries>` — Already Done

Your manifest correctly includes the `<queries>` block for `intent.action.VIEW`. No issue here — confirming compliance.

---

### 21. Hardcoded "Helsinki, Finland" Location

**File:** `lib/components/status_text.dart`

The server location is hardcoded. If you ever add more servers or move the server, the UI lies. Move this to `AppConfig` or fetch it from the server.

---

### 22. Zero Tests

**Files:** No `test/` directory, no test files anywhere.

Despite `flutter_test` being in `dev_dependencies`, there are zero unit tests, widget tests, or integration tests. For a VPN app handling:
- Cryptographic key generation and persistence
- Session state machine transitions
- Network timeout and retry logic
- Ad reward flow

At minimum, unit-test the crypto service, session timer logic, and config parsing.

---

### 23. `Server Full Picture.txt` in `.gitignore` But Present in Working Tree

The file `server full picture.txt` is in `.gitignore` but exists locally. It contains sensitive server configuration (IP addresses, Docker setup, iptables rules). Verify it's not tracked by git:
```powershell
git ls-files "server full picture.txt"
```

---

## 👤 User Experience Bugs
*Things that create an unpleasant, confusing, or glitchy experience for real users.*

---

### UX-1. 5-Second Cooldown Triggers Even on Instant Failure

**File:** `lib/components/connect_button.dart` → `_handleTap()`

```dart
setState(() => _inCooldown = true);
Future.delayed(const Duration(seconds: 5), () {
  if (mounted) setState(() => _inCooldown = false);
});
```

The cooldown is set **before** attempting the connection. If the connection fails instantly (no network, server unreachable, permission denied), the user sees:
- "PLEASE WAIT" with an hourglass icon
- A greyed-out, unresponsive button
- For **5 full seconds**

This is infuriating. The user knows the connection failed, but the app locks them out anyway.

**Fix:** Only apply the cooldown on **successful** connections (to prevent rapid disconnect/reconnect spam). On failure, reset immediately or use a much shorter cooldown (1 second).

---

### UX-2. Countdown Timer Jumps Backward When Sync Arrives Late

**File:** `lib/logic/session_timer.dart`

The optimistic start sets `_remainingSeconds = 3600`. The `_tick()` decrements it every second. When the first server sync arrives (1–3 seconds later), the server returns the *real* `expires_in_seconds` — which could be anything from 0 to 3600. The timer visibly jumps:

```
01:00:00 → 00:59:59 → 00:59:58 → [sync] → 00:45:23  ← user sees a jump
```

Even worse if the sync fails for 10 seconds — the tick keeps decrementing local time while the server still shows 3600. When sync resumes, the timer jumps UP:

```
00:59:50 → [sync] → 01:00:00  ← "Wait, did I just gain time?"
```

**Fix:** Don't start the local countdown until the first successful sync. Show "Syncing…" or a blurred placeholder until real data arrives.

---

### UX-3. "TAP TO CONNECT" Is Always Visible — Even When Nothing Will Happen

**File:** `lib/components/connect_button.dart`

When tapping has no possible effect (no network, ad not loaded, cooldown active), the button still says "TAP TO CONNECT". The only indication that tapping won't work is a subtle color change (grey vs muted blue). Users will tap repeatedly and wonder why nothing happens.

**Fix:** Show contextual text:
- No network: "NO CONNECTION"
- Ad loading: "LOADING AD…"
- Cooldown: "PLEASE WAIT" (already done)
- Ready: "TAP TO CONNECT"

---

### UX-4. No Feedback When Ad Fails to Load

**File:** `lib/logic/ad_manager.dart`

If `_preloadAd()` fails, `_isAdLoaded` stays `false`. The `ConnectButton` doesn't check `AdManager.isAdLoaded` at all — it proceeds to call `vpn.connect()` which calls `hivemind_service.fetchConfigWithPolling()`, which fires the fake SSV ping (see Critical #3), which polls. The user sees "Establishing tunnel…" for up to 30 seconds (15 polls × 2 seconds) then gets a cryptic "Session not activated" error.

**Fix:** Check `adManager.isAdLoaded` before attempting connection. If no ad is ready, show "Ad not ready, please wait…" and trigger a reload.

---

### UX-5. Snackbar Says "+30 minutes added!" Even When Bonus Fails

**File:** `lib/components/watch_ad_button.dart`

```dart
final success = await context.read<AdManager>().showAd('bonus_ad');
if (success && context.mounted) {
  context.read<SessionTimer>().addBonusTime();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: const Text('+30 minutes added!'), ...),
  );
}
```

The snackbar shows **regardless of whether `addBonusTime()` succeeded**. The `addBonusTime()` method silently catches all errors. So the user sees "+30 minutes added!" but the server never got the request (missing endpoint, see Critical #5). The timer stays unchanged. The user thinks the app is broken or lying.

**Fix:** `addBonusTime()` should return a `bool`. Only show the success snackbar if the API call succeeded. Show an error snackbar otherwise.

---

### UX-6. Intro Splash Screen — 2.5 Seconds of Wasted Time, Every Launch

**File:** `lib/screens/intro.dart`

```dart
Timer(const Duration(milliseconds: 2500), () {
  if (mounted) {
    Navigator.of(context).pushReplacement(...);
  }
});
```

Every time the user opens the app, they stare at a logo and spinner for 2.5 seconds. This is a placeholder delay, not a loading screen — nothing is being loaded. For an app that users open frequently to check their VPN status, this adds up to minutes of wasted time per week.

**Fix:** Remove the artificial delay. If the app genuinely needs startup time (e.g., checking for a running tunnel), make the intro screen reflect actual loading progress and transition as soon as `_init()` completes.

---

### UX-7. Notification Shows "0.00 KB/s" on Slow Connections

**File:** `lib/logic/session_timer.dart` → `_syncWithHivemind()`

```dart
if (_lastUsedBytes > 0 && deltaBytes > 0) {
  _currentSpeedKbps = (deltaBytes / 3) / 1024;
} else {
  _currentSpeedKbps = 0.0;
}
```

The speed calculation uses `_lastUsedBytes > 0` as a guard. On the first sync, `_lastUsedBytes` is 0, so speed shows `0.00 KB/s`. If the user isn't actively transferring data, the delta is 0 and speed shows `0.00 KB/s`. The persistent notification displays "0.00 KB/s" which looks like the VPN is broken. Users associate "0.00 KB/s" with "not working."

**Fix:** Show "Idle" or "Connected" instead of "0.00 KB/s" when speed is effectively zero.

---

### UX-8. Persistent Notification Is Re-Posted Every 3 Seconds

**File:** `lib/components/notification.dart` → `showOrUpdateStatus()`

The notification is updated every 3 seconds (every sync cycle). On some Android skins (Xiaomi, OnePlus, Samsung), frequent notification updates cause the notification to "flicker" in the shade — it briefly disappears and reappears. This is distracting and looks buggy.

**Fix:** Only update the notification when the displayed values actually change (time string differs from last posted, speed changes by >10%).

---

### UX-9. No Visual Indicator That Bonus Ad Loading Failed

**File:** `lib/components/watch_ad_button.dart`, `lib/logic/ad_manager.dart`

The `WatchAdButton` always renders — even if no ad is loaded. Tapping it calls `showAd('bonus_ad')` which internally calls `_preloadAd()` and waits. If loading fails, `showAd()` returns `false` and… nothing happens. No error message. No snackbar. The user taps "Support +30m", waits a moment, and… nothing. They'll tap again. And again.

**Fix:** Show the ad button with a loading state ("Loading ad…") when no ad is ready. Show a brief error if loading fails after a tap.

---

### UX-10. Disconnect Clears Timer Instantly — No "Tearing Down" Visual

**File:** `lib/logic/session_timer.dart` → `stop()`

```dart
void stop() {
  _timer?.cancel();
  _timer = null;
  _remainingSeconds = 0;
  ...
}
```

`stop()` sets the timer to zero immediately, but the `VpnConnection` goes through a `disconnecting → disconnected` transition. The ConnectButton circle shows a spinner during disconnection, but the timer text inside it jumps to `00:00:00` prematurely.

**Fix:** Don't zero the timer in `stop()`. Let `VpnConnection` control the disconnect flow and only zero the timer when the status reaches `disconnected`.

---

### UX-11. Error Messages Are Generic and Unhelpful

**File:** `lib/logic/vpn_connection.dart` → `connect()`

```dart
_errorMessage = 'Tunnel failed to start.\nTry reconnecting.';
```

Every failure produces the same error message. The user doesn't know if:
- The server is down
- Their network has no internet
- The ad wasn't watched
- The config was invalid
- Android denied VPN permission

This makes debugging impossible for users and will generate 1-star reviews saying "doesn't work."

**Fix:** Surface specific error messages from each failure branch. Map them to user-friendly strings.

---

### UX-12. Connected Timer Text Is Small and Hard to Read at a Glance

**File:** `lib/components/clock_display.dart`

The countdown text is 40px inside a 260px circle. For a quick-glance status, many users will pick up their phone and squint at "01:00:00" in white on a dark background. The speed text below it (12px, grey) is nearly invisible in sunlight.

**Fix:** Consider increasing font weight, adding a subtle background contrast behind the timer, or showing remaining time in the notification as a large-format text for at-a-glance viewing.

---

### UX-13. No Haptic Feedback on Connect/Disconnect

**File:** `lib/components/connect_button.dart`

The connect/disconnect action has no haptic feedback. For a button this important, a brief vibration on successful connection gives tactile confirmation. Many premium VPN apps do this.

---

### UX-14. Intro Screen "PALADIN VPN" Text Has No Loading Context

**File:** `lib/screens/intro.dart`

The intro shows a logo, "PALADIN VPN", and a spinning circle for 2.5 seconds. It doesn't say "Loading…" or "Preparing…" — it's just a spinner. Users may think the app froze. If the startup takes longer (slow device), 2.5 seconds feels like an eternity with no text indicating progress.

---

### UX-15. Status Bar Icon Brightness Is Always Light

**File:** `lib/main.dart`

```dart
statusBarIconBrightness: Brightness.light,
```

This is correct for the dark theme — light icons on a transparent/dark status bar. No bug here. Confirming compliance.

---

### UX-16. App Crashes If WireGuard Plugin Is Not Available

**File:** `lib/logic/vpn_connection.dart` → `_init()`

The `try/catch` around initialization catches the error, but `_wireguard` remains half-initialized. If the AmneziaWG native library fails to load (wrong architecture, missing .so files), subsequent calls to `startVpn()` or `stopVpn()` will throw unhandled exceptions that crash the app.

**Fix:** Set a `_isAvailable` flag after successful init. Guard all VPN operations behind it. Show "VPN service unavailable" in the UI if init failed.

---

## Summary

| Category | Count | Top Priority Items |
|----------|-------|-------------------|
| 🔴 Critical Blockers | 6 | Conflicting `applicationId`, missing `foregroundServiceType`, SSV bypasses, secrets in git, broken bonus ads, invalid server key fallback |
| 🟡 Warnings | 9 | Optimistic state flash, disconnect race, no network-drop recovery, permission dialog UX, polling scale, tc rule leak, ProGuard missing |
| 🟢 Polish | 9 | Static class, no tests, hardcoded location, privacy policy URL, debug banner, dead gradle config |
| 👤 UX Bugs | 16 | Cooldown on failure, timer jumps, broken bonus feedback, 2.5s artificial delay, generic errors, notification flicker, 0.00 KB/s display |

**Before Google Play submission, fix items 1–6 in Critical Blockers. Items UX-1 through UX-7 will directly prevent 1-star reviews.**
