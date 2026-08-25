#!/usr/bin/env bash
set -euo pipefail

# Hyperdisplay 是菜单栏 App：必须运行打包后的 .app，不能直接运行 SwiftPM 二进制。
# 该入口只在确认系统 ColorSync 空闲时用于开发/真机测试。
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS_DIR="$ROOT_DIR/macos"
APP_BUNDLE="$MACOS_DIR/build/Hyperdisplay.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Hyperdisplay"

stop_host() {
  local pids
  pids="$(pgrep -f "$APP_BINARY" || true)"
  if [[ -n "$pids" ]]; then
    # Host 对 SIGTERM 显式 destroy 全部虚拟屏；不要用 SIGKILL。
    kill -TERM $pids
    sleep 1
  fi
}

build_app() {
  (cd "$MACOS_DIR" && ./Scripts/make-app.sh)
}

launch_app() {
  /usr/bin/open "$APP_BUNDLE"
}

case "$MODE" in
  run)
    stop_host
    build_app
    launch_app
    ;;
  --logs|logs)
    stop_host
    build_app
    launch_app
    /usr/bin/log stream --style compact --predicate 'process == "Hyperdisplay"'
    ;;
  --telemetry|telemetry)
    stop_host
    build_app
    launch_app
    /usr/bin/log stream --style compact --predicate 'eventMessage CONTAINS[c] "hyperdisplay"'
    ;;
  --verify|verify)
    stop_host
    build_app
    launch_app
    sleep 1
    pgrep -f "$APP_BINARY" >/dev/null
    ;;
  --debug|debug)
    stop_host
    build_app
    lldb -- "$APP_BINARY"
    ;;
  *)
    echo "usage: $0 [run|--logs|--telemetry|--verify|--debug]" >&2
    exit 2
    ;;
esac
