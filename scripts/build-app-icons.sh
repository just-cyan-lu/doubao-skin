#!/bin/bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SOURCE="$PROJECT_ROOT/assets/app-icon.png"
ICNS_OUTPUT="$PROJECT_ROOT/assets/DoubaoSkin.icns"
ICO_OUTPUT="$PROJECT_ROOT/assets/DoubaoSkin.ico"
WORK="$(/usr/bin/mktemp -d /tmp/doubao-skin-icons.XXXXXX)"
ICONSET="$WORK/DoubaoSkin.iconset"

cleanup() {
  case "$WORK" in
    /tmp/doubao-skin-icons.*)
      [ ! -e "$WORK" ] || /usr/bin/find "$WORK" -depth -delete
      ;;
  esac
}
trap cleanup EXIT

[ -f "$SOURCE" ] || {
  printf 'Missing app icon master: %s\n' "$SOURCE" >&2
  exit 1
}
/bin/mkdir -p "$ICONSET"

resize_icon() {
  local size="$1"
  local name="$2"
  /usr/bin/sips -s format png -z "$size" "$size" \
    "$SOURCE" --out "$ICONSET/$name" >/dev/null
}

resize_icon 16 icon_16x16.png
resize_icon 32 icon_16x16@2x.png
resize_icon 32 icon_32x32.png
resize_icon 64 icon_32x32@2x.png
resize_icon 128 icon_128x128.png
resize_icon 256 icon_128x128@2x.png
resize_icon 256 icon_256x256.png
resize_icon 512 icon_256x256@2x.png
resize_icon 512 icon_512x512.png
resize_icon 1024 icon_512x512@2x.png
/usr/bin/iconutil -c icns "$ICONSET" -o "$ICNS_OUTPUT"

ICO_INPUTS=()
for size in 16 20 24 32 40 48 64 128 256; do
  ico_png="$WORK/ico-$size.png"
  /usr/bin/sips -s format png -z "$size" "$size" \
    "$SOURCE" --out "$ico_png" >/dev/null
  ICO_INPUTS+=("$ico_png")
done

/usr/bin/env node --input-type=module - "$ICO_OUTPUT" "${ICO_INPUTS[@]}" <<'JS'
import fs from "node:fs";

const [output, ...inputs] = process.argv.slice(2);
const images = inputs.map((input) => fs.readFileSync(input));
const headerSize = 6;
const entrySize = 16;
let offset = headerSize + entrySize * images.length;
const header = Buffer.alloc(headerSize + entrySize * images.length);
header.writeUInt16LE(0, 0);
header.writeUInt16LE(1, 2);
header.writeUInt16LE(images.length, 4);

images.forEach((image, index) => {
  const pngWidth = image.readUInt32BE(16);
  const pngHeight = image.readUInt32BE(20);
  const entry = headerSize + index * entrySize;
  header.writeUInt8(pngWidth === 256 ? 0 : pngWidth, entry);
  header.writeUInt8(pngHeight === 256 ? 0 : pngHeight, entry + 1);
  header.writeUInt8(0, entry + 2);
  header.writeUInt8(0, entry + 3);
  header.writeUInt16LE(1, entry + 4);
  header.writeUInt16LE(32, entry + 6);
  header.writeUInt32LE(image.length, entry + 8);
  header.writeUInt32LE(offset, entry + 12);
  offset += image.length;
});

fs.writeFileSync(output, Buffer.concat([header, ...images]));
JS

printf '%s\n%s\n' "$ICNS_OUTPUT" "$ICO_OUTPUT"
