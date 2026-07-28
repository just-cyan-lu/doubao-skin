#!/bin/bash

set -Eeuo pipefail
. "$(cd "$(dirname "$0")" && pwd -P)/common-macos.sh"

COMMAND="${1:-status}"
[ "$#" -eq 0 ] || shift
PORT=9451
THEME_SOURCE=""
CONVERSATION_OPACITY=""
INSTALLED_MODE="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --installed) INSTALLED_MODE="true"; shift ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --theme-dir) THEME_SOURCE="${2:-}"; shift 2 ;;
    --conversation-opacity) CONVERSATION_OPACITY="${2:-}"; shift 2 ;;
    *) fail "未知参数：$1" ;;
  esac
done

case "$PORT" in
  ''|*[!0-9]*) fail "端口无效：$PORT" ;;
esac
[ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] \
  || fail "端口必须在 1024–65535。"

safe_remove_tree() {
  local target="$1"
  case "$target" in
    "$STATE_ROOT"/runtime.installing.*|"$STATE_ROOT"/runtime.previous.*)
      [ ! -e "$target" ] || /usr/bin/find "$target" -depth -delete
      ;;
    *) fail "拒绝删除非运行时暂存目录：$target" ;;
  esac
}

deploy_runtime() {
  local temporary="$STATE_ROOT/runtime.installing.$$"
  local previous="$STATE_ROOT/runtime.previous.$$"
  local had_previous="false"

  ensure_state_root
  safe_remove_tree "$temporary"
  safe_remove_tree "$previous"
  /bin/mkdir -p "$temporary"
  /bin/chmod 700 "$temporary"

  for entry in assets docs presets scripts AGENTS.md LICENSE README.md package.json VERSION; do
    [ -e "$PROJECT_ROOT/$entry" ] || continue
    /usr/bin/rsync -a "$PROJECT_ROOT/$entry" "$temporary/"
  done

  /bin/mkdir -p "$temporary/bin"
  if node_is_usable "$PROJECT_ROOT/bin/node"; then
    /bin/cp "$PROJECT_ROOT/bin/node" "$temporary/bin/node"
  else
    require_node
    /bin/cp "$NODE" "$temporary/bin/node"
  fi
  /bin/chmod 700 "$temporary/bin/node" "$temporary/scripts/"*.sh
  "$temporary/bin/node" "$temporary/scripts/injector.mjs" \
    --check --preset mbti-boy-infp >/dev/null

  if [ -e "$INSTALL_ROOT" ]; then
    /bin/mv "$INSTALL_ROOT" "$previous"
    had_previous="true"
  fi
  if ! /bin/mv "$temporary" "$INSTALL_ROOT"; then
    [ "$had_previous" = "false" ] || /bin/mv "$previous" "$INSTALL_ROOT"
    fail "无法安装 Doubao Skin 运行时。"
  fi
  [ "$had_previous" = "false" ] || safe_remove_tree "$previous"
}

DEPLOY_FOR_COMMAND="false"
case "$COMMAND" in
  enable|enable-default|activate-library|reapply|set-conversation-opacity)
    DEPLOY_FOR_COMMAND="true"
    ;;
esac

if [ "$DEPLOY_FOR_COMMAND" = "true" ] \
  && [ "$INSTALLED_MODE" = "false" ] \
  && [ "$PROJECT_ROOT" != "$INSTALL_ROOT" ]; then
  ORIGINAL_SOURCE="$THEME_SOURCE"
  ORIGINAL_CONVERSATION_OPACITY="$CONVERSATION_OPACITY"
  if [ ! -x "$INSTALL_ROOT/scripts/manage-doubao-skin-macos.sh" ] \
    || [ ! -f "$PROJECT_ROOT/VERSION" ] \
    || [ ! -f "$INSTALL_ROOT/VERSION" ] \
    || ! /usr/bin/cmp -s "$PROJECT_ROOT/VERSION" "$INSTALL_ROOT/VERSION"; then
    deploy_runtime
  fi
  INSTALLED_ARGS=("$COMMAND" --installed --port "$PORT")
  [ -z "$ORIGINAL_SOURCE" ] || INSTALLED_ARGS+=(--theme-dir "$ORIGINAL_SOURCE")
  [ -z "$ORIGINAL_CONVERSATION_OPACITY" ] \
    || INSTALLED_ARGS+=(--conversation-opacity "$ORIGINAL_CONVERSATION_OPACITY")
  exec "$INSTALL_ROOT/scripts/manage-doubao-skin-macos.sh" "${INSTALLED_ARGS[@]}"
