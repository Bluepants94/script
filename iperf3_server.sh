#!/bin/bash

# ============================================
#  iperf3 开机自启管理工具
#  功能：
#    1) 检测并安装 iperf3（默认自动安装，无需确认）
#    2) 检测本地/公网 IP，并由用户选择监听 IP
#    3) 开启开机自启（systemd）
#    4) 关闭开机自启
#    0) 退出
# ============================================

set -u

SERVICE_NAME="iperf3-server-custom.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
STATE_FILE="/etc/iperf3-server-manager.conf"
DEFAULT_PORT="5201"
PLACEHOLDER_IP="---.---.---.---"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERR]${NC} $1"; }

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 用户运行此脚本。"
    exit 1
  fi
}

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

is_iperf3_installed() {
  command -v iperf3 >/dev/null 2>&1
}

install_iperf3() {
  local pm
  pm="$(detect_pkg_manager)"

  if [ -z "$pm" ]; then
    err "未识别到支持的包管理器，请手动安装 iperf3。"
    return 1
  fi

  info "检测到包管理器: ${pm}"
  info "开始自动安装 iperf3..."

  case "$pm" in
    apt)
      apt update && apt install -y iperf3
      ;;
    dnf)
      dnf install -y iperf3
      ;;
    yum)
      yum install -y epel-release && yum install -y iperf3
      ;;
    pacman)
      pacman -Sy --noconfirm iperf3
      ;;
  esac

  if is_iperf3_installed; then
    ok "iperf3 安装成功。"
    return 0
  fi

  err "iperf3 安装失败，请手动检查。"
  return 1
}

check_or_install_iperf3() {
  if is_iperf3_installed; then
    ok "iperf3 已安装。"
    return 0
  fi

  warn "iperf3 未安装，将进行自动安装（无需确认）。"
  install_iperf3
}

is_private_ipv4() {
  local ip="$1"

  if [[ "$ip" =~ ^10\. ]]; then
    return 0
  elif [[ "$ip" =~ ^192\.168\. ]]; then
    return 0
  elif [[ "$ip" =~ ^172\.([1][6-9]|2[0-9]|3[0-1])\. ]]; then
    return 0
  elif [[ "$ip" =~ ^127\. ]]; then
    return 0
  fi

  return 1
}

collect_local_ipv4() {
  if ! command -v ip >/dev/null 2>&1; then
    err "未找到 ip 命令，无法检测本地 IP。"
    return 1
  fi

  ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u
}

detect_public_ipv4() {
  local pub=""

  if command -v curl >/dev/null 2>&1; then
    pub="$(curl -4 -s --max-time 4 https://api.ipify.org 2>/dev/null || true)"
    if [ -z "$pub" ]; then
      pub="$(curl -4 -s --max-time 4 https://ifconfig.me 2>/dev/null || true)"
    fi
  fi

  if [[ "$pub" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "$pub"
  else
    echo ""
  fi
}

prompt_choice_in_range() {
  local prompt="$1"
  local min="$2"
  local max="$3"
  local choice

  read -r -p "$prompt" choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt "$min" ] || [ "$choice" -gt "$max" ]; then
    err "无效选项。"
    return 1
  fi

  echo "$choice"
}

prompt_port_with_default() {
  local input_port
  read -r -p "请输入监听端口 (默认 ${DEFAULT_PORT}): " input_port
  LISTEN_PORT="${input_port:-$DEFAULT_PORT}"

  if ! [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] || [ "$LISTEN_PORT" -lt 1 ] || [ "$LISTEN_PORT" -gt 65535 ]; then
    err "端口无效：${LISTEN_PORT}"
    return 1
  fi
}

save_selected_config() {
  cat > "$STATE_FILE" <<EOF_CFG
LISTEN_IP="${LISTEN_IP}"
LISTEN_PORT="${LISTEN_PORT}"
EOF_CFG
}

load_selected_config() {
  if [ -f "$STATE_FILE" ]; then
    # shellcheck source=/dev/null
    source "$STATE_FILE"
  fi
}

select_listen_ip() {
  local ips ip
  local private_ip=""
  local public_ip=""
  local private_choice="$PLACEHOLDER_IP"
  local public_choice="$PLACEHOLDER_IP"
  local ip_choice

  mapfile -t ips < <(collect_local_ipv4)

  for ip in "${ips[@]}"; do
    if is_private_ipv4 "$ip"; then
      private_ip="$ip"
      break
    fi
  done

  public_ip="$(detect_public_ipv4)"

  if [ -n "$private_ip" ]; then
    private_choice="$private_ip"
  fi

  if [ -n "$public_ip" ]; then
    public_choice="$public_ip"
  fi

  echo ""
  echo "请选择监听 IP："

  echo "  1) 127.0.0.1"
  echo "  2) 0.0.0.0"
  echo "  3) ${private_choice} (内网IP)"
  echo "  4) ${public_choice} (公网IP)"

  ip_choice="$(prompt_choice_in_range "输入选项编号: " 1 4)" || return 1

  case "$ip_choice" in
    1)
      LISTEN_IP="127.0.0.1"
      ;;
    2)
      LISTEN_IP="0.0.0.0"
      ;;
    3)
      if [ "$private_choice" = "$PLACEHOLDER_IP" ]; then
        err "当前无可用内网IP，请选择其他选项。"
        return 1
      fi
      LISTEN_IP="$private_choice"
      ;;
    4)
      if [ "$public_choice" = "$PLACEHOLDER_IP" ]; then
        err "当前无可用公网IP，请选择其他选项。"
        return 1
      fi
      LISTEN_IP="$public_choice"
      ;;
  esac

  prompt_port_with_default || return 1

  save_selected_config
  ok "监听配置已保存：IP=${LISTEN_IP}, PORT=${LISTEN_PORT}"
}

