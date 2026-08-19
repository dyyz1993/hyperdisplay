#!/bin/bash
# USB 有线模式一键启动：起桥接 + 配 adb reverse。
# 前置：平板用 Type-C 连着 Mac（adb 可见）。之后平板 app 点「USB 连线」即可。
set -euo pipefail

ADB="${ADB:-/Users/xuyingzhou/Library/Android/sdk/platform-tools/adb}"
TCP_PORT=5280
UDP_PORT=5277

# 1) 桥接进程（没起才起）
if ! lsof -nP -iTCP:$TCP_PORT 2>/dev/null | grep -q LISTEN; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    nohup python3 "$SCRIPT_DIR/usb-tunnel.py" $TCP_PORT $UDP_PORT >/tmp/usb-tunnel.log 2>&1 &
    sleep 1
    echo "usb-tunnel started (pid $!, log /tmp/usb-tunnel.log)"
else
    echo "usb-tunnel already running"
fi

# 2) adb reverse（每台在线设备都配）
"$ADB" devices | awk '/device$/{print $1}' | while read -r SN; do
    "$ADB" -s "$SN" reverse tcp:$TCP_PORT tcp:$TCP_PORT >/dev/null && echo "reverse OK on $SN"
done

echo "完成：平板 app → 「USB 连线」"