fi

require_node

normalize_conversation_opacity() {
  "$NODE" -e '
    const value = Number(process.argv[1]);
    if (!Number.isFinite(value) || value < 0 || value > 1) process.exit(1);
    process.stdout.write(String(Number(value.toFixed(4))));
  ' "$1"
}

if [ -n "$CONVERSATION_OPACITY" ]; then
  CONVERSATION_OPACITY="$(
    normalize_conversation_opacity "$CONVERSATION_OPACITY" 2>/dev/null
  )" || fail "对话页蒙版不透明度必须在 0%–100% 之间。"
fi

config_value() {
  local key="$1"
  [ -f "$CONFIG_PATH" ] || return 1
  /usr/bin/plutil -extract "$key" raw -o - "$CONFIG_PATH" 2>/dev/null
}

write_config() {
  local enabled="$1"
  local port="$2"
  local theme_dir="$3"
  local theme_id="$4"
  local theme_name="$5"
  local conversation_opacity="$6"
  local temporary="$CONFIG_PATH.tmp.$$"
  ensure_state_root
  /usr/bin/plutil -create xml1 "$temporary"
  /usr/bin/plutil -insert schema -string "doubao-skin-config/1" "$temporary"
  /usr/bin/plutil -insert enabled -bool "$enabled" "$temporary"
  /usr/bin/plutil -insert port -integer "$port" "$temporary"
  /usr/bin/plutil -insert themeDir -string "$theme_dir" "$temporary"
  /usr/bin/plutil -insert themeId -string "$theme_id" "$temporary"
  /usr/bin/plutil -insert themeName -string "$theme_name" "$temporary"
  /usr/bin/plutil -insert conversationOpacity -float "$conversation_opacity" "$temporary"
  /usr/bin/plutil -insert updatedAt -string "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$temporary"
  /bin/chmod 600 "$temporary"
  /bin/mv "$temporary" "$CONFIG_PATH"
}

write_active_state() {
  local port="$1"
  local theme_dir="$2"
  local theme_id="$3"
  local temporary="$STATE_PATH.tmp.$$"
  "$NODE" - "$temporary" "$STATE_PATH" "$port" "$theme_dir" "$theme_id" <<'NODE'
const fs = require("node:fs");
const [temporary, destination, port, themeDir, themeId] = process.argv.slice(2);
const state = {
  schema: "doubao-skin-state/2",
  status: "active",
  persistent: true,
  port: Number(port),
  themeDir,
  themeId,
  updatedAt: new Date().toISOString(),
};
fs.writeFileSync(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
fs.renameSync(temporary, destination);
NODE
  /bin/chmod 600 "$STATE_PATH"
}

write_supervisor_plist() {
  local temporary="$SUPERVISOR_PLIST.tmp.$$"
  /bin/mkdir -p "$HOME/Library/LaunchAgents"
  "$NODE" - "$temporary" "$SUPERVISOR_JOB_LABEL" \
    "$INSTALL_ROOT/scripts/supervisor-macos.sh" "$INSTALL_ROOT" \
    "$SUPERVISOR_LOG" "$SUPERVISOR_ERROR_LOG" <<'NODE'
const fs = require("node:fs");
const [destination, label, program, workingDirectory, stdout, stderr] =
  process.argv.slice(2);
const escape = (value) => String(value)
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;")
  .replaceAll("\"", "&quot;")
  .replaceAll("'", "&apos;");
const xml = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${escape(label)}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${escape(program)}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${escape(workingDirectory)}</string>
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
NODE
  /usr/bin/plutil -lint "$temporary" >/dev/null \
    || fail "生成的常驻配置无效。"
  /bin/mv "$temporary" "$SUPERVISOR_PLIST"
  /bin/chmod 600 "$SUPERVISOR_PLIST"
}

start_supervisor() {
  local attempt=0
  local pid=""
  stop_supervisor_job || fail "旧的常驻进程未能安全停止。"
  write_supervisor_plist
  /bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "$SUPERVISOR_PLIST" \
    >/dev/null 2>&1 || fail "无法加载登录常驻进程。"
  while [ "$attempt" -lt 40 ]; do
    pid="$(current_supervisor_job_pid || true)"
    case "$pid" in
      ''|*[!0-9]*) ;;
      *)
        /bin/kill -0 "$pid" 2>/dev/null && return 0
        ;;
    esac
    /bin/sleep 0.25
    attempt=$((attempt + 1))
  done
  fail "常驻进程没有启动，请查看：$SUPERVISOR_ERROR_LOG"
}