write_service_file() {
  local iperf3_bin
  iperf3_bin="$(command -v iperf3 || true)"
  if [ -z "$iperf3_bin" ]; then
    err "未找到 iperf3 可执行文件。"
    return 1
  fi

  cat > "$SERVICE_FILE" <<EOF_SVC
[Unit]
Description=iperf3 server (custom bind)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${iperf3_bin} -s -B ${LISTEN_IP} -p ${LISTEN_PORT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF_SVC
}

enable_autostart() {
  if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
    ok "检测到 iperf3 开机自启已启用，无需重复设置。"
    if systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
      info "当前服务状态：运行中"
    else
      warn "当前服务状态：未运行"
    fi

    load_selected_config
    if [ -n "${LISTEN_IP:-}" ] && [ -n "${LISTEN_PORT:-}" ]; then
      info "当前监听：${LISTEN_IP}:${LISTEN_PORT}"
    fi
    return 0
  fi

  check_or_install_iperf3 || return 1
  select_listen_ip || return 1

  write_service_file || return 1

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"

  if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
    ok "开机自启已开启。"
    echo "  服务: ${SERVICE_NAME}"
    echo "  监听: ${LISTEN_IP}:${LISTEN_PORT}"
  else
    err "开机自启开启失败，请检查 systemctl 状态。"
    return 1
  fi
}

disable_autostart() {
  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    ok "已关闭开机自启并停止服务。"
  else
    warn "未找到 ${SERVICE_NAME}，可能尚未启用。"
  fi

  if [ -f "$SERVICE_FILE" ]; then
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    ok "服务文件已删除：${SERVICE_FILE}"
  fi
}

show_status() {
  echo ""
  echo "========== 当前状态 =========="

  if is_iperf3_installed; then
    ok "iperf3：已安装"
  else
    warn "iperf3：未安装"
  fi

  load_selected_config
  if [ -n "${LISTEN_IP:-}" ] && [ -n "${LISTEN_PORT:-}" ]; then
    info "最近一次检测监听：${LISTEN_IP}:${LISTEN_PORT}"
  else
    warn "尚未生成监听配置"
  fi

  if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
    ok "开机自启：已启用"
  else
    warn "开机自启：未启用"
  fi

  if systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
    ok "服务运行：运行中"
  else
    warn "服务运行：未运行"
  fi
}

show_menu() {
  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║      iperf3 开机自启管理工具 (Linux)         ║"
  echo "╚══════════════════════════════════════════════╝"
  show_status
  echo ""
  echo "  1) 开机自启"
  echo "  2) 关闭自启"
  echo "  0) 退出"
  echo ""
  read -r -p "请选择操作 [0-2]: " choice

  case "$choice" in
    1)
      enable_autostart || true
      ;;
    2)
      disable_autostart || true
      ;;
    0)
      ok "已退出。"
      exit 0
      ;;
    *)
      err "无效选项，请输入 0-2。"
      ;;
  esac

  echo ""
  read -r -n 1 -s -p "按任意键返回菜单..." _
  echo ""
}

main() {
  check_root
  check_or_install_iperf3 || true
  while true; do
    clear
    show_menu
  done
}

main
