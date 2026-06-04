#!/bin/bash
# ============================================================================
# Tinyproxy HTTP 代理管理脚本
# 功能：检查/安装 tinyproxy → 配置并启动代理 → 关闭并清理
# 用法：
#   ./http_proxy.sh             交互菜单模式
#   ./http_proxy.sh start       非交互启动（环境变量传参）
#   ./http_proxy.sh stop        非交互关闭
#   ./http_proxy.sh status      查看状态
# ============================================================================
set -Euo pipefail

# ---------- 常量 ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${TINYPROXY_CONFIG:-/tmp/tinyproxy_custom.conf}"
PID_FILE="${TINYPROXY_PID:-/tmp/tinyproxy_custom.pid}"
LOG_FILE="${TINYPROXY_LOG:-/tmp/tinyproxy_custom.log}"
DEFAULT_PORT="${TINYPROXY_PORT:-8888}"
FILTER_URL="https://raw.githubusercontent.com/Bluepants94/script/refs/heads/main/http_proxy/tinyproxy_filter.txt"
FILTER_FILE="${SCRIPT_DIR}/tinyproxy_filter.txt"
STATE_FILE="${HOME}/.tinyproxy_mgr_state"
IP_ALLOW_FILE="/etc/tinyproxy/allow_ip.txt"

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

print_info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
print_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
print_err()   { echo -e "${RED}[ERR]${NC}   $1"; }

# ---------- 信号/状态管理 ----------
cleanup_on_exit() {
  local exit_code=$?
  if [ "$exit_code" -ne 0 ] && [ "$exit_code" -ne 130 ]; then
    print_warn "脚本异常退出，残留文件：${CONFIG_FILE}"
  fi
}
trap cleanup_on_exit EXIT
trap '' INT

load_state() {
  IP_WHITELIST=off
  DOMAIN_WHITELIST=off
  [ -f "$STATE_FILE" ] && . "$STATE_FILE"
}

save_state() {
  cat > "$STATE_FILE" <<EOF
IP_WHITELIST=${IP_WHITELIST:-off}
DOMAIN_WHITELIST=${DOMAIN_WHITELIST:-off}
EOF
}

# ---------- 工具函数 ----------
die() { print_err "$1"; exit "${2:-1}"; }

check_sudo() {
  if ! command -v sudo &>/dev/null; then
    die "未找到 sudo 命令，请安装 sudo 或手动安装 tinyproxy。"
  fi
}

detect_pkg_manager() {
  for pm in apt dnf yum pacman; do
    command -v "$pm" &>/dev/null && { echo "$pm"; return 0; }
  done
  echo ""
}

is_port_used() {
  local port="$1"
  if command -v ss &>/dev/null; then
    ss -tln 2>/dev/null | grep -qP "[: ]${port}\b" && return 0 || return 1
  fi
  if command -v netstat &>/dev/null; then
    netstat -tln 2>/dev/null | grep -qP "[: ]${port}\b" && return 0 || return 1
  fi
  return 1
}

# ---------- 静默下载域名白名单 ----------
download_filter() {
  [ -s "$FILTER_FILE" ] && return 0
  local tool=""
  command -v curl &>/dev/null && tool="curl"
  command -v wget &>/dev/null && tool="wget"
  [ -z "$tool" ] && return 1
  if [ "$tool" = "curl" ]; then
    curl -sSL -o "$FILTER_FILE" "$FILTER_URL" 2>/dev/null || { rm -f "$FILTER_FILE"; return 1; }
  else
    wget -q -O "$FILTER_FILE" "$FILTER_URL" 2>/dev/null || { rm -f "$FILTER_FILE"; return 1; }
  fi
  [ -s "$FILTER_FILE" ] && return 0 || { rm -f "$FILTER_FILE"; return 1; }
}

# ---------- 检查过滤文件是否有有效规则（非空行/非注释） ----------
filter_has_rules() {
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    line="$(echo "$line" | xargs)"
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue
    return 0
  done < "$1"
  return 1
}

# ---------- 检查 IP allow 文件是否有有效 IP ----------
allow_has_ips() {
  [ -f "$1" ] || return 1
  [ -s "$1" ] || return 1
  while IFS= read -r line; do
    line="$(echo "$line" | xargs)"
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue
    return 0
  done < "$1"
  return 1
}

# ---------- 安装 ----------
install_tinyproxy() {
  local pm
  pm="$(detect_pkg_manager)"
  [ -z "$pm" ] && die "未识别到支持的包管理器，请手动安装 tinyproxy。"
  check_sudo
  print_info "通过 ${pm} 安装 tinyproxy（需要 sudo 权限）..."
  case "$pm" in
    apt) sudo apt update && sudo apt install -y tinyproxy ;;
    dnf) sudo dnf install -y tinyproxy ;;
    yum) sudo yum install -y epel-release && sudo yum install -y tinyproxy ;;
    pacman) sudo pacman -Sy --noconfirm tinyproxy ;;
  esac
  command -v tinyproxy &>/dev/null && { print_ok "tinyproxy 安装成功。"; return 0; }
  die "tinyproxy 安装失败。"
}