remove_file_exact() {
  local target="$1"
  [ ! -f "$target" ] || /usr/bin/find "$target" -maxdepth 0 -type f -delete
}

cleanup_legacy_runtime() {
  stop_legacy_injector_job
  remove_file_exact "$LEGACY_INJECTOR_PLIST"
}

install_theme() {
  local source="$1"
  "$NODE" "$PROJECT_ROOT/scripts/theme-package.mjs" \
    install "$source" "$THEMES_ROOT"
}

inspect_theme() {
  local source="$1"
  "$NODE" "$PROJECT_ROOT/scripts/theme-package.mjs" inspect "$source"
}

ensure_theme_library() {
  local marker_temporary="$THEME_LIBRARY_MARKER.tmp.$$"

  ensure_state_root
  if [ ! -e "$THEME_LIBRARY_MARKER" ]; then
    "$NODE" "$PROJECT_ROOT/scripts/theme-package.mjs" \
      seed "$PROJECT_ROOT/presets" "$THEMES_ROOT" >/dev/null
    /usr/bin/printf '1\n' >"$marker_temporary"
    /bin/chmod 600 "$marker_temporary"
    /bin/mv "$marker_temporary" "$THEME_LIBRARY_MARKER"
  fi
  "$NODE" "$PROJECT_ROOT/scripts/theme-package.mjs" \
    list "$THEMES_ROOT" >/dev/null
}

list_themes() {
  ensure_theme_library
  "$NODE" "$PROJECT_ROOT/scripts/theme-package.mjs" list "$THEMES_ROOT"
}

ensure_skin_app_running() {
  local port="$1"
  discover_doubao_app
  verify_doubao_signature

  if cdp_ready "$port"; then
    return 0
  fi
  if doubao_interactive_is_running; then
    stop_doubao || fail "豆包未能正常退出，请手动退出后重试。"
  fi
  if ! port_is_available "$port"; then
    fail "端口 $port 已被其他程序占用。"
  fi
  launch_doubao_with_cdp "$port"
  wait_for_cdp "$port" \
    || fail "豆包没有开放经过验证的本机皮肤端口。"
}

