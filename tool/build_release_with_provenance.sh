#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  printf 'release provenance error: %s\n' "$*" >&2
  exit 1
}

command -v git >/dev/null || fail 'git is required'
command -v flutter >/dev/null || fail 'flutter is required'
command -v sha256sum >/dev/null || fail 'sha256sum is required'

[[ -n "${REVOLT_APP_CONFIG_SHA256:-}" ]] || \
  fail 'REVOLT_APP_CONFIG_SHA256 must be set for a production release'
[[ "$REVOLT_APP_CONFIG_SHA256" =~ ^[0-9a-f]{64}$ ]] || \
  fail 'REVOLT_APP_CONFIG_SHA256 must be 64 lowercase hex characters'

[[ -f lib/logic/app_config.dart ]] || fail 'lib/logic/app_config.dart is missing'
[[ -f android/key.properties ]] || fail 'android/key.properties is missing'
[[ -f pubspec.lock ]] || fail 'pubspec.lock is missing'

# Provenance is meaningless if tracked inputs differ from the source commit.
git diff --quiet -- || fail 'tracked working tree has unstaged changes'
git diff --cached --quiet -- || fail 'tracked working tree has staged changes'
[[ -z "$(git ls-files --others --exclude-standard -- ':!lib/logic/app_config.dart' ':!android/key.properties' ':!android/admob.properties')" ]] || \
  fail 'untracked files are present; release from a clean checkout'

SOURCE_COMMIT="$(git rev-parse HEAD)"
SOURCE_TREE="$(git rev-parse HEAD^{tree})"
SOURCE_REF="$(git symbolic-ref --quiet --short HEAD || printf 'detached')"
VERSION="$(awk '/^version:/ {print $2; exit}' pubspec.yaml)"
[[ -n "$VERSION" ]] || fail 'could not read pubspec version'

CONFIG_SHA="$(sha256sum lib/logic/app_config.dart | awk '{print $1}')"
[[ "$CONFIG_SHA" == "$REVOLT_APP_CONFIG_SHA256" ]] || \
  fail "app_config SHA-256 mismatch: expected $REVOLT_APP_CONFIG_SHA256, got $CONFIG_SHA"

# Gradle performs the same production config check again through preReleaseBuild.
flutter pub get --enforce-lockfile
flutter analyze
flutter test
(
  cd android
  ./gradlew :flutter_vless_android:testDebugUnitTest :app:lintRelease --no-daemon
)
flutter build apk --release

APK='build/app/outputs/flutter-apk/app-release.apk'
[[ -f "$APK" ]] || fail 'release APK was not produced'

ANDROID_SDK_ROOT_RESOLVED="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
[[ -n "$ANDROID_SDK_ROOT_RESOLVED" ]] || fail 'ANDROID_SDK_ROOT or ANDROID_HOME is required'

APKSIGNER="$(find "$ANDROID_SDK_ROOT_RESOLVED/build-tools" -mindepth 2 -maxdepth 2 -type f \( -name apksigner -o -name apksigner.bat \) -print 2>/dev/null | sort -V | tail -n1)"
[[ -n "$APKSIGNER" && -f "$APKSIGNER" ]] || fail 'apksigner was not found in Android build-tools'

SIGNING_OUTPUT="$($APKSIGNER verify --verbose --print-certs "$APK")"
grep -q 'Verifies' <<<"$SIGNING_OUTPUT" || fail 'APK signature verification failed'
CERT_SHA="$(sed -n 's/.*Signer #1 certificate SHA-256 digest: //p' <<<"$SIGNING_OUTPUT" | head -n1 | tr -d ':' | tr 'A-F' 'a-f')"
[[ "$CERT_SHA" =~ ^[0-9a-f]{64}$ ]] || fail 'could not extract signing certificate SHA-256'

mkdir -p build/provenance
OUT="build/provenance/revoltvpn-${VERSION}+${SOURCE_COMMIT:0:12}.env"
APK_SHA="$(sha256sum "$APK" | awk '{print $1}')"
LOCK_SHA="$(sha256sum pubspec.lock | awk '{print $1}')"
WRAPPER_SHA="$(sha256sum android/gradle/wrapper/gradle-wrapper.jar | awk '{print $1}')"
RUNTIME_TREE="$(git rev-parse HEAD:local_packages/flutter_vless_android-1.1.5)"
FLUTTER_VERSION="$(flutter --version --machine | python3 -c 'import json,sys; print(json.load(sys.stdin)["frameworkVersion"])')"
JAVA_VERSION="$(java -version 2>&1 | head -n1 | tr ' ' '_')"
BUILD_EPOCH="$(date -u +%s)"

cat > "$OUT" <<EOF
provenance_format=revolt-release-v2
source_repository=https://github.com/esefxdz/ReVoltVPN
source_ref=$SOURCE_REF
source_commit=$SOURCE_COMMIT
source_tree=$SOURCE_TREE
version=$VERSION
app_config_sha256=$CONFIG_SHA
pubspec_lock_sha256=$LOCK_SHA
gradle_wrapper_sha256=$WRAPPER_SHA
vendored_runtime_tree=$RUNTIME_TREE
flutter_version=$FLUTTER_VERSION
java_version=$JAVA_VERSION
apk_path=$APK
apk_sha256=$APK_SHA
signing_certificate_sha256=$CERT_SHA
build_epoch_utc=$BUILD_EPOCH
EOF

# A detached digest makes accidental provenance-file editing detectable.
sha256sum "$OUT" > "$OUT.sha256"

printf 'Release APK: %s\n' "$APK"
printf 'APK SHA-256: %s\n' "$APK_SHA"
printf 'Signing cert SHA-256: %s\n' "$CERT_SHA"
printf 'Source commit: %s\n' "$SOURCE_COMMIT"
printf 'Provenance: %s\n' "$OUT"
printf 'Provenance SHA-256: %s\n' "$(awk '{print $1}' "$OUT.sha256")"
