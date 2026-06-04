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
CONFIG_FILE="${TINYPROXY_CONFIG:-/tmp/tinyproxy_custom.conf}"
PID_FILE="${TINYPROXY_PID:-/tmp/tinyproxy_custom.pid}"
LOG_FILE="${TINYPROXY_LOG:-/tmp/tinyproxy_custom.log}"
DEFAULT_PORT="${TINYPROXY_PORT:-8888}"

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

print_info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
print_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
print_err()   { echo -e "${RED}[ERR]${NC}   $1"; }

# ---------- 信号处理 ----------
cleanup_on_exit() {
  local exit_code=$?
  if [ "$exit_code" -ne 0 ] && [ "$exit_code" -ne 130 ]; then
    print_warn "脚本异常退出，残留文件：${CONFIG_FILE}"
  fi
}
trap cleanup_on_exit EXIT
trap '' INT

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
    ss -tln 2>/dev/null | grep -qP "[: ]${port}\b"
    return $?
  fi
  if command -v netstat &>/dev/null; then
    netstat -tln 2>/dev/null | grep -qP "[: ]${port}\b"
    return $?
  fi
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

# ---------- 交互参数（所有输入页均支持 0=返回） ----------
prompt_start_params() {
  local input_port listen_choice custom_ip

  # 端口输入
  read -r -p "请输入代理端口 (默认 ${DEFAULT_PORT}，输入 0 返回): " input_port
  if [ "${input_port:-}" = "0" ]; then
    print_info "已返回。"
    return 1
  fi
  PROXY_PORT="${input_port:-$DEFAULT_PORT}"
  [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && [ "$PROXY_PORT" -ge 1 ] && [ "$PROXY_PORT" -le 65535 ] \
    || die "端口无效：${PROXY_PORT}"

  # 监听地址选择
  echo ""
  echo "请选择监听地址:"
  echo "  1) 0.0.0.0 (所有网卡，允许外部访问) [默认]"
  echo "  2) 127.0.0.1 (仅本地访问)"
  echo "  3) 自定义IP"
  echo "  0) 返回"
  read -r -p "输入选项 [0-3]: " listen_choice
  case "${listen_choice}" in
    0) print_info "已返回。"; return 1 ;;
    2) LISTEN_ADDR="127.0.0.1" ;;
    3)
      read -r -p "请输入自定义监听IP (输入 0 返回): " custom_ip
      if [ "${custom_ip:-}" = "0" ]; then print_info "已返回。"; return 1; fi
      [ -n "$custom_ip" ] || die "监听IP不能为空"
      LISTEN_ADDR="$custom_ip"
      ;;
    *) LISTEN_ADDR="0.0.0.0" ;;
  esac

  # 用户名
  read -r -p "请输入用户名 (可留空，输入 0 返回): " PROXY_USER
  if [ "${PROXY_USER:-}" = "0" ]; then
    print_info "已返回。"
    return 1
  fi

  # 密码（不回显）
  read -r -s -p "请输入密码 (可留空，输入 0 返回): " PROXY_PASS
  echo ""
  if [ "${PROXY_PASS:-}" = "0" ]; then
    print_info "已返回。"
    return 1
  fi

  # IP 白名单
  echo ""
  print_info "IP 白名单设置（留空则允许所有IP访问）"
  print_info "多个IP用空格分隔，支持 CIDR 格式（如 192.168.1.0/24）"
  read -r -p "请输入允许访问的IP (输入 0 返回): " ALLOW_IPS
  if [ "${ALLOW_IPS:-}" = "0" ]; then
    print_info "已返回。"
    return 1
  fi
}

# ---------- 非交互参数（环境变量） ----------
load_env_params() {
  PROXY_PORT="${TINYPROXY_PORT:-${DEFAULT_PORT}}"
  [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] && [ "$PROXY_PORT" -ge 1 ] && [ "$PROXY_PORT" -le 65535 ] \
    || die "TINYPROXY_PORT 无效：${PROXY_PORT}"

  LISTEN_ADDR="${TINYPROXY_LISTEN:-0.0.0.0}"
  PROXY_USER="${TINYPROXY_USER:-}"
  PROXY_PASS="${TINYPROXY_PASS:-}"
  ALLOW_IPS="${TINYPROXY_ALLOW_IPS:-}"
}

