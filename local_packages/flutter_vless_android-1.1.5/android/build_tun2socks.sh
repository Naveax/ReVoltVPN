#!/bin/bash
set -euo pipefail

TUN2SOCKS_REPO="https://github.com/xjasonlyu/tun2socks"
: "${TUN2SOCKS_COMMIT:?Set TUN2SOCKS_COMMIT to the reviewed immutable 40-hex source commit}"
[[ "$TUN2SOCKS_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "TUN2SOCKS_COMMIT must be a 40-hex commit"; exit 1; }
TARGET_DIR="${TARGET_DIR:-../../../android_runtime/xray_android/src/main/jniLibs}"
NDK_PATH="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/28.2.13676358}"

[ -d "$NDK_PATH" ] || { echo "NDK not found at $NDK_PATH"; exit 1; }
case "$(uname -s)" in
  Darwin) TOOLCHAIN="${NDK_PATH}/toolchains/llvm/prebuilt/darwin-x86_64" ;;
  Linux) TOOLCHAIN="${NDK_PATH}/toolchains/llvm/prebuilt/linux-x86_64" ;;
  *) echo "Unsupported host OS $(uname -s)"; exit 1 ;;
esac
[ -d "$TOOLCHAIN" ] || { echo "NDK toolchain not found at $TOOLCHAIN"; exit 1; }

if [ ! -d tun2socks-go/.git ]; then
  git clone --no-checkout "$TUN2SOCKS_REPO" tun2socks-go
fi
(
  cd tun2socks-go
  git fetch --force origin "$TUN2SOCKS_COMMIT"
  git checkout --detach "$TUN2SOCKS_COMMIT"
  test "$(git rev-parse HEAD)" = "$TUN2SOCKS_COMMIT"
  go mod verify
)

build_tun2socks() {
  local ARCH_NAME=$1 GO_ARCH=$2 GO_ARM=$3 ANDROID_TARGET=$4
  local OUTPUT_DIR="${TARGET_DIR}/${ARCH_NAME}"
  mkdir -p "$OUTPUT_DIR"
  export CGO_ENABLED=1 GOOS=android GOARCH="$GO_ARCH" GOARM="$GO_ARM"
  export CC="${TOOLCHAIN}/bin/${ANDROID_TARGET}-clang"
  export CXX="${TOOLCHAIN}/bin/${ANDROID_TARGET}-clang++"
  [ -f "$CC" ] || { echo "Compiler not found at $CC"; return 1; }
  (
    cd tun2socks-go
    go build -v -trimpath \
      -ldflags "-s -w -buildid= -linkmode=external -extldflags '-Wl,-z,max-page-size=16384'" \
      -buildmode=pie \
      -o "../${OUTPUT_DIR}/libtun2socks.so" .
  )
  sha256sum "${OUTPUT_DIR}/libtun2socks.so"
  if [ -x "${TOOLCHAIN}/bin/llvm-readelf" ]; then
    ALIGN=$("${TOOLCHAIN}/bin/llvm-readelf" -l "${OUTPUT_DIR}/libtun2socks.so" | awk '/LOAD/{print $NF; exit}')
    test "$ALIGN" = 0x4000 || { echo "Invalid page alignment: $ALIGN"; return 1; }
  fi
}

[ "${TUN2SOCKS_BUILD_ARM64:-1}" = 1 ] && build_tun2socks arm64-v8a arm64 "" aarch64-linux-android21
[ "${TUN2SOCKS_BUILD_ARMV7:-1}" = 1 ] && build_tun2socks armeabi-v7a arm 7 armv7a-linux-androideabi21
[ "${TUN2SOCKS_BUILD_X86:-1}" = 1 ] && build_tun2socks x86 386 "" i686-linux-android21
[ "${TUN2SOCKS_BUILD_X86_64:-1}" = 1 ] && build_tun2socks x86_64 amd64 "" x86_64-linux-android21