check_tinyproxy() {
  command -v tinyproxy &>/dev/null && return 0
  print_warn "tinyproxy 未安装。"
  read -r -p "是否立即自动安装 tinyproxy? (y/N): " choice
  [[ "$choice" =~ ^[Yy]$ ]] || die "用户取消安装。"
  install_tinyproxy
}

# ---------- 交互参数 ----------
prompt_start_params() {
  local input_port listen_choice custom_ip
  read -r -p "请输入代理端口 (默认 ${DEFAULT_PORT}): " input_port
  PROXY_PORT="${input_port:-$DEFAULT_PORT}"
  [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && [ "$PROXY_PORT" -ge 1 ] && [ "$PROXY_PORT" -le 65535 ] \
    || die "端口无效：${PROXY_PORT}"
  echo ""
  echo "请选择监听地址:"
  echo "  1) 0.0.0.0 (所有网卡，允许外部访问) [默认]"
  echo "  2) 127.0.0.1 (仅本地访问)"
  echo "  3) 自定义IP"
  read -r -p "输入选项 [1-3](默认 1): " listen_choice
  case "${listen_choice:-1}" in
    2) LISTEN_ADDR="127.0.0.1" ;;
    3)
      read -r -p "请输入自定义监听IP: " custom_ip
      [ -n "$custom_ip" ] || die "监听IP不能为空"
      LISTEN_ADDR="$custom_ip"
      ;;
    *) LISTEN_ADDR="0.0.0.0" ;;
  esac
  read -r -p "请输入用户名 (可留空): " PROXY_USER
  read -r -s -p "请输入密码 (可留空，输入不可见): " PROXY_PASS
  echo ""
}

