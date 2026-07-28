#!/bin/bash

set -Eeuo pipefail
. "$(cd "$(dirname "$0")" && pwd -P)/common-macos.sh"

SOURCE_APP="$PROJECT_ROOT/dist/Doubao Skin.app"
DESTINATION="/Applications/Doubao Skin.app"
TEMPORARY="/Applications/Doubao Skin.app.installing.$$"
PREVIOUS="/Applications/Doubao Skin.app.previous.$$"

[ -d "$SOURCE_APP" ] || "$PROJECT_ROOT/scripts/build-macos-app.sh" >/dev/null
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP" >/dev/null \
  || fail "待安装的 Doubao Skin.app 签名无效。"

cleanup() {
  [ ! -e "$TEMPORARY" ] || /usr/bin/find "$TEMPORARY" -depth -delete
}
trap cleanup EXIT

/usr/bin/ditto "$SOURCE_APP" "$TEMPORARY"
if [ -e "$DESTINATION" ]; then
  identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
    "$DESTINATION/Contents/Info.plist" 2>/dev/null || true)"
  [ "$identifier" = "com.local.doubao-skin" ] \
    || fail "拒绝覆盖其他应用：$DESTINATION"
  /bin/mv "$DESTINATION" "$PREVIOUS"
fi
if ! /bin/mv "$TEMPORARY" "$DESTINATION"; then
  [ ! -e "$PREVIOUS" ] || /bin/mv "$PREVIOUS" "$DESTINATION"
  fail "Doubao Skin.app 安装失败。"
fi
[ ! -e "$PREVIOUS" ] || /usr/bin/find "$PREVIOUS" -depth -delete
/usr/bin/xattr -dr com.apple.quarantine "$DESTINATION" 2>/dev/null || true
printf '已安装：%s\n' "$DESTINATION"
