#!/bin/bash

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$COMMON_DIR/.." && pwd -P)"
INJECTOR="$PROJECT_ROOT/scripts/injector.mjs"
EXPECTED_BUNDLE_ID="com.bot.pc.doubao"
EXPECTED_TEAM_ID="96L78H6LMH"
STATE_ROOT="${DOUBAO_SKIN_STATE_ROOT:-$HOME/Library/Application Support/DoubaoSkin}"
STATE_PATH="$STATE_ROOT/state.json"
CONFIG_PATH="$STATE_ROOT/config.plist"
THEME_LIBRARY_MARKER="$STATE_ROOT/bundled-theme-library-v2"
INSTALL_ROOT="$STATE_ROOT/runtime"
THEMES_ROOT="$STATE_ROOT/themes"
INJECTOR_LOG="$STATE_ROOT/injector.log"
INJECTOR_ERROR_LOG="$STATE_ROOT/injector-error.log"
SUPERVISOR_LOG="$STATE_ROOT/supervisor.log"
SUPERVISOR_ERROR_LOG="$STATE_ROOT/supervisor-error.log"
APP_LOG="$STATE_ROOT/doubao.log"
APP_ERROR_LOG="$STATE_ROOT/doubao-error.log"
INJECTOR_JOB_LABEL="com.local.doubao-skin-poc.injector"
INJECTOR_PLIST="$STATE_ROOT/$INJECTOR_JOB_LABEL.plist"
SUPERVISOR_JOB_LABEL="com.local.doubao-skin.supervisor"
SUPERVISOR_PLIST="$HOME/Library/LaunchAgents/$SUPERVISOR_JOB_LABEL.plist"
LEGACY_STATE_ROOT="$HOME/Library/Application Support/DoubaoSkinPoC"
LEGACY_INJECTOR_PLIST="$LEGACY_STATE_ROOT/$INJECTOR_JOB_LABEL.plist"

fail() {
  printf 'Doubao Skin: %s\n' "$*" >&2
  exit 1
}

ensure_state_root() {
  /bin/mkdir -p "$STATE_ROOT"
  /bin/chmod 700 "$STATE_ROOT"
}

discover_doubao_app() {
  local candidate=""
  local identifier=""
  local executable_name=""
  local configured="${DOUBAO_APP_BUNDLE:-}"

  DOUBAO_BUNDLE=""
  for candidate in "$configured" \
    "/Applications/Doubao.app" "$HOME/Applications/Doubao.app"; do
    [ -n "$candidate" ] || continue
    [ -f "$candidate/Contents/Info.plist" ] || continue
    identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
      "$candidate/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$identifier" = "$EXPECTED_BUNDLE_ID" ]; then
      DOUBAO_BUNDLE="$candidate"
      break
    fi
  done

  if [ -z "$DOUBAO_BUNDLE" ]; then
    candidate="$(/usr/bin/mdfind \
      "kMDItemCFBundleIdentifier == \"$EXPECTED_BUNDLE_ID\"" | /usr/bin/head -n 1)"
    if [ -n "$candidate" ] && [ -f "$candidate/Contents/Info.plist" ]; then
      identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
        "$candidate/Contents/Info.plist" 2>/dev/null || true)"
      [ "$identifier" = "$EXPECTED_BUNDLE_ID" ] && DOUBAO_BUNDLE="$candidate"
    fi
  fi

  [ -n "$DOUBAO_BUNDLE" ] || fail "没有找到官方豆包应用（$EXPECTED_BUNDLE_ID）。"
  executable_name="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - \
    "$DOUBAO_BUNDLE/Contents/Info.plist")"
  DOUBAO_EXE="$DOUBAO_BUNDLE/Contents/MacOS/$executable_name"
  DOUBAO_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - \
    "$DOUBAO_BUNDLE/Contents/Info.plist")"
  [ -x "$DOUBAO_EXE" ] || fail "豆包主程序不存在：$DOUBAO_EXE"
  export DOUBAO_BUNDLE DOUBAO_EXE DOUBAO_VERSION
}

codesign_team_id() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 \
    | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}'
}

verify_doubao_signature() {
  local team_id=""
  /usr/bin/codesign --verify --strict "$DOUBAO_BUNDLE" >/dev/null 2>&1 \
    || fail "豆包应用签名校验失败，请重新安装官方版本。"
  team_id="$(codesign_team_id "$DOUBAO_BUNDLE")"
  [ "$team_id" = "$EXPECTED_TEAM_ID" ] \
    || fail "豆包签名团队不符合预期：${team_id:-missing}"
}

