#!/usr/bin/env bash
set -euo pipefail

# 纯拓扑退避回归：不启动 Host、不建 CGVirtualDisplay、不访问网络。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hyperdisplay-topology-retry.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

swiftc "$ROOT_DIR/macos/Sources/HyperdisplayHost/TopologyRetryPolicy.swift" \
       "$ROOT_DIR/macos/Tests/TopologyRetryPolicyTests.swift" \
       -o "$TMP_DIR/topology-retry-tests"
"$TMP_DIR/topology-retry-tests"
