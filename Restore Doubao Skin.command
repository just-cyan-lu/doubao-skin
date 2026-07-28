#!/bin/bash

ROOT="$(cd "$(dirname "$0")" && pwd -P)"
"$ROOT/scripts/restore-doubao-skin-macos.sh" "$@"
STATUS="$?"
printf '\n'
if [ -t 0 ]; then
  read -r -p "按回车键关闭窗口…"
fi
exit "$STATUS"
