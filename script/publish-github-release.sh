#!/bin/bash
# 上传已验证的正式安装包。默认仓库是官方公开发行仓库；可用环境变量覆盖给 fork。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPOSITORY="${HYPERDISPLAY_GITHUB_REPOSITORY:-dyyz1993/hyperdisplay}"
VERSION="${1:?usage: script/publish-github-release.sh <version，例如 0.1.0> [--android-only]}"
MODE="${2:-}"
TAG="v${VERSION#v}"
DIST="$ROOT/dist/$TAG"

command -v gh >/dev/null 2>&1 || { echo "release error: missing gh CLI" >&2; exit 1; }
[[ -f "$DIST/Hyperdisplay-android.apk" ]] || { echo "release error: missing Android APK; run package-release.sh first" >&2; exit 1; }
[[ -f "$DIST/SHA256SUMS" ]] || { echo "release error: missing SHA256SUMS" >&2; exit 1; }

ASSETS=(
  "$DIST/Hyperdisplay-android.apk#Hyperdisplay-android.apk"
  "$DIST/SHA256SUMS#SHA256SUMS"
)
NOTES=()
if [[ -f "$DIST/Hyperdisplay-macOS-arm64.dmg" ]]; then
  ASSETS=("$DIST/Hyperdisplay-macOS-arm64.dmg#Hyperdisplay-macOS-arm64.dmg" "${ASSETS[@]}")
elif [[ "$MODE" == "--android-only" ]]; then
  NOTES=(--notes "Android APK is available now. The macOS DMG will be added after Apple notarization.")
else
  echo "release error: missing notarized Mac DMG; use --android-only for an explicitly Android-only release" >&2
  exit 1
fi

gh release create "$TAG" \
  "${ASSETS[@]}" \
  --repo "$REPOSITORY" \
  --title "Hyperdisplay $TAG" \
  --generate-notes \
  "${NOTES[@]}"
