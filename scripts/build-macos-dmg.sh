#!/bin/bash

set -Eeuo pipefail
. "$(cd "$(dirname "$0")" && pwd -P)/common-macos.sh"

VERSION="$(/usr/bin/tr -d '\r\n' <"$PROJECT_ROOT/VERSION")"
case "$VERSION" in
  ''|*[!0-9.]*)
    fail "VERSION 不是有效的发布版本号。"
    ;;
esac

OUTPUT_ROOT="$PROJECT_ROOT/dist"
APP_PATH="$OUTPUT_ROOT/Doubao Skin.app"
DMG_PATH="$OUTPUT_ROOT/Doubao-Skin-macOS-$VERSION.dmg"
STAGING="$(/usr/bin/mktemp -d /tmp/doubao-skin-dmg.XXXXXX)"

cleanup() {
  case "$STAGING" in
    /tmp/doubao-skin-dmg.*)
      [ ! -e "$STAGING" ] || /usr/bin/find "$STAGING" -depth -delete
      ;;
  esac
}
trap cleanup EXIT

"$PROJECT_ROOT/scripts/build-macos-app.sh" >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP_PATH" >/dev/null \
  || fail "待封装的 Doubao Skin.app 签名无效。"

/usr/bin/ditto "$APP_PATH" "$STAGING/Doubao Skin.app"
/bin/ln -s /Applications "$STAGING/Applications"
/bin/cp "$PROJECT_ROOT/docs/APP-USAGE.md" "$STAGING/使用说明.md"
/bin/cp "$PROJECT_ROOT/LICENSE" "$STAGING/LICENSE"
/bin/cp "$PROJECT_ROOT/README.md" "$STAGING/项目说明.md"

/usr/bin/hdiutil create \
  -ov \
  -volname "Doubao Skin" \
  -srcfolder "$STAGING" \
  -format UDZO \
  "$DMG_PATH" >/dev/null
/usr/bin/hdiutil verify "$DMG_PATH" >/dev/null \
  || fail "生成的 DMG 校验失败。"

printf '%s\n' "$DMG_PATH"
