#!/bin/bash

set -Eeuo pipefail
. "$(cd "$(dirname "$0")" && pwd -P)/common-macos.sh"

OUTPUT_ROOT="$PROJECT_ROOT/dist"
APP_PATH="$OUTPUT_ROOT/Doubao Skin.app"
TEMPORARY="$OUTPUT_ROOT/Doubao Skin.app.building.$$"

cleanup() {
  [ ! -e "$TEMPORARY" ] || /usr/bin/find "$TEMPORARY" -depth -delete
}
trap cleanup EXIT

require_node
/usr/bin/xcrun --find swiftc >/dev/null \
  || fail "没有找到 Swift 编译器，请安装 Xcode Command Line Tools。"

/bin/mkdir -p "$OUTPUT_ROOT"
cleanup
/bin/mkdir -p \
  "$TEMPORARY/Contents/MacOS" \
  "$TEMPORARY/Contents/Resources/runtime/bin"

/bin/cp "$PROJECT_ROOT/macos/Info.plist" "$TEMPORARY/Contents/Info.plist"
/bin/cp "$PROJECT_ROOT/assets/DoubaoSkin.icns" \
  "$TEMPORARY/Contents/Resources/DoubaoSkin.icns"
for entry in assets docs macos presets scripts AGENTS.md LICENSE README.md package.json VERSION; do
  [ -e "$PROJECT_ROOT/$entry" ] || continue
  /usr/bin/rsync -a "$PROJECT_ROOT/$entry" "$TEMPORARY/Contents/Resources/runtime/"
done
/bin/cp "$NODE" "$TEMPORARY/Contents/Resources/runtime/bin/node"
/bin/chmod 700 \
  "$TEMPORARY/Contents/Resources/runtime/bin/node" \
  "$TEMPORARY/Contents/Resources/runtime/scripts/"*.sh

/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -target arm64-apple-macos13.0 \
  "$PROJECT_ROOT/macos/DoubaoSkinApp.swift" \
  -framework AppKit \
  -framework SwiftUI \
  -o "$TEMPORARY/Contents/MacOS/Doubao Skin"

/usr/bin/plutil -lint "$TEMPORARY/Contents/Info.plist" >/dev/null
"$TEMPORARY/Contents/Resources/runtime/bin/node" \
  "$TEMPORARY/Contents/Resources/runtime/scripts/injector.mjs" \
  --check --preset mbti-boy-infp >/dev/null
/usr/bin/codesign --force --deep --sign - "$TEMPORARY" >/dev/null

if [ -e "$APP_PATH" ]; then
  identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
    "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
  [ "$identifier" = "com.local.doubao-skin" ] \
    || fail "拒绝覆盖 dist 中不属于本项目的应用：$APP_PATH"
  /usr/bin/find "$APP_PATH" -depth -delete
fi
/bin/mv "$TEMPORARY" "$APP_PATH"
printf '%s\n' "$APP_PATH"
