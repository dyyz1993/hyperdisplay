#!/usr/bin/env bash
set -euo pipefail

# 纯发送队列回归：不启动 Host、不创建 CGVirtualDisplay、不发送任何网络包。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hyperdisplay-route-queue.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

swiftc "$ROOT_DIR/macos/Sources/HyperdisplayHost/VideoRouteQueue.swift" \
       "$ROOT_DIR/macos/Tests/VideoRouteQueueTests.swift" \
       -o "$TMP_DIR/video-route-queue-tests"
"$TMP_DIR/video-route-queue-tests"
