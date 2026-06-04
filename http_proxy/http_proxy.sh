#!/bin/bash
# ============================================================================
# Tinyproxy HTTP 代理管理脚本
# ============================================================================
set -Euo pipefail

# ---------- 常量 ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${TINYPROXY_CONFIG:-/tmp/tinyproxy_custom.conf}"
PID_FILE="${TINYPROXY_PID:-/tmp/tinyproxy_custom.pid}"
LOG_FILE="${TINYPROXY_LOG:-/tmp/tinyproxy_custom.log}"
RUNTIME_FILE="${TINYPROXY_RUNTIME:-/tmp/tinyproxy_runtime.state}"
DEFAULT_PORT="${TINYPROXY_PORT:-8888}"
WHITELIST_URL="https://raw.githubusercontent.com/Bluepants94/script/refs/heads/main/http_proxy/whitelist"
WHITELIST_FILE="/etc/tinyproxy/whitelist"
STATE_FILE="${HOME}/.tinyproxy_mgr_state"
IP_ALLOW_FILE="/etc/tinyproxy/allow_ip.txt"

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

print_info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
print_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
print_err()   { echo -e "${RED}[ERR]${NC}   $1"; }

# ---------- 信号 ----------
cleanup_on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 130 ]; then
    print_warn "脚本异常退出，残留文件：${CONFIG_FILE}"
  fi
}
trap cleanup_on_exit EXIT
trap '' INT

# ---------- 状态（持久化） ----------
load_state() {
  IP_WHITELIST=off; DOMAIN_WHITELIST=off
  [ -f "$STATE_FILE" ] && . "$STATE_FILE"
}

save_state() {
  cat > "$STATE_FILE" <<EOF
IP_WHITELIST=${IP_WHITELIST:-off}
DOMAIN_WHITELIST=${DOMAIN_WHITELIST:-off}
EOF
}

# ---------- 运行时参数（重启时直接用，不用解析配置） ----------
save_runtime() {
  cat > "$RUNTIME_FILE" <<EOF
PROXY_PORT=${PROXY_PORT}
LISTEN_ADDR=${LISTEN_ADDR}
PROXY_USER=${PROXY_USER}
PROXY_PASS=${PROXY_PASS}
EOF
}

load_runtime() {
  if [ -f "$RUNTIME_FILE" ]; then
    . "$RUNTIME_FILE" && return 0
  fi
  PROXY_PORT="$DEFAULT_PORT"; LISTEN_ADDR="0.0.0.0"
  PROXY_USER=""; PROXY_PASS=""
  return 1
}

# ---------- 工具 ----------
die() { print_err "$1"; exit "${2:-1}"; }

check_sudo() {
  command -v sudo &>/dev/null || die "未找到 sudo 命令。"
}

detect_pkg_manager() {
  for pm in apt dnf yum pacman; do
    command -v "$pm" &>/dev/null && { echo "$pm"; return 0; }
  done
  echo ""
}

is_port_used() {
  local port="$1"
  { command -v ss &>/dev/null && ss -tln 2>/dev/null; } \
    || { command -v netstat &>/dev/null && netstat -tln 2>/dev/null; } \
    | awk -v p="$port" '$0 ~ ":"p"[[:space:]]" {exit 1}' && return 0
  return 1
}

# ---------- 文件有效性检查 ----------
filter_has_rules() {
  [ -f "$1" ] && [ -s "$1" ] || return 1
  awk 'NF>0 && !/^[[:space:]]*#/{exit 0} END{exit 1}' "$1"
}

allow_has_ips() {
  [ -f "$1" ] && [ -s "$1" ] || return 1
  awk 'NF>0 && !/^[[:space:]]*#/{exit 0} END{exit 1}' "$1"
}

# ---------- 域名白名单下载（静默） ----------
download_whitelist() {
  [ -f "$WHITELIST_FILE" ] && [ -s "$WHITELIST_FILE" ] && return 0
  check_sudo
  local tool=""; command -v curl &>/dev/null && tool="curl"
  command -v wget &>/dev/null && tool="wget"
  [ -z "$tool" ] && return 1
  sudo mkdir -p "$(dirname "$WHITELIST_FILE")" 2>/dev/null || true
  if [ "$tool" = "curl" ]; then
    sudo curl -sSL -o "$WHITELIST_FILE" "$WHITELIST_URL" 2>/dev/null || { sudo rm -f "$WHITELIST_FILE"; return 1; }
  else
    sudo wget -q -O "$WHITELIST_FILE" "$WHITELIST_URL" 2>/dev/null || { sudo rm -f "$WHITELIST_FILE"; return 1; }
  fi
  [ -s "$WHITELIST_FILE" ] && return 0 || { sudo rm -f "$WHITELIST_FILE"; return 1; }
}

