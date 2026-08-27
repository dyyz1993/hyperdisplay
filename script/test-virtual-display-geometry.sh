#!/usr/bin/env bash
set -euo pipefail

# 纯尺寸契约回归：不启动 Host、不创建 CGVirtualDisplay。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hyperdisplay-display-geometry.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

swiftc "$ROOT_DIR/macos/Sources/HyperdisplayHost/VirtualDisplayGeometry.swift" \
       "$ROOT_DIR/macos/Tests/VirtualDisplayGeometryTests.swift" \
       -o "$TMP_DIR/virtual-display-geometry-tests"
"$TMP_DIR/virtual-display-geometry-tests"
