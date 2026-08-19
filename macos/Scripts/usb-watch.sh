#!/bin/bash
# adb reverse 守护：reverse 注册不随 USB 重插存活，本脚本每 3s 为所有在线设备
# 幂等补注册一次（同参数 reverse 会覆盖，无副作用）。
# 用法: nohup macos/Scripts/usb-watch.sh >/tmp/usb-watch.log 2>&1 &
ADB="${ADB:-/Users/xuyingzhou/Library/Android/sdk/platform-tools/adb}"
TCP_PORT=5280

while true; do
    for SN in $("$ADB" devices 2>/dev/null | awk '/device$/{print $1}'); do
        "$ADB" -s "$SN" reverse tcp:$TCP_PORT tcp:$TCP_PORT >/dev/null 2>&1 || true
    done
    sleep 3
done
