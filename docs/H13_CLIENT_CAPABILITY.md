# H13 client activation capability

Status: preparation/recovery primitive only. Production AdMob main-reward cutover is not enabled by this branch.

The client keeps two distinct values:

- `session_secret`: private 32-lowercase-hex authorization material sent only to the configured ReVoltVPN HTTPS control plane;
- `activation_id`: public UUIDv4 correlation material returned by the server and intended for the later AdMob SSV cutover.

Before preparation network I/O, the private secret is persisted so a response loss or process restart cannot silently forget cleanup authority. Abandonment first converges activation-intent cancellation and then performs authenticated exact-secret `/session/stop`; local ownership is cleared only after both operations are definitive. Promotion may clear pending ownership only for the exact activation-id/secret pair after authenticated active-session proof has persisted the same secret as current possession.

Support rewards and existing AdMob custom_data are intentionally unchanged until the backend H13 state, preparation API, nginx admission, and exact-client integration gates are accepted.
