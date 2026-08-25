#!/bin/bash
# 打包 GitHub 直发的 Android 正式 APK。密钥密码只从 Keychain 或显式环境变量读取。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DIR="$ROOT/android"
KEYSTORE_DEFAULT="/Users/xuyingzhou/Library/Application Support/Hyperdisplay/keys/hyperdisplay-release.jks"
KEYSTORE="${HYPERDISPLAY_ANDROID_KEYSTORE:-$KEYSTORE_DEFAULT}"

fail() { echo "android release error: $*" >&2; exit 1; }
[[ -f "$KEYSTORE" ]] || fail "release keystore missing: $KEYSTORE"
command -v shasum >/dev/null || fail "missing shasum"

export HYPERDISPLAY_ANDROID_KEYSTORE="$KEYSTORE"
export HYPERDISPLAY_ANDROID_KEY_ALIAS="${HYPERDISPLAY_ANDROID_KEY_ALIAS:-hyperdisplay}"
if [[ -z "${HYPERDISPLAY_ANDROID_STORE_PASSWORD:-}" ]]; then
    export HYPERDISPLAY_ANDROID_STORE_PASSWORD="$(security find-generic-password -a hyperdisplay-release -s com.hyperdisplay.android.store-password -w)"
fi
if [[ -z "${HYPERDISPLAY_ANDROID_KEY_PASSWORD:-}" ]]; then
    export HYPERDISPLAY_ANDROID_KEY_PASSWORD="$(security find-generic-password -a hyperdisplay-release -s com.hyperdisplay.android.key-password -w)"
fi

VERSION="$(sed -n 's/.*versionName = "\([^"]*\)".*/\1/p' "$ANDROID_DIR/app/build.gradle.kts" | head -n 1)"
[[ -n "$VERSION" ]] || fail "could not read Android versionName"
DIST="$ROOT/dist/v$VERSION"
[[ ! -e "$DIST" ]] || fail "refusing to overwrite existing $DIST"
mkdir -p "$DIST"

pushd "$ANDROID_DIR" >/dev/null
./gradlew :app:assembleRelease
APK="app/build/outputs/apk/release/app-release.apk"
[[ -f "$APK" ]] || fail "signed release APK was not produced"
APKSIGNER="$(find "$(sed -n 's|sdk.dir=||p' local.properties)"/build-tools -name apksigner -type f 2>/dev/null | sort -V | tail -n 1)"
[[ -n "$APKSIGNER" ]] || fail "missing apksigner in Android SDK build-tools"
"$APKSIGNER" verify --verbose --print-certs "$APK"
cp "$APK" "$DIST/Hyperdisplay-android.apk"
popd >/dev/null

(cd "$DIST" && shasum -a 256 Hyperdisplay-android.apk > SHA256SUMS)
echo "Android release artifacts ready: $DIST"
