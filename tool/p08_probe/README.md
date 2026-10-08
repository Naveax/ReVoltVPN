# P0.8 independent Android UID probe

This is a test-only Android application, separate from the ReVoltVPN package and UID.
It tests network behavior under Android VPN and Always-on lockdown. Neither a local
TCP connect acknowledgement nor a blocked DNS query proves a fully leak-free VPN.

## Build (Windows / PowerShell 7)

Requirements: JDK 17, Android SDK platform android-35, build-tools 35.0.0.
The signing key and all generated artifacts are written only to OutputDir,
outside this repository. The test key is not a release signing credential.

    ./tool/p08_probe/build-probe.ps1 -AndroidSdkRoot C:\path\to\android_sdk -JdkRoot C:\path\to\jdk17 -OutputDir C:\temp\rvpn-p08-probe

Install the generated probe.apk ONLY on the chosen test device. If upgrading a
probe previously signed with a different disposable debug key, manually uninstall
dev.naveax.p08probe first; this does not involve the production VPN package.

    adb -s emulator-5554 install -r C:\temp\rvpn-p08-probe\probe.apk

## Run

Run the existing read-only preflight and the independent application test as
separate evidence types:

    ./tool/collect_android_privacy_evidence.ps1 -AdbPath C:\path\to\adb.exe -Serial emulator-5554
    ./tool/p08_probe/run-probe.ps1 -AdbPath C:\path\to\adb.exe -Serial emulator-5554

The runner launches only the probe app. It does NOT toggle Android lockdown,
stop or start the VPN service, change routes, or install any package. It uses a
random per-invocation log token so historical logcat lines cannot be mistaken
for current acceptance evidence. Only redacted result types are returned.

Expected scoped negative-path observations:
- With lockdown active and no established TUN: no active network; IPv4, IPv6,
  TLS and default DNS fail.
- With the separate synthetic VLESS+TLS harness and TUN running: Android reports
  a VPN network, IPv6 fails, default DNS fails, and the intentionally invalid
  VLESS upstream cannot complete an application-layer TLS handshake.
- IPv4 connect() alone is NOT end-to-end forwarding proof; physical packet capture
  and a REAL authenticated VLESS/REALITY/XHTTP server are required for P0.8.

If the runner reports INCONCLUSIVE_OR_POSSIBLE_ESCAPE_INVESTIGATE, do not convert
that outcome into a successful privacy claim. Preserve the isolated diagnostics,
inspect underlay traffic and correct the root cause. Always-on lockdown is a
device policy and cannot be proven from Flutter source or a stale event log.

No passwords, full logcat dumps, user DNS queries, session keys or raw payloads
are intentionally emitted by these tools. P0.8 remains BLOCKED-LIVE until its
full acceptance matrix has passed on the exact production candidate.
