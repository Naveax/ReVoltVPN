# H13 client cutover gate

Status: implemented behind a compile-time default-off gate. Not production-enabled.

The production main rewarded-ad path has two mutually exclusive authorization contracts:

- legacy: a 32-lowercase-hex candidate nonce is reserved with ReVolt and used by the existing callback;
- H13: a private 32-lowercase-hex `session_secret` is registered directly with ReVolt, while only the server-issued UUIDv4 `activation_id` is placed in Google-visible `custom_data`.

`AppConfig.h13ActivationEnabled` defaults to `false`. Enabling it is allowed only after the matching backend activation-intent state/API, dedicated verified Google SSV callback, nginx admission and production SSV configuration have been accepted.

The H13 client persists private ownership before preparation network I/O. Prepare, abandonment recovery and promotion are serialized locally. Abandonment converges activation-intent cancellation before authenticated exact-secret session stop. Promotion polls session status with the private secret and persists that exact secret as active possession only after authenticated active status is proven.

If active possession is already the same private secret while the H13 pending marker remains, the client treats that as an interrupted local marker cleanup and removes only the stale marker. It must not revoke the live generation. Debug `signature=test` stays on the legacy compatibility path because H13 forbids that bypass. Support rewards are unchanged.