node_is_usable() {
  local candidate="$1"
  local version=""
  local major=""
  [ -x "$candidate" ] || return 1
  version="$("$candidate" --version 2>/dev/null || true)"
  major="${version#v}"
  major="${major%%.*}"
  case "$major" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$major" -ge 22 ]
}

require_node() {
  local candidate=""
  local path_node=""
  path_node="$(command -v node 2>/dev/null || true)"

  for candidate in "$PROJECT_ROOT/bin/node" \
    "$path_node" \
    "/opt/homebrew/bin/node" \
    "/usr/local/bin/node" \
    "$HOME/.local/bin/node" \
    "$HOME/.local/share/mise/installs/node/lts/bin/node" \
    "$HOME"/.local/share/mise/installs/node/*/bin/node \
    "$HOME"/.nvm/versions/node/*/bin/node; do
    [ -n "$candidate" ] || continue
    if node_is_usable "$candidate"; then
      NODE="$candidate"
      NODE_VERSION="$("$NODE" --version)"
      export NODE NODE_VERSION
      return 0
    fi
  done
  fail "此 PoC 需要 Node.js 22 或更高版本。"
}

state_field() {
  local field="$1"
  [ -f "$STATE_PATH" ] || return 1
  "$NODE" -e '
    const fs = require("node:fs");
    const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))[process.argv[2]];
    if (value !== null && value !== undefined) process.stdout.write(String(value));
  ' "$STATE_PATH" "$field"
}

write_state() {
  local port="$1"
  local injector_pid="$2"
  local app_pid="$3"
  local background="${4:-}"
  local preset="${5:-}"
  local temporary="$STATE_PATH.tmp.$$"
  ensure_state_root
  "$NODE" -e '
    const fs = require("node:fs");
    const [destination, temporary, port, injectorPid, appPid, background, preset] =
      process.argv.slice(1);
    const state = {
      schema: "doubao-skin-state/1",
      status: "active",
      port: Number(port),
      injectorPid: Number(injectorPid),
      appPid: Number(appPid),
      background: background || null,
      preset: preset || null,
      updatedAt: new Date().toISOString()
    };
    fs.writeFileSync(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
    fs.renameSync(temporary, destination);
  ' "$STATE_PATH" "$temporary" "$port" "$injector_pid" "$app_pid" "$background" "$preset"
  /bin/chmod 600 "$STATE_PATH"
}

clear_state() {
  [ ! -f "$STATE_PATH" ] \
    || /usr/bin/find "$STATE_PATH" -maxdepth 0 -type f -delete
  [ ! -f "$INJECTOR_PLIST" ] \
    || /usr/bin/find "$INJECTOR_PLIST" -maxdepth 0 -type f -delete
}

doubao_main_pids() {
  local pid=""
  local command_line=""
  while read -r pid command_line; do
    [ -n "$pid" ] || continue
    case "$command_line" in
      "$DOUBAO_EXE"*) printf '%s\n' "$pid" ;;
    esac
  done < <(/bin/ps -axo pid=,command=)
}

doubao_interactive_main_pids() {
  local pid=""
  local command_line=""
  while read -r pid command_line; do
    [ -n "$pid" ] || continue
    case "$command_line" in
      "$DOUBAO_EXE"*--headless*) ;;
      "$DOUBAO_EXE"*) printf '%s\n' "$pid" ;;
    esac
  done < <(/bin/ps -axo pid=,command=)
}

doubao_interactive_is_running() {
  [ -n "$(doubao_interactive_main_pids)" ]
}

doubao_interactive_has_skin_port() {
  local port="$1"
  local pid=""
  local command_line=""
  while read -r pid command_line; do
    [ -n "$pid" ] || continue
    case "$command_line" in
      "$DOUBAO_EXE"*--headless*) ;;
      "$DOUBAO_EXE"*--remote-debugging-address=127.0.0.1*--remote-debugging-port="$port"*)
        return 0
        ;;
    esac
  done < <(/bin/ps -axo pid=,command=)
  return 1
}

doubao_family_pids() {
  local pid=""
  local command_line=""
  while read -r pid command_line; do
    [ -n "$pid" ] || continue
    case "$command_line" in
      "$DOUBAO_BUNDLE/Contents/"*) printf '%s\n' "$pid" ;;
    esac
  done < <(/bin/ps -axo pid=,command=)
}

doubao_is_running() {
  [ -n "$(doubao_main_pids)" ]
}

