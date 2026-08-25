#!/bin/bash
# 生成可公开下载的两个正式安装包。此脚本从不生成/保存密钥，并拒绝未签名或未公证产物。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DIR="$ROOT/android"
MACOS_DIR="$ROOT/macos"
APP="$MACOS_DIR/build/Hyperdisplay.app"
NOTARY_PROFILE="${HYPERDISPLAY_NOTARY_PROFILE:-}"

fail() { echo "release error: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }

[[ -n "$NOTARY_PROFILE" ]] || fail "set HYPERDISPLAY_NOTARY_PROFILE to a notarytool keychain profile"
require codesign
require ditto
require hdiutil
require shasum
require xcrun

# 正式 APK 的密钥默认只存在本机 Keychain，不把密码写入仓库或 properties 文件。
# 用户也可用四个 HYPERDISPLAY_ANDROID_* 环境变量覆盖，便于 CI 注入 secret。
if [[ -z "${HYPERDISPLAY_ANDROID_KEYSTORE:-}" ]]; then
    export HYPERDISPLAY_ANDROID_KEYSTORE="/Users/xuyingzhou/Library/Application Support/Hyperdisplay/keys/hyperdisplay-release.jks"
fi
[[ -f "$HYPERDISPLAY_ANDROID_KEYSTORE" ]] || fail "Android release keystore not found"
if [[ -z "${HYPERDISPLAY_ANDROID_STORE_PASSWORD:-}" ]]; then
    export HYPERDISPLAY_ANDROID_STORE_PASSWORD="$(security find-generic-password -a hyperdisplay-release -s com.hyperdisplay.android.store-password -w)"
fi
if [[ -z "${HYPERDISPLAY_ANDROID_KEY_PASSWORD:-}" ]]; then
    export HYPERDISPLAY_ANDROID_KEY_PASSWORD="$(security find-generic-password -a hyperdisplay-release -s com.hyperdisplay.android.key-password -w)"
fi
export HYPERDISPLAY_ANDROID_KEY_ALIAS="${HYPERDISPLAY_ANDROID_KEY_ALIAS:-hyperdisplay}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "$VERSION" ]]; then
    "$MACOS_DIR/Scripts/make-app.sh"
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
fi
DIST="$ROOT/dist/v$VERSION"
mkdir -p "$DIST"
[[ ! -e "$DIST/Hyperdisplay-macOS-arm64.dmg" ]] || fail "refusing to overwrite existing Mac DMG"

# 重建后重新读取版本；并确保是 Developer ID + hardened runtime，而不是 ad-hoc。
"$MACOS_DIR/Scripts/make-app.sh"
# Do not pipe `codesign` into `grep -q` under `pipefail`: grep exits immediately
# on a match and can make codesign report SIGPIPE as a false signing failure.
SIGNING_INFO="$(codesign -dvv "$APP" 2>&1)"
[[ "$SIGNING_INFO" == *"Authority=Developer ID Application:"* ]] || fail "Mac app is not Developer ID signed"
[[ "$SIGNING_INFO" == *"runtime"* ]] || fail "Mac app is missing hardened runtime"

MAC_ZIP="$DIST/Hyperdisplay-macOS-arm64.zip"
ditto -c -k --keepParent "$APP" "$MAC_ZIP"
xcrun notarytool submit "$MAC_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv "$APP"
hdiutil create -volname Hyperdisplay -srcfolder "$APP" -ov -format UDZO "$DIST/Hyperdisplay-macOS-arm64.dmg"

pushd "$ANDROID_DIR" >/dev/null
./gradlew :app:assembleRelease
APK="app/build/outputs/apk/release/app-release.apk"
[[ -f "$APK" ]] || fail "signed release APK was not produced"
APKSIGNER="$(command -v apksigner || true)"
if [[ -z "$APKSIGNER" ]]; then
    SDK_ROOT="$(sed -n 's|sdk.dir=||p' local.properties)"
    APKSIGNER="$(find "$SDK_ROOT/build-tools" -name apksigner -type f 2>/dev/null | sort -V | tail -n 1)"
fi
[[ -n "$APKSIGNER" ]] || fail "missing apksigner (install Android SDK build-tools)"
"$APKSIGNER" verify --verbose --print-certs "$APK"
cp "$APK" "$DIST/Hyperdisplay-android.apk"
popd >/dev/null

(cd "$DIST" && shasum -a 256 Hyperdisplay-macOS-arm64.dmg Hyperdisplay-android.apk > SHA256SUMS)
echo "Release artifacts ready: $DIST"
