#!/bin/bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

PORT=9451
PRESET="infp"
THEME_DIR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 ;;
    --preset) PRESET="${2:-}"; shift 2 ;;
    --theme-dir) THEME_DIR="${2:-}"; shift 2 ;;
    --restart-existing) shift ;;
    --background)
      printf 'Doubao Skin: 0.4.0 起请把背景图放进主题文件夹，并写入 theme.json 的 background 字段。\n' >&2
      exit 1
      ;;
    *) printf 'Doubao Skin: 未知参数：%s\n' "$1" >&2; exit 1 ;;
  esac
done

if [ -z "$THEME_DIR" ]; then
  case "$PRESET" in
    [a-z0-9]*)
      case "$PRESET" in *[!a-z0-9-]*) printf 'Doubao Skin: 主题 ID 无效。\n' >&2; exit 1 ;; esac
      ;;
    *) printf 'Doubao Skin: 主题 ID 无效。\n' >&2; exit 1 ;;
  esac
  THEME_DIR="$PROJECT_ROOT/presets/$PRESET"
fi

exec "$SCRIPT_DIR/manage-doubao-skin-macos.sh" \
  enable --port "$PORT" --theme-dir "$THEME_DIR"
