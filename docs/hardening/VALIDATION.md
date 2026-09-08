# Validation record — 2026-09-08

Base: 6d8a923475ce66a511b6f7d1c99fd65ec72bcacc.

## Executed

- Fresh clone status clean; initial diff empty; repository AGENTS.md search found none.
- GitHub branch/PR/issue/release metadata read. Upstream PR #7 remains open.
- Native ingress producer, runtime consumer and existing tests read together.
- Repo-wide delay API call search: only internal obsolete subsystem; plugin exposes no method cases for it.
- Current IPv4/IPv6 routes, proxyOnly branch and always-on manifest/service startup paths inspected.
- TCP-only local readiness scope inspected; this is not a UDP failure diagnosis.
- `git diff --check`: passed.
- Protected files byte-compared to base: AdManager, consent manager, Hivemind service, support button, example config, pubspec/lock and app Gradle unchanged.
- Static post-edit checks: native noauth literal removed, delay entrypoints removed, exact-one-ingress guard present. These checks do not replace Kotlin execution.
- Android/Dart/GitHub primary documentation consulted; links in PLAN.md.

## Added but NOT executed locally

- Existing three XrayCoreManager tests retained.
- Two new Kotlin test methods cover missing/empty/extra ingress and eleven malformed ingress variants, including type mismatches and empty/additional accounts.
- Two Dart NetworkSnapshot tests cover malformed metadata and preservation of valid metadata.
- CI native task: `./gradlew :flutter_vless_android:testDebugUnitTest --no-daemon`.

## Environment blockers

- Flutter and Dart executables unavailable.
- Java 17 is present.
- `./android/gradlew --version` attempted; Gradle distribution download failed with `java.net.SocketException: Network is unreachable`.
- Consequently Kotlin/Dart tests, analyze, lint and APK build have NOT passed in this environment.
- No Android device/emulator runtime acceptance performed.
- No production backend authorization, APK signature or build attestation verification performed.

## CI discipline

Branch push is configured to run Android CI once for this branch's new SHA. Do not manually rerun while the same SHA/workflow/input is queued, waiting or running. Read the existing run ID and inspect its result. The other active hardening branch is independent and must not be overwritten.

Do not mark H01–H04 accepted until native/Dart test output and build evidence exist. All other packages remain explicitly open in PLAN.md.
