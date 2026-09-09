# Privacy Policy

**Last updated:** September 2026

ReVoltVPN is a free VPN service built and operated by ReVolt Team.

## In-app disclosure

When you first open the app, we show a brief summary of this policy before you connect. You can review this full policy at any time from the sidebar menu.

## What we collect

We collect service data required to create, authorize, account for, recover, and stop VPN sessions:

- A randomly generated device ID created on your phone. It is not based on your name, email address, advertising ID, or phone number, but it is a stable pseudonymous identifier used by the service to associate session state with the same installation.
- Session state linked to that device ID, including session/generation identifiers, temporary VLESS/Xray credential identifiers, session authorization nonce, selected Reality session metadata, creation/update/expiry timestamps, session state, data allowance, and bytes used.
- Operational state needed for reliable recovery, accounting, replay protection, and fail-closed behavior.

## What our server sees

To start, check, refresh, or stop a session, the app contacts our API directly rather than through the VPN tunnel. The network connection carrying those API requests necessarily has a source IP address, and the API requests include the app's pseudonymous device ID where required by the session protocol.

The current Rust session database schema does not store a source-IP field in the `sessions` table. Network infrastructure or host-level logging outside that table may still process connection metadata as necessary to operate and secure the service.

This control-plane traffic is separate from browsing traffic carried inside the VPN tunnel.

## Session quotas and persistent session state

Each session lasts up to **2 hours** or **10 GB** of data — whichever comes first. When your session expires or reaches its data cap, the active VPN credential is revoked and the tunnel is expected to disconnect.

The current Rust backend stores session state in a persistent SQLite database so it can enforce quotas, recover safely after process restarts, reconcile Xray state, prevent stale-generation operations, and perform authorized session shutdown. A session record changes state when it becomes revoked, expired, or cap-exhausted; it is **not automatically deleted merely because the active session ended**.

The current implementation does not define a fixed automatic deletion period for those terminal session records. We therefore do not claim that session metadata disappears immediately at disconnect or expiry. Server maintenance and any future retention policy must preserve the safety and anti-replay invariants required by the service while minimizing retained data.

Support ads (the "Support us" button) extend an active session by 30 minutes and add extra data allowance.

## Operational logs

The Rust services write operational events, health/recovery information, aggregate counters, and error messages to the host's systemd journal. These logs are separate from the SQLite session database. Journal retention is controlled by the server's systemd/journald configuration.

The service is not designed to place browsing history, DNS queries, packet contents, or destination-IP histories into these operational logs.

## What we do not collect as VPN traffic history

- We do not require your name or email address to create a VPN session.
- We do not intentionally record a browsing-history list from traffic passing through the VPN.
- We do not intentionally store DNS-query history or packet contents as part of the VPN session-accounting system.
- We do not sell user data.

These statements do not mean that the service stores no operational metadata at all. The session and operational data described above is required for authentication, quota enforcement, recovery, abuse prevention, and service security.

## Ads & Consent

ReVoltVPN uses Google AdMob to display rewarded video ads. Where required — for users in the European Economic Area (EEA) and United Kingdom — a consent dialog provided by Google's User Messaging Platform is shown before the first ad is requested, letting you choose whether to allow personalized ads. This choice is stored on your device and can be reviewed at any time from the "Ad Consent" entry in the sidebar menu. Google may collect data as part of ad delivery. Please refer to Google's Privacy Policy for details.

## Your traffic

Your internet traffic is routed through the configured ReVoltVPN server. ReVoltVPN's session-accounting system tracks aggregate bytes transferred per session for quota enforcement; it does not require packet contents, browsing URLs, or DNS-query history to perform that accounting.

Network and operating-system components necessarily handle source and destination addresses while forwarding packets. This policy distinguishes that transient packet handling from intentionally creating a persistent browsing-history or destination-history dataset.

## Contact

If you have any questions, open an issue on the GitHub repository or join the Discord server.
