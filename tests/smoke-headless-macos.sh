#!/bin/bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
. "$PROJECT_ROOT/scripts/common-macos.sh"

PROBE_ROOT="$(/usr/bin/mktemp -d /tmp/doubao-skin-smoke.XXXXXX)"
PROBE_PID=""
SCREENSHOT="${DOUBAO_SKIN_SMOKE_SCREENSHOT:-}"
PRESET="${DOUBAO_SKIN_SMOKE_PRESET:-}"
PROFILE="$PROBE_ROOT/profile"
ORIGINAL_MAIN_PIDS=""

cleanup() {
  local code="$?"
  local pid=""
  local attempt=0
  set +e
  while read -r pid; do
    [ -n "$pid" ] || continue
    /bin/kill -TERM "$pid" 2>/dev/null || true
  done < <(/bin/ps -axo pid=,command= \
    | /usr/bin/awk -v profile="$PROFILE" 'index($0, profile) { print $1 }')
  if [ -n "$PROBE_PID" ]; then
    /bin/kill -TERM "$PROBE_PID" 2>/dev/null || true
  fi
  while [ "$attempt" -lt 16 ]; do
    [ -z "$PROBE_PID" ] || ! /bin/kill -0 "$PROBE_PID" 2>/dev/null || {
      /bin/sleep 0.25
      attempt=$((attempt + 1))
      continue
    }
    break
  done
  while read -r pid; do
    [ -n "$pid" ] || continue
    /bin/kill -KILL "$pid" 2>/dev/null || true
  done < <(/bin/ps -axo pid=,command= \
    | /usr/bin/awk -v profile="$PROFILE" 'index($0, profile) { print $1 }')
  if [ -n "$PROBE_PID" ]; then
    /bin/kill -KILL "$PROBE_PID" 2>/dev/null || true
  fi
  while read -r pid; do
    [ -n "$pid" ] || continue
    if ! printf '%s\n' "$ORIGINAL_MAIN_PIDS" | /usr/bin/grep -qx "$pid"; then
      /bin/kill -TERM "$pid" 2>/dev/null || true
    fi
  done < <(doubao_main_pids 2>/dev/null || true)
  case "$PROBE_ROOT" in
    /tmp/doubao-skin-smoke.*)
      [ -d "$PROBE_ROOT" ] && /usr/bin/find "$PROBE_ROOT" -depth -delete
      ;;
  esac
  exit "$code"
}
trap cleanup EXIT

discover_doubao_app
verify_doubao_signature
require_node
ORIGINAL_MAIN_PIDS="$(doubao_main_pids)"

ACTIVE_PORT_FILE="$PROFILE/DevToolsActivePort"
"$DOUBAO_EXE" \
  --headless=new \
  --no-first-run \
  --no-default-browser-check \
  --disable-gpu \
  --user-data-dir="$PROFILE" \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port=0 \
  "chrome://doubao-chat/chat" \
  >"$PROBE_ROOT/doubao-headless.log" 2>&1 &
PROBE_PID="$!"

attempt=0
while [ "$attempt" -lt 100 ]; do
  [ -s "$ACTIVE_PORT_FILE" ] && break
  /bin/sleep 0.25
  attempt=$((attempt + 1))
done
[ -s "$ACTIVE_PORT_FILE" ] || fail "无界面豆包没有开放 CDP 端口。"

PORT="$(/usr/bin/sed -n '1p' "$ACTIVE_PORT_FILE")"
ARGS=(--port "$PORT" --timeout-ms 20000)
[ -z "$PRESET" ] || ARGS+=(--preset "$PRESET")
if [ -n "$SCREENSHOT" ]; then
  "$NODE" "$INJECTOR" --once "${ARGS[@]}" --screenshot "$SCREENSHOT"
else
  "$NODE" "$INJECTOR" --once "${ARGS[@]}"
fi
"$NODE" "$INJECTOR" --verify "${ARGS[@]}"
"$NODE" "$INJECTOR" --remove "${ARGS[@]}"

printf 'PASS: real Doubao renderer accepted, verified, and removed the PoC skin on CDP port %s.\n' \
  "$PORT"