apply_theme_directory() {
  local theme_dir="$1"
  local theme_id="$2"
  local theme_name="$3"
  local requested_conversation_opacity="${4:-}"
  local saved_port=""
  local saved_conversation_opacity=""
  local inspected_json=""
  local conversation_opacity=""

  discover_doubao_app
  verify_doubao_signature
  saved_port="$(config_value port 2>/dev/null || true)"
  case "$saved_port" in
    ''|*[!0-9]*) ;;
    *) PORT="$saved_port" ;;
  esac
  conversation_opacity="$requested_conversation_opacity"
  if [ -z "$conversation_opacity" ]; then
    saved_conversation_opacity="$(
      config_value conversationOpacity 2>/dev/null || true
    )"
    conversation_opacity="$(
      normalize_conversation_opacity "$saved_conversation_opacity" 2>/dev/null || true
    )"
  fi
  if [ -z "$conversation_opacity" ]; then
    inspected_json="$(inspect_theme "$theme_dir")"
    conversation_opacity="$("$NODE" -e '
      const value = Number(JSON.parse(process.argv[1]).conversationOpacity);
      if (!Number.isFinite(value) || value < 0 || value > 1) process.exit(1);
      process.stdout.write(String(value));
    ' "$inspected_json")" || fail "主题没有有效的对话页蒙版不透明度。"
  fi
  if ! cdp_ready "$PORT" && ! port_is_available "$PORT"; then
    PORT="$(select_available_port "$PORT")" || fail "9451–9551 没有可用端口。"
  fi

  cleanup_legacy_runtime
  stop_supervisor_job || fail "旧的常驻进程未能安全停止。"
  write_config true "$PORT" "$theme_dir" "$theme_id" "$theme_name" \
    "$conversation_opacity"
  ensure_skin_app_running "$PORT"
  "$NODE" "$INJECTOR" \
    --once --port "$PORT" --theme-dir "$theme_dir" \
    --conversation-opacity "$conversation_opacity" --timeout-ms 45000 >/dev/null
  "$NODE" "$INJECTOR" \
    --verify --port "$PORT" --theme-dir "$theme_dir" \
    --conversation-opacity "$conversation_opacity" --timeout-ms 20000 >/dev/null
  write_active_state "$PORT" "$theme_dir" "$theme_id"
  start_supervisor
  if [ -n "$requested_conversation_opacity" ]; then
    "$NODE" -e '
      process.stdout.write(`对话页蒙版透明度已调整为 ${Math.round((1 - Number(process.argv[1])) * 100)}%。\n`);
    ' "$conversation_opacity"
  else
    printf '已启用主题“%s”。豆包以后从 Dock 正常打开也会自动恢复皮肤。\n' "$theme_name"
  fi
}

enable_theme() {
  local source="$1"
  local installed_json=""
  local theme_dir=""
  local theme_id=""
  local theme_name=""

  [ -n "$source" ] || fail "请选择包含 theme.json 和背景图的主题文件夹。"
  ensure_theme_library
  installed_json="$(install_theme "$source")"
  theme_dir="$("$NODE" -e \
    'process.stdout.write(JSON.parse(process.argv[1]).directory)' "$installed_json")"
  theme_id="$("$NODE" -e \
    'process.stdout.write(JSON.parse(process.argv[1]).id)' "$installed_json")"
  theme_name="$("$NODE" -e \
    'process.stdout.write(JSON.parse(process.argv[1]).name)' "$installed_json")"
  apply_theme_directory "$theme_dir" "$theme_id" "$theme_name" \
    "$CONVERSATION_OPACITY"
}

activate_library_theme() {
  local source="$1"
  local inspected_json=""
  local theme_dir=""
  local theme_id=""
  local theme_name=""

  [ -n "$source" ] || fail "请先在主题库中选择一个有效主题。"
  ensure_theme_library
  inspected_json="$(inspect_theme "$source")"
  "$NODE" -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const theme = JSON.parse(process.argv[1]);
    const library = fs.realpathSync(process.argv[2]);
    if (path.dirname(theme.directory) !== library) process.exit(1);
  ' "$inspected_json" "$THEMES_ROOT" \
    || fail "只能启用主题库直属目录中的有效主题。"
  theme_dir="$("$NODE" -e \
    'process.stdout.write(JSON.parse(process.argv[1]).directory)' "$inspected_json")"
  theme_id="$("$NODE" -e \
    'process.stdout.write(JSON.parse(process.argv[1]).id)' "$inspected_json")"
  theme_name="$("$NODE" -e \
    'process.stdout.write(JSON.parse(process.argv[1]).name)' "$inspected_json")"
  apply_theme_directory "$theme_dir" "$theme_id" "$theme_name" \
    "$CONVERSATION_OPACITY"
}