# ---------- 安装 ----------
install_tinyproxy() {
  local pm; pm="$(detect_pkg_manager)"
  [ -z "$pm" ] && die "未识别包管理器，请手动安装 tinyproxy。"
  check_sudo
  print_info "通过 ${pm} 安装 tinyproxy..."
  case "$pm" in
    apt)    sudo apt update && sudo apt install -y tinyproxy ;;
    dnf)    sudo dnf install -y tinyproxy ;;
    yum)    sudo yum install -y epel-release && sudo yum install -y tinyproxy ;;
    pacman) sudo pacman -Sy --noconfirm tinyproxy ;;
  esac
  command -v tinyproxy &>/dev/null && { print_ok "tinyproxy 安装成功。"; return 0; }
  die "tinyproxy 安装失败。"
}

check_tinyproxy() {
  command -v tinyproxy &>/dev/null && return 0
  print_warn "tinyproxy 未安装，正在自动安装..."
  install_tinyproxy
}

# ---------- 非交互 ----------
load_env_params() {
  PROXY_PORT="${TINYPROXY_PORT:-${DEFAULT_PORT}}"
  [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && [ "$PROXY_PORT" -ge 1 ] && [ "$PROXY_PORT" -le 65535 ] \
    || die "TINYPROXY_PORT 无效：${PROXY_PORT}"
  LISTEN_ADDR="${TINYPROXY_LISTEN:-0.0.0.0}"
  PROXY_USER="${TINYPROXY_USER:-}"; PROXY_PASS="${TINYPROXY_PASS:-}"
}

# ---------- 配置生成 ----------
generate_config() {
  local run_user run_group
  run_user="$(id -un 2>/dev/null || echo "nobody")"
  run_group="$(id -gn 2>/dev/null || echo "nogroup")"
  {
    echo "Port ${PROXY_PORT}"
    echo "Listen ${LISTEN_ADDR}"
    echo "Timeout 600"
    echo "MaxClients 100"
    echo "LogFile \"${LOG_FILE}\""
    echo "LogLevel Info"
    echo "PidFile \"${PID_FILE}\""
    echo "DisableViaHeader Yes"
    echo "User ${run_user}"
    echo "Group ${run_group}"
    if [ -n "${PROXY_USER:-}" ] && [ -n "${PROXY_PASS:-}" ]; then
      echo "BasicAuth ${PROXY_USER} ${PROXY_PASS}"; AUTH_ENABLED=yes
    else
      AUTH_ENABLED=no
    fi

    # IP 白名单
    if [ "${IP_WHITELIST:-off}" = "on" ] && allow_has_ips "$IP_ALLOW_FILE"; then
      awk 'NF>0 && !/^[[:space:]]*#/{print "Allow",$0}' "$IP_ALLOW_FILE"
    fi

    # 域名白名单
    if [ "${DOMAIN_WHITELIST:-off}" = "on" ] && filter_has_rules "$WHITELIST_FILE"; then
      echo "Filter \"${WHITELIST_FILE}\""
      echo "FilterDefaultDeny Yes"
    fi
  } > "$CONFIG_FILE"
}

# ---------- 进程管理 ----------
graceful_kill() {
  local pid="$1" w="${2:-5}" c=0
  kill "$pid" 2>/dev/null || return 0
  while [ "$c" -lt "$w" ]; do
    kill -0 "$pid" 2>/dev/null || return 0; sleep 1; c=$((c+1))
  done
  kill -9 "$pid" 2>/dev/null || true
}

# ---------- 启动 ----------
start_proxy() {
  check_tinyproxy; load_state
  if [ "${1:-}" = "--env" ]; then load_env_params; else load_runtime || { PROXY_PORT="$DEFAULT_PORT"; LISTEN_ADDR="0.0.0.0"; PROXY_USER=""; PROXY_PASS=""; }; fi
  is_port_used "$PROXY_PORT" && die "端口 ${PROXY_PORT} 已被占用。"
  [ "$DOMAIN_WHITELIST" = "on" ] && download_whitelist || true
  command -v systemctl &>/dev/null && sudo systemctl stop tinyproxy 2>/dev/null || true
  generate_config; save_runtime
  tinyproxy -c "$CONFIG_FILE" || die "tinyproxy 启动失败。"
  local pid="" c=0
  while [ ! -f "$PID_FILE" ] && [ "$c" -lt 3 ]; do sleep 1; c=$((c+1)); done
  [ -f "$PID_FILE" ] && pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "${pid:-}" ] && kill -0 "${pid}" 2>/dev/null; then
    status_proxy
  else
    tail -5 "$LOG_FILE" 2>/dev/null || true
    die "代理启动失败：${LOG_FILE}"
  fi
}

