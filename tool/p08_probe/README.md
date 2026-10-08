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

The extended independent-UID probe additionally sends bounded **test-only**
`example.com` A and AAAA DNS wire queries directly to the public 1.1.1.1
resolver over UDP/53; A over TCP/53; DNS-over-TLS to
`cloudflare-dns.com` at 1.1.1.1:853; and DNS-over-HTTPS to the same name
at 1.1.1.1:443. HTTPS/TLS certificate checks use the server hostname,
not merely SNI. No user browsing data or session credentials are probed.

`RESPONSE_VERIFIED` means an actual DNS wire response was read and its
transaction ID, response flag, complete echoed QNAME, QTYPE and QCLASS matched.
Header-only, truncated, altered or mismatched DNS questions are unverified.
A TCP connect acknowledgment alone
is not a DNS response. A reply may legitimately be carried by an active
VPN. It is **not** by itself a leak. A timeout likewise does not prove a
DNS packet did not escape. No-TUN network blocking requires all five
direct DNS transport attempts to be denied at connect time in addition
to the existing independent-UID IPv4/IPv6/DNS checks. Ambiguity yields
`INCONCLUSIVE_OR_POSSIBLE_ESCAPE_INVESTIGATE` rather than a pass.

`DnsEvidence.java` is a pure Java validation helper included in the isolated
probe APK, with 14 positive/negative cases in `DnsEvidenceTest.java` that run
in CI without Android networking, an upstream DNS resolver or user data.
These tests confirm that a 12-byte DNS header is insufficient as evidence.

Extended tests can take longer than the earlier probe. The script now
uses a 45-second default deadline; use `-TimeoutSeconds 60` for a slow
synthetic VPN. Production APK, VPN policies, routes and user DNS settings
remain untouched.

The probe now samples Android's current network handle, VPN transport
classification and DNS server count **before and after each attempt**. Both
the beginning and final network status are logged without device identifiers;
`NETWORK_STABLE=true` is required for either limited positive verdict. A
handover to another network (including another VPN instance), or any observed
change in VPN classification/DNS count, results in
`INCONCLUSIVE_OR_POSSIBLE_ESCAPE_INVESTIGATE`. Sampling is not continuous:
a very brief transition between two snapshots may still be missed, so physical
underlay capture remains mandatory. The pure mock-ADB regression script
`test-run-probe.ps1` verifies stable, intermediate-change, VPN-to-no-network,
missing-end, duplicate-end and runtime-failure scenarios and runs in GitHub
Actions using PowerShell. It never launches ADB, changes settings or touches
a real device. Any matching `PROBE_FAILED` event ends real runs immediately;
they must not be confused with a successful test timeout. The APK build
explicitly includes the nested `ProbeActivity$NetworkSnapshot.class` in D8
inputs to prevent runtime `NoClassDefFoundError` after successful compilation.

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