pid_is_doubao_family() {
  local pid="$1"
  local current="$pid"
  local command_line=""
  local parent=""
  local depth=0
  while [ "$current" -gt 1 ] 2>/dev/null && [ "$depth" -lt 16 ]; do
    command_line="$(/bin/ps -p "$current" -o command= 2>/dev/null || true)"
    case "$command_line" in
      "$DOUBAO_EXE"*) return 0 ;;
      *"/Doubao Browser.app/Contents/MacOS/Doubao Browser"*) return 0 ;;
    esac
    parent="$(/bin/ps -p "$current" -o ppid= 2>/dev/null | /usr/bin/tr -d ' ')"
    case "$parent" in
      ''|*[!0-9]*) return 1 ;;
    esac
    [ "$parent" != "$current" ] || return 1
    current="$parent"
    depth=$((depth + 1))
  done
  return 1
}

listener_belongs_to_doubao() {
  local port="$1"
  local pid=""
  local found="false"
  [ -x /usr/sbin/lsof ] || return 0
  while read -r pid; do
    [ -n "$pid" ] || continue
    found="true"
    pid_is_doubao_family "$pid" || return 1
  done < <(/usr/sbin/lsof -nP -a -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true)
  [ "$found" = "true" ]
}

port_is_available() {
  local port="$1"
  if [ -x /usr/sbin/lsof ]; then
    ! /usr/sbin/lsof -nP -a -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1
  else
    ! /usr/bin/nc -z 127.0.0.1 "$port" >/dev/null 2>&1
  fi
}

select_available_port() {
  local preferred="$1"
  local candidate="$preferred"
  while [ "$candidate" -le 9551 ]; do
    if port_is_available "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    candidate=$((candidate + 1))
  done
  return 1
}

cdp_ready() {
  local port="$1"
  local version=""
  version="$(/usr/bin/curl --silent --show-error --max-time 2 \
    "http://127.0.0.1:$port/json/version" 2>/dev/null || true)"
  printf '%s' "$version" | /usr/bin/grep -q '"Protocol-Version"' \
    && listener_belongs_to_doubao "$port"
}

wait_for_cdp() {
  local port="$1"
  local attempt=0
  while [ "$attempt" -lt 180 ]; do
    cdp_ready "$port" && return 0
    /bin/sleep 0.25
    attempt=$((attempt + 1))
  done
  return 1
}

stop_doubao() {
  local pid=""
  local attempt=0
  /usr/bin/osascript -e \
    'tell application id "com.bot.pc.doubao" to quit' >/dev/null 2>&1 || true
  while [ "$attempt" -lt 40 ]; do
    doubao_is_running || return 0
    /bin/sleep 0.25
    attempt=$((attempt + 1))
  done
  while read -r pid; do
    [ -n "$pid" ] || continue
    /bin/kill -TERM "$pid" 2>/dev/null || true
  done < <(doubao_main_pids)
  attempt=0
  while [ "$attempt" -lt 24 ]; do
    doubao_is_running || return 0
    /bin/sleep 0.25
    attempt=$((attempt + 1))
  done
  while read -r pid; do
    [ -n "$pid" ] || continue
    /bin/kill -KILL "$pid" 2>/dev/null || true
  done < <(doubao_family_pids)
  attempt=0
  while [ "$attempt" -lt 16 ]; do
    doubao_is_running || return 0
    /bin/sleep 0.25
    attempt=$((attempt + 1))
  done
  return 1
}

launch_doubao_with_cdp() {
  local port="$1"
  ensure_state_root
  : > "$APP_LOG"
  : > "$APP_ERROR_LOG"
  /usr/bin/open -na "$DOUBAO_BUNDLE" --args \
    --remote-debugging-address=127.0.0.1 \
    --remote-debugging-port="$port" \
    >>"$APP_LOG" 2>>"$APP_ERROR_LOG" || true
  /bin/sleep 1
  if ! doubao_is_running; then
    /usr/bin/nohup "$DOUBAO_EXE" \
      --remote-debugging-address=127.0.0.1 \
      --remote-debugging-port="$port" \
      >>"$APP_LOG" 2>>"$APP_ERROR_LOG" &
  fi
}

launch_doubao_normally() {
  /usr/bin/open -na "$DOUBAO_BUNDLE"
}

supervisor_job_target() {
  printf 'gui/%s/%s\n' "$(/usr/bin/id -u)" "$SUPERVISOR_JOB_LABEL"
}