# ---------- 停止 ----------
stop_proxy() {
  local pid="" ok=false
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [ -n "${pid:-}" ] && kill -0 "${pid}" 2>/dev/null && { graceful_kill "$pid"; ok=true; }
  fi
  if ! $ok; then
    local p; p="$(pgrep -f "tinyproxy.*${CONFIG_FILE}" 2>/dev/null || true)"
    [ -n "$p" ] && while IFS= read -r pid; do [ -n "$pid" ] && graceful_kill "$pid"; done <<< "$p"
  fi
  rm -f "$CONFIG_FILE" "$PID_FILE" "$LOG_FILE" "$RUNTIME_FILE"
}

# ---------- 重启（从 runtime 文件读参数，不解析配置） ----------
restart_proxy() {
  local pid=""
  [ -f "$PID_FILE" ] && pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [ -z "${pid:-}" ] || ! kill -0 "${pid}" 2>/dev/null && { print_warn "代理未运行，无需重启。"; return 1; }

  load_runtime || { print_warn "未找到运行时参数，无法重启。"; return 1; }
  load_state
  [ "$DOMAIN_WHITELIST" = "on" ] && download_whitelist || true

  graceful_kill "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"; sleep 1
  generate_config
  tinyproxy -c "$CONFIG_FILE" || { print_warn "重启失败。"; return 1; }

  local c=0
  while [ ! -f "$PID_FILE" ] && [ "$c" -lt 5 ]; do sleep 1; c=$((c+1)); done
  [ ! -f "$PID_FILE" ] && { print_warn "新进程未生成 PID 文件。"; return 1; }
  local np; np="$(cat "$PID_FILE" 2>/dev/null || true)"
  [ -z "${np:-}" ] || ! kill -0 "${np}" 2>/dev/null && { print_warn "新进程未运行。"; return 1; }
  return 0
}

# ---------- 重载 ----------
reload_proxy() {
  local pid=""
  [ -f "$PID_FILE" ] && pid="$(cat "$PID_FILE" 2>/dev/null || true)" || true
  [ -z "${pid:-}" ] || ! kill -0 "${pid}" 2>/dev/null && { print_warn "代理未运行，无需重载。"; return 1; }

  # 重新生成配置，然后重载
  load_runtime 2>/dev/null || { PROXY_PORT="$DEFAULT_PORT"; LISTEN_ADDR="0.0.0.0"; }
  load_state
  generate_config

  check_sudo
  if command -v systemctl &>/dev/null; then
    sudo systemctl reload tinyproxy 2>/dev/null && { print_ok "代理配置已重载。"; return 0; }
  fi
  kill -HUP "$pid" 2>/dev/null && { print_ok "代理配置已重载。"; return 0; }
  print_err "重载失败。"
  return 1
}

# ---------- 状态 ----------
status_proxy() {
  local pid=""
  [ -f "$PID_FILE" ] && pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "${pid:-}" ] && kill -0 "${pid}" 2>/dev/null && [ -f "$CONFIG_FILE" ]; then
    local port listen
    port="$(   awk '/^Port[[:space:]]+/{print $2;exit}'     "$CONFIG_FILE" 2>/dev/null || echo "?")"
    listen="$( awk '/^Listen[[:space:]]+/{print $2;exit}'   "$CONFIG_FILE" 2>/dev/null || echo "?")"
    print_ok "代理运行中 — ${listen}:${port}"
    return 0
  fi
  return 1
}

# ---------- 开关 ----------
toggle_ip_whitelist() {
  load_state
  if [ "$IP_WHITELIST" = "on" ]; then
    IP_WHITELIST=off; save_state; reload_proxy; return
  fi
  check_sudo
  [ -d /etc/tinyproxy ] || sudo mkdir -p /etc/tinyproxy 2>/dev/null || true
  if [ ! -f "$IP_ALLOW_FILE" ]; then
    sudo tee "$IP_ALLOW_FILE" >/dev/null <<'EOF'
# 每行一个 IP 或 CIDR
# 例如: 192.168.1.0/24

EOF
  fi
  IP_WHITELIST=on; save_state; reload_proxy
}

