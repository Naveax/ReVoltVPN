# ReVoltVPN 3.3.1 review

This branch reviews the 3.3.1 client independently from the upstream PR. `release/3.3.1` / upstream PR #2 is intentionally untouched.

## Confirmed issues fixed on this branch

- Restored health probing to idle-only behavior. A connected/connecting/disconnecting VPN no longer performs the 30-second public health request, and health polling stops while the app is backgrounded.
- Removed the Android `ConnectivityManager` telemetry EventChannel and Dart `NetworkMonitor`. The data was only exposed as diagnostics and did not drive Extreme recovery.
- Removed unused VPN diagnostic/public state including transport/validation telemetry, latency counters, fallback count, recovery reason, routing-description and synthetic `Active: server` presentation.
- Renamed `no_ass_migration_test.dart` to `ass_to_socks5_migration_test.dart`; the test verifies migration rather than removal.
- Removed `lib/components/notification.dart`. `VpnNotificationManager` had no callers and duplicated the native foreground notification path that the app already replaced in 3.2.0.
- Reduced `HapticSettings` to the only feedback path that has callers in 3.3.1 (`tap`). The unused `selection`/`success` API and enum branches were removed.

## Intentionally kept

- The `10807` / `10808` values inside the secure SOCKS regression fixture are not production listeners. They model stale legacy no-auth SOCKS/HTTP inbounds and verify that `SecureSocksSession` removes them.
- The authenticated random-port SOCKS session, app routing, Extreme Xray-disconnect recovery, wall-clock session reconciliation and native ongoing notification behavior are functional paths, not dead telemetry.
- `CryptoService` UUID validation is small and actively protects the device-id query value from corrupted storage.

## Further cleanup candidates

These are real cleanup opportunities but are kept separate from the first low-risk pass because they touch build/runtime behavior or unrelated existing features.

1. **Fold `patch_flutter_vless_secure_socks_scope_fix.dart` into the primary secure SOCKS patcher.** The scope-fix script explicitly exists because the primary patcher can miss the Xray process capture. Keeping a patch for a patch adds about 150 lines and another Gradle task.
2. **Remove the unused `Updater.check(BuildContext)` wrapper.** Current sidebar code uses `checkWithHandles(...)` directly.
3. **Tighten `LocalSocksTester`.** Current 3.3.1 callers always pass the active random port plus username/password; the optional no-auth compatibility branch and default `10807` argument are not used by production code.
4. **Audit old direct dependencies.** `cupertino_icons`, `google_fonts`, `path_provider`, and after removal of the duplicate notification manager `flutter_local_notifications` have no application-code references in the current tree. Removing them should be done together with a regenerated `pubspec.lock`.
5. **Support-reward persistence is feature code, not dead code.** It is used by `SupportButton` and `SessionTimer`, but it is unrelated to the routing/runtime release and can be split out if a smaller 3.3.1 feature surface is preferred.

## Validation strategy

The equivalent product changes are validated on `stage/pr2-dead-code-cleanup`, which contains the temporary CI workflow. The clean review branch does not contain that workflow.
