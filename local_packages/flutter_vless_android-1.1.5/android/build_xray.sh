#!/bin/bash
set -euo pipefail

XRAY_REPO="https://github.com/XTLS/Xray-core"
XRAY_VERSION="${XRAY_VERSION:-v26.7.11}"
XRAY_COMMIT="${XRAY_COMMIT:-50231eaff98ccc31b5cbd247a721c16e97fe5ec1}"
TARGET_DIR="${TARGET_DIR:-../../../android_runtime/xray_android/src/main/jniLibs}"
NDK_PATH="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/28.2.13676358}"

[[ "$XRAY_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "XRAY_COMMIT must be a 40-hex commit"; exit 1; }
[ -d "$NDK_PATH" ] || { echo "NDK not found at $NDK_PATH"; exit 1; }
case "$(uname -s)" in
  Darwin) TOOLCHAIN="${NDK_PATH}/toolchains/llvm/prebuilt/darwin-x86_64" ;;
  Linux) TOOLCHAIN="${NDK_PATH}/toolchains/llvm/prebuilt/linux-x86_64" ;;
  *) echo "Unsupported host OS $(uname -s)"; exit 1 ;;
esac
[ -d "$TOOLCHAIN" ] || { echo "NDK toolchain not found at $TOOLCHAIN"; exit 1; }

if [ ! -d Xray-core/.git ]; then
  git clone --no-checkout "$XRAY_REPO" Xray-core
fi
(
  cd Xray-core
  git fetch --tags --force origin
  git checkout --detach "$XRAY_COMMIT"
  test "$(git rev-parse HEAD)" = "$XRAY_COMMIT"
  if git rev-parse -q --verify "refs/tags/$XRAY_VERSION" >/dev/null; then
    test "$(git rev-list -n1 "$XRAY_VERSION")" = "$XRAY_COMMIT" || {
      echo "$XRAY_VERSION no longer resolves to pinned commit $XRAY_COMMIT"
      exit 1
    }
  fi
  go mod verify
)

build_xray() {
  local ARCH_NAME=$1 GO_ARCH=$2 GO_ARM=$3 ANDROID_TARGET=$4
  local OUTPUT_DIR="${TARGET_DIR}/${ARCH_NAME}"
  mkdir -p "$OUTPUT_DIR"
  export CGO_ENABLED=1 GOOS=android GOARCH="$GO_ARCH" GOARM="$GO_ARM"
  export CC="${TOOLCHAIN}/bin/${ANDROID_TARGET}-clang"
  export CXX="${TOOLCHAIN}/bin/${ANDROID_TARGET}-clang++"
  export LDFLAGS="-Wl,-z,max-page-size=16384"
  [ -f "$CC" ] || { echo "Compiler not found at $CC"; return 1; }
  (
    cd Xray-core
    go build -v -trimpath -buildvcs=false \
      -gcflags "all=-l=4" \
      -ldflags "-X github.com/xtls/xray-core/core.build=${XRAY_VERSION} -s -w -buildid= -checklinkname=0 -linkmode=external -extldflags=${LDFLAGS}" \
      -buildmode=pie \
      -o "../${OUTPUT_DIR}/libxray.so" ./main
  )
  sha256sum "${OUTPUT_DIR}/libxray.so"
}

[ "${XRAY_BUILD_ARM64:-1}" = 1 ] && build_xray arm64-v8a arm64 "" aarch64-linux-android21
[ "${XRAY_BUILD_ARMV7:-1}" = 1 ] && build_xray armeabi-v7a arm 7 armv7a-linux-androideabi21
[ "${XRAY_BUILD_X86:-1}" = 1 ] && build_xray x86 386 "" i686-linux-android21
[ "${XRAY_BUILD_X86_64:-1}" = 1 ] && build_xray x86_64 amd64 "" x86_64-linux-android21