set_conversation_opacity() {
  local enabled=""
  local active_theme=""
  [ -n "$CONVERSATION_OPACITY" ] \
    || fail "请提供 0–1 之间的对话页蒙版不透明度。"
  enabled="$(config_value enabled 2>/dev/null || true)"
  [ "$enabled" = "true" ] || fail "请先启用一个主题。"
  active_theme="$(config_value themeDir 2>/dev/null || true)"
  [ -n "$active_theme" ] || fail "当前主题配置不完整。"
  activate_library_theme "$active_theme"
}

disable_skin() {
  local port=""
  local theme_dir=""
  local theme_id=""
  local theme_name=""
  local conversation_opacity=""
  discover_doubao_app
  verify_doubao_signature
  port="$(config_value port 2>/dev/null || true)"
  theme_dir="$(config_value themeDir 2>/dev/null || true)"
  theme_id="$(config_value themeId 2>/dev/null || true)"
  theme_name="$(config_value themeName 2>/dev/null || true)"
  conversation_opacity="$(
    config_value conversationOpacity 2>/dev/null || true
  )"
  conversation_opacity="$(
    normalize_conversation_opacity "$conversation_opacity" 2>/dev/null || true
  )"
  if [ -z "$conversation_opacity" ] && [ -d "$theme_dir" ]; then
    conversation_opacity="$("$NODE" -e '
      const value = Number(JSON.parse(process.argv[1]).conversationOpacity);
      process.stdout.write(String(Number.isFinite(value) ? value : 0.60));
    ' "$(inspect_theme "$theme_dir" 2>/dev/null || printf '{}')")"
  fi
  [ -n "$conversation_opacity" ] || conversation_opacity="0.60"

  stop_supervisor_job || fail "常驻进程未能安全停止。"
  stop_legacy_injector_job
  remove_file_exact "$SUPERVISOR_PLIST"
  remove_file_exact "$LEGACY_INJECTOR_PLIST"
  case "$port" in
    ''|*[!0-9]*) ;;
    *)
      if cdp_ready "$port"; then
        "$NODE" "$INJECTOR" --remove --port "$port" --timeout-ms 10000 \
          >/dev/null 2>&1 || true
      fi
      ;;
  esac
  if doubao_interactive_is_running; then
    stop_doubao || fail "豆包未能正常退出。"
    launch_doubao_normally
  fi
  write_config false "${port:-9451}" "$theme_dir" "$theme_id" "$theme_name" \
    "$conversation_opacity"
  remove_file_exact "$STATE_PATH"
  printf '皮肤常驻已停用，豆包已恢复官方启动方式。\n'
}

open_doubao() {
  local enabled=""
  local port=""
  discover_doubao_app
  verify_doubao_signature
  enabled="$(config_value enabled 2>/dev/null || true)"
  port="$(config_value port 2>/dev/null || true)"
  if doubao_interactive_is_running; then
    /usr/bin/open -a "$DOUBAO_BUNDLE"
    return 0
  fi
  if [ "$enabled" = "true" ]; then
    case "$port" in
      ''|*[!0-9]*) fail "保存的皮肤端口无效。" ;;
    esac
    launch_doubao_with_cdp "$port"
  else
    launch_doubao_normally
  fi
}