# ---------- 非交互参数（环境变量） ----------
load_env_params() {
  PROXY_PORT="${TINYPROXY_PORT:-${DEFAULT_PORT}}"
  [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && [ "$PROXY_PORT" -ge 1 ] && [ "$PROXY_PORT" -le 65535 ] \
    || die "TINYPROXY_PORT 无效：${PROXY_PORT}"
  LISTEN_ADDR="${TINYPROXY_LISTEN:-0.0.0.0}"
  PROXY_USER="${TINYPROXY_USER:-}"
  PROXY_PASS="${TINYPROXY_PASS:-}"
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
      echo "BasicAuth ${PROXY_USER} ${PROXY_PASS}"
      AUTH_ENABLED="yes"
    else
      AUTH_ENABLED="no"
    fi
    # IP 白名单 - 控制谁能连接
    if [ "$IP_WHITELIST" = "on" ]; then
      if allow_has_ips "$IP_ALLOW_FILE"; then
        while IFS= read -r line; do
          line="$(echo "$line" | xargs)"
          [ -z "$line" ] && continue
          [[ "$line" == \#* ]] && continue
          echo "Allow ${line}"
        done < "$IP_ALLOW_FILE"
      fi
    fi
    # 域名白名单 - 控制能访问的目标
    if [ "$DOMAIN_WHITELIST" = "on" ]; then
      if filter_has_rules "$FILTER_FILE"; then
        echo "Filter \"${FILTER_FILE}\""
        echo "FilterDefaultDeny Yes"
      fi
    fi
  } > "$CONFIG_FILE"
}

# ---------- 优雅关闭进程 ----------
graceful_kill() {
  local pid="$1" max_wait="${2:-5}" waited=0
  kill "$pid" 2>/dev/null || return 0
  while [ "$waited" -lt "$max_wait" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
    waited=$((waited + 1))
  done
  kill -9 "$pid" 2>/dev/null || true
}

# ---------- 启动 ----------
start_proxy() {
  check_tinyproxy
  load_state
  if [ "${1:-}" = "--env" ]; then
    load_env_params
  else
    prompt_start_params || return 1
  fi
  is_port_used "$PROXY_PORT" && die "端口 ${PROXY_PORT} 已被占用。"
  if [ "$DOMAIN_WHITELIST" = "on" ]; then
    download_filter || true
  fi
  if command -v systemctl &>/dev/null; then
    sudo systemctl stop tinyproxy 2>/dev/null || true
  fi
  generate_config
  tinyproxy -c "$CONFIG_FILE" || die "tinyproxy 启动失败。"
  local pid="" waited=0
  while [ ! -f "$PID_FILE" ] && [ "$waited" -lt 3 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  [ -f "$PID_FILE" ] && pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    print_ok "代理已启动。"
    echo "--------------------------------------------------"
    echo "  监听地址: ${LISTEN_ADDR}"
    echo "  端口:     ${PROXY_PORT}"
    echo "  认证:     $( [ "$AUTH_ENABLED" = yes ] && echo '已启用' || echo '未启用' )"
    if [ "$AUTH_ENABLED" = yes ]; then
      echo "  代理地址: http://${PROXY_USER}:${PROXY_PASS}@<服务器IP>:${PROXY_PORT}"
    else
      echo "  代理地址: http://<服务器IP>:${PROXY_PORT}"
    fi
    echo "  IP白名单:  $( [ "$IP_WHITELIST" = on ] && echo '已开启' || echo '未开启' )"
    echo "  域名白名单: $( [ "$DOMAIN_WHITELIST" = on ] && echo '已开启' || echo '未开启' )"
    echo "--------------------------------------------------"
  else
    tail -5 "$LOG_FILE" 2>/dev/null || true
    die "代理启动失败，请检查日志：${LOG_FILE}"
  fi
}

# ---------- 停止（静默） ----------
stop_proxy() {
  local pid="" stopped=false
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      graceful_kill "$pid"
      stopped=true
    fi
  fi
  if ! "$stopped"; then
    local pids
    pids="$(pgrep -f "tinyproxy.*${CONFIG_FILE}" 2>/dev/null || true)"
    if [ -n "$pids" ]; then
      while IFS= read -r pid; do
        [ -n "$pid" ] && graceful_kill "$pid"
      done <<< "$pids"
    fi
  fi
  rm -f "$CONFIG_FILE" "$PID_FILE" "$LOG_FILE"
}

# ---------- 重启（沿用当前参数 + 最新白名单状态） ----------
restart_proxy() {
  local pid="" running=false
  [ -f "$PID_FILE" ] && pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [ -n "${pid:-}" ] && kill -0 "${pid}" 2>/dev/null && running=true
  if ! $running; then
    return 0
  fi

  # 从当前配置读取参数
  local old_port old_listen old_user old_pass
  if [ -f "$CONFIG_FILE" ]; then
    old_port="$(grep -oP '^Port\s+\K[0-9]+' "$CONFIG_FILE" 2>/dev/null || true)"
    old_listen="$(grep -oP '^Listen\s+\K\S+' "$CONFIG_FILE" 2>/dev/null || true)"
    local auth_line
    auth_line="$(grep '^BasicAuth' "$CONFIG_FILE" 2>/dev/null || true)"
    if [ -n "$auth_line" ]; then
      old_user="$(echo "$auth_line" | awk '{print $2}')"
      old_pass="$(echo "$auth_line" | awk '{print $3}')"
    fi
  fi
  PROXY_PORT="${old_port:-$DEFAULT_PORT}"
  LISTEN_ADDR="${old_listen:-0.0.0.0}"
  PROXY_USER="${old_user:-}"
  PROXY_PASS="${old_pass:-}"

  load_state

  if [ "$DOMAIN_WHITELIST" = "on" ]; then
    download_filter || true
  fi

  graceful_kill "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  sleep 1

  generate_config
  tinyproxy -c "$CONFIG_FILE" || { print_warn "重启失败，端口可能未释放。"; return 1; }

  local new_pid="" waited=0
  while [ ! -f "$PID_FILE" ] && [ "$waited" -lt 5 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  [ -f "$PID_FILE" ] && new_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -z "$new_pid" ] || ! kill -0 "$new_pid" 2>/dev/null; then
    print_warn "重启后新进程未能确认运行。"
    return 1
  fi
  return 0
}

# ---------- 状态 ----------
status_proxy() {
  local pid="" port="" listen=""
  [ -f "$PID_FILE" ] && pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    port="$(   grep -oP '^Port\s+\K[0-9]+'   "$CONFIG_FILE" 2>/dev/null || echo "?")"
    listen="$( grep -oP '^Listen\s+\K\S+'    "$CONFIG_FILE" 2>/dev/null || echo "?")"
    print_ok "代理运行中 — ${listen}:${port}"
    return 0
  fi
  return 1
}

# ---------- IP 白名单开关（静默） ----------
toggle_ip_whitelist() {
  load_state
  if [ "$IP_WHITELIST" = "on" ]; then
    IP_WHITELIST=off
    save_state
    restart_proxy
    return 0
  fi
  check_sudo
  if [ ! -d "/etc/tinyproxy" ]; then
    sudo mkdir -p /etc/tinyproxy 2>/dev/null || true
  fi
  if [ ! -f "$IP_ALLOW_FILE" ]; then
    sudo tee "$IP_ALLOW_FILE" > /dev/null <<'EOF'
# /etc/tinyproxy/allow_ip.txt
# 每行一个 IP 或 CIDR，允许访问此 HTTP 代理
# 修改后需要重启代理才能生效
# 示例:
# 192.168.1.100
# 10.0.0.0/8
# 172.16.0.0/12

192.168.1.0/24
EOF
  fi
  IP_WHITELIST=on
  save_state
  restart_proxy
}

# ---------- 域名白名单开关（静默） ----------
toggle_domain_whitelist() {
  load_state
  if [ "$DOMAIN_WHITELIST" = "on" ]; then
    DOMAIN_WHITELIST=off
    save_state
    restart_proxy
    return 0
  fi
  if download_filter; then
    DOMAIN_WHITELIST=on
    save_state
    restart_proxy
  fi
}

# ---------- 菜单 UI ----------
show_banner() {
  load_state
  local proxy_status proxy_pid="" proxy_info=""
  [ -f "$PID_FILE" ] && proxy_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "${proxy_pid:-}" ] && kill -0 "${proxy_pid}" 2>/dev/null; then
    local p port="?"
    p="$(grep -oP '^Port\s+\K[0-9]+' "$CONFIG_FILE" 2>/dev/null || true)"
    [ -n "$p" ] && port="$p"
    proxy_status="● 已启动"
    proxy_info="  监听:       $(grep -oP '^Listen\s+\K\S+' "$CONFIG_FILE" 2>/dev/null || echo '?'):${port}"
  fi
  echo ""
  echo "=================================================="
  echo "        Tinyproxy HTTP 代理管理工具"
  echo "=================================================="
  echo "  配置路径:   /etc/tinyproxy"
  echo -e "  代理状态:   $([ -n "${proxy_pid:-}" ] && kill -0 "${proxy_pid}" 2>/dev/null && echo "${GREEN}${proxy_status}${NC}" || echo "${RED}○ 未启动${NC}")"
  [ -n "$proxy_info" ] && echo "$proxy_info"
  echo -e "  IP 白名单:  $( [ "$IP_WHITELIST" = on ] && echo "${GREEN}● 已开启${NC}" || echo "${RED}○ 未开启${NC}")"
  echo -e "  域名白名单: $( [ "$DOMAIN_WHITELIST" = on ] && echo "${GREEN}● 已开启${NC}" || echo "${RED}○ 未开启${NC}")"
}

show_menu() {
  local proxy_running=false
  local pid=""
  [ -f "$PID_FILE" ] && pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [ -n "${pid:-}" ] && kill -0 "${pid}" 2>/dev/null && proxy_running=true
  echo ""
  if $proxy_running; then
    echo "  1) 关闭代理"
  else
    echo "  1) 开启代理"
  fi
  echo "  2) $([ "$IP_WHITELIST" = on ] && echo '关闭' || echo '开启')IP白名单"
  echo "  3) $([ "$DOMAIN_WHITELIST" = on ] && echo '关闭' || echo '开启')域名白名单"
  echo "  0) 退出"
  echo -n "输入选项 [0-3]: "
}

run_ui() {
  while true; do
    show_banner
    show_menu
    read -r choice
    case "${choice}" in
      1)
        local proxy_running=false
        local pid=""
        [ -f "$PID_FILE" ] && pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        [ -n "${pid:-}" ] && kill -0 "${pid}" 2>/dev/null && proxy_running=true
        if $proxy_running; then
          stop_proxy
        else
          start_proxy || true
        fi
        continue
        ;;
      2)
        toggle_ip_whitelist
        continue
        ;;
      3)
        toggle_domain_whitelist
        continue
        ;;
      0)
        exit 0
        ;;
      *)
        continue
        ;;
    esac
  done
}

