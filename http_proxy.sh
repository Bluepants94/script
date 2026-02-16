#!/bin/bash

# Tinyproxy HTTP 代理管理脚本
# 功能：
# 1) 检查并安装 tinyproxy
# 2) 开启代理（端口 + 可选用户名/密码）
# 3) 关闭代理并清理配置文件

set -euo pipefail

CONFIG_FILE="/tmp/tinyproxy_custom.conf"
PID_FILE="/tmp/tinyproxy_custom.pid"
LOG_FILE="/tmp/tinyproxy_custom.log"
DEFAULT_PORT="8888"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

print_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
print_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_err() { echo -e "${RED}[ERR]${NC} $1"; }

detect_pkg_manager() {
  if command -v apt >/dev/null 2>&1; then
    echo "apt"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v pacman >/dev/null 2>&1; then
    echo "pacman"
  else
    echo ""
  fi
}

install_tinyproxy() {
  local pm
  pm="$(detect_pkg_manager)"

  if [ -z "$pm" ]; then
    print_err "未识别到支持的包管理器，请手动安装 tinyproxy。"
    return 1
  fi

  print_info "开始安装 tinyproxy（需要 sudo 权限）..."
  case "$pm" in
    apt)
      sudo apt update && sudo apt install -y tinyproxy
      ;;
    dnf)
      sudo dnf install -y tinyproxy
      ;;
    yum)
      sudo yum install -y epel-release && sudo yum install -y tinyproxy
      ;;
    pacman)
      sudo pacman -Sy --noconfirm tinyproxy
      ;;
  esac

  if command -v tinyproxy >/dev/null 2>&1; then
    print_ok "tinyproxy 安装成功。"
    return 0
  fi

  print_err "tinyproxy 安装失败，请手动检查。"
  return 1
}

check_or_install_tinyproxy() {
  if command -v tinyproxy >/dev/null 2>&1; then
    print_ok "tinyproxy 已安装。"
    return 0
  fi

  print_warn "tinyproxy 未安装。"
  read -r -p "是否立即自动安装 tinyproxy? (y/N): " choice
  if [[ "$choice" =~ ^[Yy]$ ]]; then
    install_tinyproxy
  else
    print_err "用户取消安装，无法继续。"
    return 1
  fi
}