# ---------- 配置生成 ----------
generate_config() {
  local run_user run_group
  run_user="$(id -un 2>/dev/null || echo "nobody")"
  run_group="$(id -gn 2>/dev/null || echo "nogroup")"

  # 一次性写入完整配置（已移除新版 Tinyproxy 废弃的 StartServers / MinSpareServers / MaxSpareServers / MaxRequestsPerChild）
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

    if [ -n "${ALLOW_IPS:-}" ]; then
      for ip in ${ALLOW_IPS}; do
        echo "Allow ${ip}"
      done
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
  print_warn "进程 ${pid} 未能优雅退出，已强制终止。"
}

# ---------- 启动 ----------
start_proxy() {
  check_tinyproxy

  if [ "${1:-}" = "--env" ]; then
    load_env_params
  else
    prompt_start_params || return 1
  fi

  is_port_used "$PROXY_PORT" && die "端口 ${PROXY_PORT} 已被占用。"

  if command -v systemctl &>/dev/null; then
    sudo systemctl stop tinyproxy 2>/dev/null || true
  fi

  generate_config

  print_info "正在启动 tinyproxy..."
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
    echo "  白名单:   ${ALLOW_IPS:-未启用（允许所有IP）}"
    echo "  PID:      ${pid}"
    echo "--------------------------------------------------"
  else
    tail -5 "$LOG_FILE" 2>/dev/null || true
    die "代理启动失败，请检查日志：${LOG_FILE}"
  fi
}

# ---------- 停止 ----------
stop_proxy() {
  local pid="" stopped=false

  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      graceful_kill "$pid"
      print_ok "tinyproxy 已停止（PID: ${pid}）。"
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
      print_ok "tinyproxy 进程已停止（通过进程匹配）。"
    else
      print_warn "未发现运行中的自定义 tinyproxy 进程。"
    fi
  fi

  rm -f "$CONFIG_FILE" "$PID_FILE" "$LOG_FILE"
  print_ok "临时文件已清理。"
}

# ---------- 状态 ----------
status_proxy() {
  local pid="" port="" listen=""
  [ -f "$PID_FILE" ] && pid="$(cat "$PID_FILE" 2>/dev/null || true)"

  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    port="$(   grep -oP '^Port\s+\K[0-9]+'   "$CONFIG_FILE" 2>/dev/null || echo "?")"
    listen="$( grep -oP '^Listen\s+\K\S+'    "$CONFIG_FILE" 2>/dev/null || echo "?")"
    print_ok "代理运行中 — PID: ${pid}  监听: ${listen}:${port}"
  else
    print_warn "代理未运行。"
    return 1
  fi
}

# ---------- 菜单 UI ----------
show_banner() {
  echo ""
  echo "=================================================="
  echo "        Tinyproxy HTTP 代理管理工具"
  echo "=================================================="
  status_proxy &>/dev/null \
    && echo -e "  代理状态: ${GREEN}● 已启动${NC}" \
    || echo -e "  代理状态: ${RED}○ 未启动${NC}"
}

show_menu() {
  echo ""
  echo "  1) 开启代理"
  echo "  2) 关闭代理"
  echo "  3) 查看状态"
  echo "  0) 退出"
  echo -n "输入选项 [0-3]: "
}

run_ui() {
  while true; do
    show_banner
    show_menu
    read -r choice
    case "${choice}" in
      1) start_proxy || true ;;
      2) stop_proxy  || true ;;
      3) status_proxy || true ;;
      0) print_ok "已退出。"; exit 0 ;;
      *) print_warn "无效选项，请输入 0-3。" ;;
    esac
    echo ""
    read -r -p "按回车键继续..." _
  done
}

# ---------- 入口 ----------
main() {
  case "${1:-}" in
    start|--start)
      shift
      check_tinyproxy
      load_env_params
      start_proxy --env
      ;;
    stop|--stop)
      stop_proxy
      ;;
    status|--status)
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
      echo "  TINYPROXY_ALLOW_IPS 白名单 IP（空格分隔）"
      echo "  TINYPROXY_CONFIG    配置文件路径"
      echo "  TINYPROXY_PID       PID 文件路径"
      echo "  TINYPROXY_LOG       日志文件路径"
      ;;
    *)
      run_ui
      ;;
  esac
}

main "$@"
