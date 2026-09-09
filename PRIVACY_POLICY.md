# Privacy Policy

**Last updated:** September 2026

ReVoltVPN is a VPN application and service built and operated by ReVolt Team.

## In-app disclosure

When you first open the app, we show a short data-use disclosure before you connect. You can review this policy from the sidebar menu.

## Data used to operate a session

The service uses the minimum session data needed for connection control and quota enforcement:

- A randomly generated UUIDv4 device identifier created on your phone. The current client canonicalizes this identifier before sending it to the API.
- Session lifecycle and accounting values such as expiry, quota, and total bytes used for the current server-managed session.
- A per-session authorization value used to prove ownership of the active session when checking status or requesting a stop. This value is treated as control-plane credential material and is not returned by the status API.

The application does not ask for your name or email as part of the VPN session protocol.

## What the network edge can observe

Before a tunnel exists, the app must contact the ReVoltVPN API over the ordinary network to obtain, check, or revoke a session. The network edge handling that TLS connection can therefore observe connection metadata such as the source network address while the request is in flight.

The managed ReVoltVPN nginx configuration disables access logging for public API routes, including query-bearing session and AdMob callback routes. It also disables nginx location error logs for the query-bearing routes. This prevents the managed edge configuration from intentionally persisting full request URLs containing pseudonymous identifiers or callback data.

## Session quotas and retention

Session limits are server-authoritative and may be changed by service configuration. A session is stopped when the server reports that its time or data allowance has been exhausted.

The current Rust backend stores durable session state in its local database and transitions sessions to terminal states such as revoked, expired, or cap-exhausted. The current implementation does **not** promise immediate deletion of the session row when a session ends. Any future production retention period must be documented and enforced before a shorter deletion claim is made.

## Operational logs

The Rust services write operational events and errors to their service journal. The managed public nginx API boundary has access logging disabled. The application and API are not designed to record browsing contents, DNS query contents, or a per-request list of tunnel destinations as part of session accounting.

Log retention is controlled by the deployed host's journal and operational configuration. Release documentation must not claim a shorter retention period unless that period is actually configured and verified on the production host.

## Ads and third-party processing

The current source checkpoint has rewarded advertising disabled in the app (`AdManager.adsEnabled = false`). The repository nevertheless contains an optional Google AdMob rewarded-ad integration that may be enabled in a future release.

When Google AdMob is enabled, Google may process information required for ad delivery, consent, fraud prevention, and server-side verification under Google's own terms and privacy policy. ReVoltVPN server-side verification custom data can contain a pseudonymous device identifier and a callback correlation value. Therefore ReVoltVPN does **not** make a blanket claim that no data is ever processed by third parties when the AdMob integration is enabled.

ReVoltVPN does not sell tunnel contents or browsing history.

## VPN traffic

VPN traffic is carried through the configured ReVoltVPN tunnel endpoint. The application-level quota mechanism tracks aggregate session bytes rather than packet contents. The client hardening branch explicitly disables local Xray access logging. Production release acceptance still requires verifying the deployed server/Xray logging configuration before making stronger claims about server-side destination or DNS retention.

## Security and release scope

This policy describes the behavior supported by the current source and managed deployment configuration. It is not, by itself, proof that a particular APK or server deployment matches that source. Production release provenance, signing, deployed Xray configuration, and host retention settings are separate release acceptance requirements.

## Contact

If you have questions about this policy, use the project's documented support or repository contact channel.