toggle_domain_whitelist() {
  load_state
  if [ "$DOMAIN_WHITELIST" = "on" ]; then
    DOMAIN_WHITELIST=off; save_state; reload_proxy; return
  fi
  if download_whitelist; then
    DOMAIN_WHITELIST=on; save_state; reload_proxy
  fi
}

# ---------- UI ----------
show_banner() {
  load_state
  local ps="" pi="" pid=""
  [ -f "$PID_FILE" ] && pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "${pid:-}" ] && kill -0 "${pid}" 2>/dev/null && [ -f "$CONFIG_FILE" ]; then
    local p; p="$(awk '/^Port/{print $2;exit}' "$CONFIG_FILE" 2>/dev/null || echo "?")"
    local l; l="$(awk '/^Listen/{print $2;exit}' "$CONFIG_FILE" 2>/dev/null || echo "?")"
    ps="● 已启动"; pi="  监听:       ${l}:${p}"
  fi
  echo ""
  echo "=================================================="
  echo "        Tinyproxy HTTP 代理管理工具"
  echo "=================================================="
  echo "  配置路径:   /etc/tinyproxy"
  echo -e "  代理状态:   $([ -n "${pid:-}" ] && kill -0 "${pid}" 2>/dev/null && echo "${GREEN}${ps}${NC}" || echo "${RED}○ 未启动${NC}")"
  [ -n "$pi" ] && echo "$pi"
  echo -e "  IP 白名单:  $( [ "${IP_WHITELIST:-off}" = on ] && echo "${GREEN}● 已开启${NC}" || echo "${RED}○ 未开启${NC}")"
  echo -e "  域名白名单: $( [ "${DOMAIN_WHITELIST:-off}" = on ] && echo "${GREEN}● 已开启${NC}" || echo "${RED}○ 未开启${NC}")"
}

show_menu() {
  local r=false pid=""
  [ -f "$PID_FILE" ] && pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [ -n "${pid:-}" ] && kill -0 "${pid}" 2>/dev/null && r=true
  echo ""
  echo "  1) $($r && echo '关闭' || echo '开启')代理"
  echo "  2) $( [ "${IP_WHITELIST:-off}" = on ] && echo '关闭' || echo '开启')IP白名单"
  echo "  3) $( [ "${DOMAIN_WHITELIST:-off}" = on ] && echo '关闭' || echo '开启')域名白名单"
  echo "  4) 重载代理"
  echo "  0) 退出"
  printf "输入选项 [0-4]: "
}

run_ui() {
  # 首次进入：后台静默下载白名单文件
  [ -f "$WHITELIST_FILE" ] && [ -s "$WHITELIST_FILE" ] || (download_whitelist &>/dev/null &)

  while true; do
    show_banner; show_menu
    IFS= read -r c
    case "${c}" in
      1)
        local r=false pid=""
        [ -f "$PID_FILE" ] && pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        [ -n "${pid:-}" ] && kill -0 "${pid}" 2>/dev/null && r=true
        if $r; then stop_proxy
        else
          load_runtime 2>/dev/null || true
          TINYPROXY_PORT="${PROXY_PORT:-$DEFAULT_PORT}"
          TINYPROXY_LISTEN="${LISTEN_ADDR:-0.0.0.0}"
          TINYPROXY_USER="${PROXY_USER:-}"
          TINYPROXY_PASS="${PROXY_PASS:-}"
          start_proxy --env || true
        fi
        continue ;;
      2) toggle_ip_whitelist      ; continue ;;
      3) toggle_domain_whitelist  ; continue ;;
      4) reload_proxy             ; continue ;;
      0) exit 0 ;;
      *) continue ;;
    esac
  done
}

# ---------- 入口 ----------
main() {
  case "${1:-}" in
    start|--start) shift; check_tinyproxy; load_state
      [ "$DOMAIN_WHITELIST" = "on" ] && download_whitelist || true
      start_proxy --env ;;
    stop|--stop) stop_proxy ;;
    status|--status) load_state; status_proxy ;;
    --help|-h|help)
      echo "用法: $0 [start|stop|status|--help]"
      echo "  (无参数)   交互菜单"
      echo "  start      TINYPROXY_PORT|LISTEN|USER|PASS 环境变量启动"
      echo "  stop       非交互关闭"
      echo "  status     查看状态"
      echo ""
      echo "持久化: ${STATE_FILE} | IP: ${IP_ALLOW_FILE} | 域名: ${WHITELIST_FILE}" ;;
    *) run_ui ;;
  esac
}

main "$@"









