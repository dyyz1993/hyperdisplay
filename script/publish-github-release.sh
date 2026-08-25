#!/bin/bash
# 上传已验证的正式安装包。默认仓库是官方公开发行仓库；可用环境变量覆盖给 fork。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPOSITORY="${HYPERDISPLAY_GITHUB_REPOSITORY:-dyyz1993/hyperdisplay}"
VERSION="${1:?usage: script/publish-github-release.sh <version，例如 0.1.0>}"
TAG="v${VERSION#v}"
DIST="$ROOT/dist/$TAG"

command -v gh >/dev/null 2>&1 || { echo "release error: missing gh CLI" >&2; exit 1; }
[[ -f "$DIST/Hyperdisplay-macOS-arm64.dmg" ]] || { echo "release error: missing Mac DMG; run package-release.sh first" >&2; exit 1; }
[[ -f "$DIST/Hyperdisplay-android.apk" ]] || { echo "release error: missing Android APK; run package-release.sh first" >&2; exit 1; }
[[ -f "$DIST/SHA256SUMS" ]] || { echo "release error: missing SHA256SUMS" >&2; exit 1; }

gh release create "$TAG" \
  "$DIST/Hyperdisplay-macOS-arm64.dmg#Hyperdisplay-macOS-arm64.dmg" \
  "$DIST/Hyperdisplay-android.apk#Hyperdisplay-android.apk" \
  "$DIST/SHA256SUMS#SHA256SUMS" \
  --repo "$REPOSITORY" \
  --title "Hyperdisplay $TAG" \
  --generate-notes
