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

[[ -f "$ANDROID_DIR/keystore.properties" ]] || fail "missing android/keystore.properties (copy the .example; never commit it)"
[[ -n "$NOTARY_PROFILE" ]] || fail "set HYPERDISPLAY_NOTARY_PROFILE to a notarytool keychain profile"
require codesign
require ditto
require hdiutil
require shasum
require xcrun

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "$VERSION" ]]; then
    "$MACOS_DIR/Scripts/make-app.sh"
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
fi
DIST="$ROOT/dist/v$VERSION"
[[ ! -e "$DIST" ]] || fail "refusing to overwrite existing $DIST"
mkdir -p "$DIST"

# 重建后重新读取版本；并确保是 Developer ID + hardened runtime，而不是 ad-hoc。
"$MACOS_DIR/Scripts/make-app.sh"
codesign -dvv "$APP" 2>&1 | grep -q 'Authority=Developer ID Application:' || fail "Mac app is not Developer ID signed"
codesign -dvv "$APP" 2>&1 | grep -q 'flags=.*runtime' || fail "Mac app is missing hardened runtime"

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
[[ -n "$APKSIGNER" ]] || fail "missing apksigner (install Android SDK build-tools)"
"$APKSIGNER" verify --verbose --print-certs "$APK"
cp "$APK" "$DIST/Hyperdisplay-android.apk"
popd >/dev/null

(cd "$DIST" && shasum -a 256 Hyperdisplay-macOS-arm64.dmg Hyperdisplay-android.apk > SHA256SUMS)
echo "Release artifacts ready: $DIST"
