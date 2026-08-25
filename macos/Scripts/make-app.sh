#!/bin/bash
# 组装 Hyperdisplay.app：release 二进制 + Info.plist + Developer ID（可用时）签名。
# 屏幕录制 TCC 权限按 bundle id 记账，必须以 .app 方式运行。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Hyperdisplay.app"
ICON="$ROOT/Resources/Hyperdisplay.icns"
MENUBAR_ICON="$ROOT/Resources/HyperdisplayMenuBar.png"
# Release 页是安装 Android 客户端的唯一稳定入口；每个版本的 APK 名称可变，
# 但 `/releases/latest` 始终指向当前正式版本。fork 可在打包时覆盖此 URL。
RELEASE_URL="${HYPERDISPLAY_RELEASE_URL:-https://github.com/dyyz1993/hyperdisplay/releases/latest}"

if [[ ! -f "$ICON" || ! -f "$MENUBAR_ICON" ]]; then
    "$ROOT/Scripts/generate-icon.sh"
fi

swift build -c release --package-path "$ROOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/HyperdisplayHost" "$APP/Contents/MacOS/Hyperdisplay"
cp "$ICON" "$APP/Contents/Resources/Hyperdisplay.icns"
cp "$MENUBAR_ICON" "$APP/Contents/Resources/HyperdisplayMenuBar.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.hyperdisplay.host</string>
    <key>CFBundleName</key>
    <string>Hyperdisplay</string>
    <key>CFBundleDisplayName</key>
    <string>Hyperdisplay</string>
    <key>CFBundleExecutable</key>
    <string>Hyperdisplay</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>Hyperdisplay</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License. CGVirtualDisplay bindings derived from DeskPad (MIT).</string>
    <key>HyperdisplayAndroidReleaseURL</key>
    <string>${RELEASE_URL}</string>
</dict>
</plist>
PLIST

SIGNING_IDENTITY="${HYPERDISPLAY_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n 1)"
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
    codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP"
    echo "Signed with Developer ID: $SIGNING_IDENTITY"
else
    # 没有 Developer ID 的开发机仍可本地调试；分发版不可使用此签名。
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc (development only; set HYPERDISPLAY_SIGNING_IDENTITY for distribution)"
fi

echo "Built $APP"
echo "Run: open $APP   （首次授权屏幕录制）"
