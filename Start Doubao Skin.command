#!/bin/bash

ROOT="$(cd "$(dirname "$0")" && pwd -P)"
"$ROOT/scripts/start-doubao-skin-macos.sh" --restart-existing "$@"
STATUS="$?"
printf '\n'
if [ -t 0 ]; then
  read -r -p "按回车键关闭窗口…"
fi
exit "$STATUS"
