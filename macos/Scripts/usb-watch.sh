#!/bin/bash
# adb reverse 守护：reverse 注册不随 USB 重插存活，本脚本补注册。
# 注意：必须先查再补——无条件重复注册会掐断正在使用的隧道连接
# （曾导致隧道内丢帧 90%、会话被 host 剪除）。
ADB="${ADB:-/Users/xuyingzhou/Library/Android/sdk/platform-tools/adb}"
TCP_PORT=5280

while true; do
    for SN in $("$ADB" devices 2>/dev/null | awk '/device$/{print $1}'); do
        if ! "$ADB" -s "$SN" reverse --list 2>/dev/null | grep -q "tcp:$TCP_PORT"; then
            "$ADB" -s "$SN" reverse tcp:$TCP_PORT tcp:$TCP_PORT >/dev/null 2>&1                 && echo "$(date '+%H:%M:%S') re-registered reverse on $SN"
        fi
    done
    sleep 3
done