prompt_start_params() {
  read -r -p "请输入代理端口 (默认 ${DEFAULT_PORT}): " input_port
  PROXY_PORT="${input_port:-$DEFAULT_PORT}"

  if ! [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || [ "$PROXY_PORT" -lt 1 ] || [ "$PROXY_PORT" -gt 65535 ]; then
    print_err "端口无效：$PROXY_PORT"
    return 1
  fi

  read -r -p "请输入用户名 (可留空): " PROXY_USER
  read -r -p "请输入密码 (可留空): " PROXY_PASS
}

is_port_used() {
  local port="$1"

  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | grep -q ":${port} "
    return $?
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | grep -q ":${port} "
    return $?
  fi

  return 1
}

detect_runtime_user() {
  id -un 2>/dev/null || echo "nobody"
}

detect_runtime_group() {
  id -gn 2>/dev/null || echo "nogroup"
}

generate_config() {
  local run_user run_group
  run_user="$(detect_runtime_user)"
  run_group="$(detect_runtime_group)"

  : > "$CONFIG_FILE"

  cat >> "$CONFIG_FILE" <<EOF_CONF
Port ${PROXY_PORT}
Listen 0.0.0.0
Timeout 600
MaxClients 100
StartServers 5
MinSpareServers 5
MaxSpareServers 20
MaxRequestsPerChild 0
LogFile "${LOG_FILE}"
LogLevel Info
PidFile "${PID_FILE}"
DisableViaHeader Yes
User ${run_user}
Group ${run_group}
EOF_CONF

  # 用户名和密码都不为空时启用认证，否则不启用
  if [ -n "${PROXY_USER}" ] && [ -n "${PROXY_PASS}" ]; then
    cat >> "$CONFIG_FILE" <<EOF_AUTH
BasicAuth ${PROXY_USER} ${PROXY_PASS}
EOF_AUTH
    AUTH_ENABLED="yes"
  else
    AUTH_ENABLED="no"
  fi
}

start_proxy() {
  check_or_install_tinyproxy || return 1
  prompt_start_params || return 1

  if is_port_used "$PROXY_PORT"; then
    print_err "端口 ${PROXY_PORT} 已被占用，请更换端口。"
    return 1
  fi

  # 防止系统服务冲突（如果存在）
  sudo systemctl stop tinyproxy >/dev/null 2>&1 || true

  generate_config

  print_info "正在启动 tinyproxy..."
  tinyproxy -c "$CONFIG_FILE"
  sleep 1

  local pid=""
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  fi

  if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
    print_ok "代理已启动。"
    echo "--------------------------------------------------"
    echo "端口: ${PROXY_PORT}"
    if [ "$AUTH_ENABLED" = "yes" ]; then
      echo "认证: 已启用"
      echo "用户名: ${PROXY_USER}"
      echo "密码: ${PROXY_PASS}"
      echo "代理地址: http://${PROXY_USER}:${PROXY_PASS}@<服务器IP>:${PROXY_PORT}"
    else
      echo "认证: 未启用（用户名/密码留空）"
      echo "代理地址: http://<服务器IP>:${PROXY_PORT}"
    fi
    echo "配置文件: ${CONFIG_FILE}"
    echo "PID文件: ${PID_FILE}"
    echo "日志文件: ${LOG_FILE}"
    echo "--------------------------------------------------"
  else
    print_err "启动失败，请检查：${LOG_FILE}"
    return 1
  fi
}

stop_proxy() {
  local pid=""
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  fi

  if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "$pid" >/dev/null 2>&1 || true
    print_ok "tinyproxy 进程已停止（PID: $pid）。"
  else
    # 兜底：查找自定义配置启动的 tinyproxy
    local pids
    pids="$(pgrep -f "tinyproxy.*${CONFIG_FILE}" || true)"
    if [ -n "$pids" ]; then
      echo "$pids" | xargs kill >/dev/null 2>&1 || true
      sleep 1
      echo "$pids" | xargs kill -9 >/dev/null 2>&1 || true
      print_ok "tinyproxy 进程已停止（通过进程匹配）。"
    else
      print_warn "未发现运行中的自定义 tinyproxy 进程。"
    fi
  fi

  rm -f "$CONFIG_FILE" "$PID_FILE" "$LOG_FILE"
  print_ok "配置文件、PID 文件、日志文件已清理。"
}

show_usage() {
  cat <<EOF_USAGE
用法:
  ./tinyproxy_manager.sh            # 交互式 UI 菜单
  ./tinyproxy_manager.sh start      # 命令行模式：检查安装并开启代理
  ./tinyproxy_manager.sh stop       # 命令行模式：关闭代理并清理配置
EOF_USAGE
}

show_banner() {
  echo ""
  echo "=================================================="
  echo "        Tinyproxy HTTP 代理管理工具 (UI)"
  echo "=================================================="
}

show_menu() {
  echo ""
  echo "请选择操作："
  echo "  1) 开启代理（检查/安装 tinyproxy）"
  echo "  2) 关闭代理（并清理配置）"
  echo "  3) 查看帮助"
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
        start_proxy || true
        ;;
      2)
        stop_proxy || true
        ;;
      3)
        show_usage
        ;;
      0)
        print_ok "已退出。"
        exit 0
        ;;
      *)
        print_warn "无效选项，请输入 0-3。"
        ;;
    esac

    echo ""
    read -r -p "按回车键继续..." _
  done
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    "")
      run_ui
      ;;
    start)
      start_proxy
      ;;
    stop)
      stop_proxy
      ;;
    *)
      show_usage
      exit 1
      ;;
  esac
}

main "$@"