print_status() {
  local enabled="false"
  local port=""
  local theme_dir=""
  local theme_id=""
  local theme_name=""
  local conversation_opacity=""
  local running="false"
  local skin_active="false"
  local supervisor_running="false"
  local supervisor_pid=""

  discover_doubao_app
  enabled="$(config_value enabled 2>/dev/null || printf 'false')"
  port="$(config_value port 2>/dev/null || true)"
  theme_dir="$(config_value themeDir 2>/dev/null || true)"
  theme_id="$(config_value themeId 2>/dev/null || true)"
  theme_name="$(config_value themeName 2>/dev/null || true)"
  conversation_opacity="$(
    config_value conversationOpacity 2>/dev/null || true
  )"
  conversation_opacity="$(
    normalize_conversation_opacity "$conversation_opacity" 2>/dev/null || true
  )"
  if [ -z "$conversation_opacity" ] && [ -d "$theme_dir" ]; then
    conversation_opacity="$("$NODE" -e '
      const value = Number(JSON.parse(process.argv[1]).conversationOpacity);
      process.stdout.write(String(Number.isFinite(value) ? value : 0.60));
    ' "$(inspect_theme "$theme_dir" 2>/dev/null || printf '{}')")"
  fi
  [ -n "$conversation_opacity" ] || conversation_opacity="0.60"
  doubao_interactive_is_running && running="true"
  case "$port" in
    ''|*[!0-9]*) ;;
    *) cdp_ready "$port" && skin_active="true" ;;
  esac
  supervisor_pid="$(current_supervisor_job_pid || true)"
  case "$supervisor_pid" in
    ''|*[!0-9]*) ;;
    *) supervisor_running="true" ;;
  esac
  "$NODE" - "$enabled" "$port" "$theme_dir" "$theme_id" "$theme_name" \
    "$conversation_opacity" \
    "$running" "$skin_active" "$supervisor_running" "$DOUBAO_VERSION" \
    "$DOUBAO_BUNDLE" <<'NODE'
const [
  enabled, port, themeDir, themeId, themeName, conversationOpacity, running, skinActive,
  supervisorRunning, doubaoVersion, doubaoBundle,
] = process.argv.slice(2);
process.stdout.write(`${JSON.stringify({
  schema: "doubao-skin-status/1",
  enabled: enabled === "true",
  port: /^\d+$/.test(port) ? Number(port) : null,
  themeDir: themeDir || null,
  themeId: themeId || null,
  themeName: themeName || null,
  conversationOpacity: Number(conversationOpacity),
  running: running === "true",
  skinActive: skinActive === "true",
  supervisorRunning: supervisorRunning === "true",
  doubaoVersion,
  doubaoBundle,
}, null, 2)}\n`);
NODE
}

case "$COMMAND" in
  enable)
    enable_theme "$THEME_SOURCE"
    ;;
  enable-default)
    enable_theme "$PROJECT_ROOT/presets/mbti-boy-infp"
    ;;
  activate-library)
    activate_library_theme "$THEME_SOURCE"
    ;;
  reapply)
    ACTIVE_THEME="$(config_value themeDir 2>/dev/null || true)"
    activate_library_theme "$ACTIVE_THEME"
    ;;
  set-conversation-opacity)
    set_conversation_opacity
    ;;
  disable)
    disable_skin
    ;;
  open)
    open_doubao
    ;;
  status)
    print_status
    ;;
  list-themes)
    list_themes
    ;;
  reveal-themes)
    ensure_theme_library
    /usr/bin/open "$THEMES_ROOT"
    ;;
  verify)
    ACTIVE_PORT="$(config_value port 2>/dev/null || true)"
    ACTIVE_THEME="$(config_value themeDir 2>/dev/null || true)"
    ACTIVE_CONVERSATION_OPACITY="$(
      config_value conversationOpacity 2>/dev/null || true
    )"
    ACTIVE_CONVERSATION_OPACITY="$(
      normalize_conversation_opacity "$ACTIVE_CONVERSATION_OPACITY" \
        2>/dev/null || true
    )"
    [ -n "$ACTIVE_CONVERSATION_OPACITY" ] \
      || fail "没有有效的对话页蒙版不透明度配置。"
    case "$ACTIVE_PORT" in
      ''|*[!0-9]*) fail "没有有效的皮肤配置。" ;;
    esac
    "$NODE" "$INJECTOR" \
      --verify --port "$ACTIVE_PORT" --theme-dir "$ACTIVE_THEME" \
      --conversation-opacity "$ACTIVE_CONVERSATION_OPACITY" --timeout-ms 20000
    ;;
  *) fail "未知命令：$COMMAND" ;;
esac
