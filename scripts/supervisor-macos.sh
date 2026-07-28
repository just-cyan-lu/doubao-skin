#!/bin/bash

set -u
. "$(cd "$(dirname "$0")" && pwd -P)/common-macos.sh"

WATCHER_PID=""
STOPPING="false"

log() {
  printf '%s %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$*"
}

notify_user() {
  /usr/bin/osascript - "$1" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  display notification (item 1 of argv) with title "Doubao Skin"
end run
APPLESCRIPT
}

config_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$CONFIG_PATH" 2>/dev/null || true
}

stop_watcher() {
  local attempt=0
  case "$WATCHER_PID" in
    ''|*[!0-9]*) return 0 ;;
  esac
  /bin/kill -TERM "$WATCHER_PID" 2>/dev/null || true
  while [ "$attempt" -lt 24 ]; do
    /bin/kill -0 "$WATCHER_PID" 2>/dev/null || {
      WATCHER_PID=""
      return 0
    }
    /bin/sleep 0.25
    attempt=$((attempt + 1))
  done
  /bin/kill -KILL "$WATCHER_PID" 2>/dev/null || true
  WATCHER_PID=""
}

shutdown() {
  STOPPING="true"
  stop_watcher
}
trap shutdown INT TERM EXIT

[ -f "$CONFIG_PATH" ] || {
  log "configuration is absent; supervisor is exiting"
  exit 0
}
[ "$(config_value enabled)" = "true" ] || {
  log "skin is disabled; supervisor is exiting"
  exit 0
}

PORT="$(config_value port)"
THEME_DIR="$(config_value themeDir)"
CONVERSATION_OPACITY="$(config_value conversationOpacity)"
case "$PORT" in
  ''|*[!0-9]*) log "invalid configured port"; exit 1 ;;
esac
[ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || {
  log "configured port is outside the allowed range"
  exit 1
}
[ -d "$THEME_DIR" ] && [ -f "$THEME_DIR/theme.json" ] || {
  log "configured theme is missing"
  exit 1
}

if ! discover_doubao_app || ! verify_doubao_signature || ! require_node; then
  log "official Doubao runtime validation failed"
  exit 1
fi

start_watcher() {
  local watcher_args=(
    --watch
    --port "$PORT"
    --theme-dir "$THEME_DIR"
    --timeout-ms 45000
  )
  if [ -n "$WATCHER_PID" ] && /bin/kill -0 "$WATCHER_PID" 2>/dev/null; then
    return 0
  fi
  [ -z "$CONVERSATION_OPACITY" ] \
    || watcher_args+=(--conversation-opacity "$CONVERSATION_OPACITY")
  "$NODE" "$INJECTOR" "${watcher_args[@]}" &
  WATCHER_PID="$!"
  log "theme watcher started (pid $WATCHER_PID)"
}

start_watcher
log "persistent supervisor is ready on 127.0.0.1:$PORT"

while [ "$STOPPING" = "false" ]; do
  start_watcher

  if ! doubao_interactive_is_running; then
    /bin/sleep 2
    continue
  fi

  # The verified manager is the only component that launches an interactive
  # instance with this exact loopback argument pair. Checking the main process
  # command avoids an expensive curl/lsof probe every second while Doubao is
  # already healthy; the watcher independently reconnects to the renderer.
  if doubao_interactive_has_skin_port "$PORT"; then
    /bin/sleep 3
    continue
  fi

  # A normal Dock/Finder launch has no CDP switch. Give a CDP-enabled launch
  # time to finish first, then replace only the interactive app instance.
  /bin/sleep 2
  [ "$STOPPING" = "false" ] || break
  doubao_interactive_has_skin_port "$PORT" && continue
  doubao_interactive_is_running || continue

  log "normal Doubao launch detected; restarting it with the loopback skin endpoint"
  if ! verify_doubao_signature; then
    log "Doubao signature changed or failed validation; leaving the app untouched"
    notify_user "豆包签名校验失败，皮肤没有自动接管。"
    /bin/sleep 15
    continue
  fi
  if ! stop_doubao; then
    log "could not stop the normal Doubao instance"
    notify_user "豆包未能自动重启，请退出后再打开一次。"
    /bin/sleep 5
    continue
  fi

  launch_doubao_with_cdp "$PORT"
  if wait_for_cdp "$PORT"; then
    log "Doubao relaunched with persistent skin support"
  else
    log "Doubao did not expose the verified loopback endpoint"
    notify_user "豆包已打开，但皮肤端口没有就绪。请在 Doubao Skin 中重新应用。"
  fi
done

exit 0
