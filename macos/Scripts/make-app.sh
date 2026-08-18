#!/bin/bash
# 组装 Hyperdisplay.app：release 二进制 + Info.plist + ad-hoc 签名。
# TCC 权限（屏幕录制/辅助功能）按 bundle id 记账，必须以 .app 方式运行。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Hyperdisplay.app"

swift build -c release --package-path "$ROOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/.build/release/HyperdisplayHost" "$APP/Contents/MacOS/Hyperdisplay"

cat > "$APP/Contents/Info.plist" <<'PLIST'
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
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1

echo "Built $APP"
echo "Run: open $APP   （首次需在系统设置授权 屏幕录制 + 辅助功能）"