current_supervisor_job_pid() {
  /bin/launchctl print "$(supervisor_job_target)" 2>/dev/null \
    | /usr/bin/awk '/^[[:space:]]*pid = [0-9]+/{print $3; exit}'
}

stop_supervisor_job() {
  local pid=""
  local attempt=0
  pid="$(current_supervisor_job_pid || true)"
  /bin/launchctl bootout "$(supervisor_job_target)" >/dev/null 2>&1 || true
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  while [ "$attempt" -lt 32 ]; do
    /bin/kill -0 "$pid" 2>/dev/null || return 0
    /bin/sleep 0.25
    attempt=$((attempt + 1))
  done
  return 1
}

stop_legacy_injector_job() {
  /bin/launchctl bootout \
    "gui/$(/usr/bin/id -u)/$INJECTOR_JOB_LABEL" >/dev/null 2>&1 || true
}

injector_job_target() {
  printf 'gui/%s/%s\n' "$(/usr/bin/id -u)" "$INJECTOR_JOB_LABEL"
}

current_injector_job_pid() {
  /bin/launchctl print "$(injector_job_target)" 2>/dev/null \
    | /usr/bin/awk '/^[[:space:]]*pid = [0-9]+/{print $3; exit}'
}

write_injector_plist() {
  local port="$1"
  local background="${2:-}"
  local preset="${3:-}"
  ensure_state_root
  "$NODE" -e '
    const fs = require("node:fs");
    const [destination, label, node, injector, port, stdout, stderr, background, preset] =
      process.argv.slice(1);
    const escape = (value) => String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll("\"", "&quot;")
      .replaceAll("\x27", "&apos;");
    const args = [
      node, injector, "--watch", "--port", port, "--timeout-ms", "45000"
    ];
    if (background) args.push("--background", background);
    if (preset) args.push("--preset", preset);
    const argumentXml = args.map((value) => `    <string>${escape(value)}</string>`).join("\n");
    const xml = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${escape(label)}</string>
  <key>ProgramArguments</key>
  <array>
${argumentXml}
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>StandardOutPath</key>
  <string>${escape(stdout)}</string>
  <key>StandardErrorPath</key>
  <string>${escape(stderr)}</string>
</dict>
</plist>
`;
    fs.writeFileSync(destination, xml, { mode: 0o600 });
  ' "$INJECTOR_PLIST" "$INJECTOR_JOB_LABEL" "$NODE" "$INJECTOR" "$port" \
    "$INJECTOR_LOG" "$INJECTOR_ERROR_LOG" "$background" "$preset"
  /bin/chmod 600 "$INJECTOR_PLIST"
  /usr/bin/plutil -lint "$INJECTOR_PLIST" >/dev/null \
    || fail "生成的注入器 LaunchAgent 配置无效。"
}

stop_injector_job() {
  local pid=""
  local attempt=0
  pid="$(current_injector_job_pid || true)"
  /bin/launchctl bootout "$(injector_job_target)" >/dev/null 2>&1 || true
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  while [ "$attempt" -lt 24 ]; do
    /bin/kill -0 "$pid" 2>/dev/null || return 0
    /bin/sleep 0.25
    attempt=$((attempt + 1))
  done
  return 1
}

launch_injector_daemon() {
  local port="$1"
  local background="${2:-}"
  local preset="${3:-}"
  local pid=""
  local attempt=0
  stop_injector_job || return 1
  write_injector_plist "$port" "$background" "$preset"
  /bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "$INJECTOR_PLIST" \
    >/dev/null 2>&1 || return 1
  while [ "$attempt" -lt 40 ]; do
    pid="$(current_injector_job_pid || true)"
    case "$pid" in
      ''|*[!0-9]*) ;;
      *)
        /bin/kill -0 "$pid" 2>/dev/null && {
          printf '%s\n' "$pid"
          return 0
        }
        ;;
    esac
    /bin/sleep 0.25
    attempt=$((attempt + 1))
  done
  return 1
}

stop_recorded_injector() {
  local recorded_pid=""
  local command_line=""
  stop_injector_job || return 1
  [ -f "$STATE_PATH" ] || return 0
  recorded_pid="$(state_field injectorPid 2>/dev/null || true)"
  case "$recorded_pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  command_line="$(/bin/ps -p "$recorded_pid" -o command= 2>/dev/null || true)"
  case "$command_line" in
    *"$INJECTOR"*"--watch"*)
      /bin/kill -TERM "$recorded_pid" 2>/dev/null || true
      ;;
  esac
  return 0
}