# ---------- 入口 ----------
main() {
  case "${1:-}" in
    start|--start)
      shift
      check_tinyproxy
      load_state
      load_env_params
      if [ "$DOMAIN_WHITELIST" = "on" ]; then
        download_filter || true
      fi
      start_proxy --env
      ;;
    stop|--stop)
      stop_proxy
      ;;
    status|--status)
      load_state
      status_proxy
      ;;
    --help|-h|help)
      echo "用法：$0 [start|stop|status|--help]"
      echo "  无参数     交互菜单模式"
      echo "  start      非交互启动（环境变量 TINYPROXY_* 传参）"
      echo "  stop       非交互关闭"
      echo "  status     查看代理运行状态"
      echo ""
      echo "环境变量:"
      echo "  TINYPROXY_PORT      端口号（默认 8888）"
      echo "  TINYPROXY_LISTEN    监听地址（默认 0.0.0.0）"
      echo "  TINYPROXY_USER      认证用户名"
      echo "  TINYPROXY_PASS      认证密码"
      echo ""
      echo "白名单状态持久化到: ${STATE_FILE}"
      echo "IP 白名单文件:       ${IP_ALLOW_FILE}"
      echo "域名白名单文件:      ${FILTER_FILE}"
      ;;
    *)
      run_ui
      ;;
  esac
}

main "$@"
