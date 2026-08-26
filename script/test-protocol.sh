#!/usr/bin/env bash
set -euo pipefail

# 纯 Wire 协议回归测试：不启动 App、不连接 UDP、更不会创建 CGVirtualDisplay。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hyperdisplay-protocol.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

swiftc "$ROOT_DIR/macos/Sources/HyperdisplayHost/Protocol.swift" \
       "$ROOT_DIR/macos/Sources/HyperdisplayHost/DeviceTopology.swift" \
       "$ROOT_DIR/macos/Tests/ProtocolContractTests.swift" \
       -o "$TMP_DIR/protocol-contract-tests"
"$TMP_DIR/protocol-contract-tests"
