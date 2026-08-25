#!/bin/bash
# 把 Apple notarization 凭据安全存入登录 Keychain；不会写入 Git、shell 历史或项目文件。
set -euo pipefail

PROFILE="${1:-HyperdisplayNotary}"
TEAM_ID="${HYPERDISPLAY_APPLE_TEAM_ID:-B45VZCNYU3}"

command -v xcrun >/dev/null 2>&1 || { echo "notary setup error: missing Xcode command-line tools" >&2; exit 1; }
printf 'Apple ID（仅用于保存到 Keychain，不会写入项目）： '
read -r APPLE_ID
[[ -n "$APPLE_ID" ]] || { echo "notary setup error: Apple ID is required" >&2; exit 1; }

# 不传 --password：notarytool 会在终端安全提示输入 Apple ID 的 app-specific password，
# 并在写入前联网验证凭据；密码既不会显示也不会留在 shell history。
xcrun notarytool store-credentials "$PROFILE" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --sync

echo "Notary profile '$PROFILE' is ready in Keychain."
echo "Next: HYPERDISPLAY_NOTARY_PROFILE='$PROFILE' ./script/package-release.sh"
