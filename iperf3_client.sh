#!/bin/bash

# ============================================
#  iperf3 客户端整点定时任务管理工具
#  功能：
#    1) 启用整点定时连接（systemd timer）
#    2) 关闭整点定时连接
#    3) 启动（按已设参数立即运行一次）
#    0) 退出
# ============================================

set -u

SERVICE_NAME="iperf3-client-hourly.service"
TIMER_NAME="iperf3-client-hourly.timer"

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
TIMER_FILE="/etc/systemd/system/${TIMER_NAME}"
STATE_FILE="/etc/iperf3-client-hourly.conf"
LOG_FILE="/var/log/iperf3-client-hourly.log"

DEFAULT_PORT="5201"

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

is_valid_ipv4() {
  local ip="$1"
  local IFS='.'
  local -a octets

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    if ! [[ "$octet" =~ ^[0-9]+$ ]] || [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
      return 1
    fi
  done

  return 0
}

prompt_target_ip() {
  local input_ip
  read -r -p "请输入 iperf3 服务端 IP: " input_ip

  if [ -z "$input_ip" ]; then
    err "IP 不能为空。"
    return 1
  fi

  if ! is_valid_ipv4 "$input_ip"; then
    err "IP 格式无效：${input_ip}"
    return 1
  fi

  TARGET_IP="$input_ip"
}

prompt_port_with_default() {
  local input_port
  read -r -p "请输入服务端端口 (默认 ${DEFAULT_PORT}): " input_port
  TARGET_PORT="${input_port:-$DEFAULT_PORT}"

  if ! [[ "$TARGET_PORT" =~ ^[0-9]+$ ]] || [ "$TARGET_PORT" -lt 1 ] || [ "$TARGET_PORT" -gt 65535 ]; then
    err "端口无效：${TARGET_PORT}"
    return 1
  fi
}

prompt_bandwidth_optional() {
  local input_bw
  read -r -p "请输入限速(例如 10M，可留空表示不限速): " input_bw
  BANDWIDTH="$input_bw"
}

prompt_transfer_mode_optional() {
  local input_mode
  read -r -p "请输入传输模式(留空普通传输，填 -R 为反向): " input_mode

  if [ -z "$input_mode" ]; then
    TRANSFER_MODE=""
    return 0
  fi

  if [ "$input_mode" != "-R" ]; then
    err "传输模式仅支持留空或 -R。"
    return 1
  fi

  TRANSFER_MODE="-R"
}

prompt_duration_sec() {
  local input_sec
  read -r -p "请输入持续时间(秒): " input_sec

  if ! [[ "$input_sec" =~ ^[0-9]+$ ]] || [ "$input_sec" -le 0 ]; then
    err "持续时间必须为正整数秒。"
    return 1
  fi

  DURATION_SEC="$input_sec"
}

save_selected_config() {
  cat > "$STATE_FILE" <<EOF_CFG
TARGET_IP="${TARGET_IP}"
TARGET_PORT="${TARGET_PORT}"
BANDWIDTH="${BANDWIDTH}"
TRANSFER_MODE="${TRANSFER_MODE}"
DURATION_SEC="${DURATION_SEC}"
EOF_CFG
}

load_selected_config() {
  if [ -f "$STATE_FILE" ]; then
    # shellcheck source=/dev/null
    source "$STATE_FILE"
  fi
}

configure_task_params() {
  prompt_target_ip || return 1
  prompt_port_with_default || return 1
  prompt_bandwidth_optional || return 1
  prompt_transfer_mode_optional || return 1
  prompt_duration_sec || return 1
  save_selected_config

  ok "配置已保存：IP=${TARGET_IP}, PORT=${TARGET_PORT}, MODE=${TRANSFER_MODE:-normal}, DURATION=${DURATION_SEC}s"
  if [ -n "$BANDWIDTH" ]; then
    info "限速：${BANDWIDTH}"
  else
    info "限速：不限速"
  fi
}

write_service_file() {
  local iperf3_bin
  local cmd

  iperf3_bin="$(command -v iperf3 || true)"
  if [ -z "$iperf3_bin" ]; then
    err "未找到 iperf3 可执行文件。"
    return 1
  fi

  cmd="${iperf3_bin} -c ${TARGET_IP} -p ${TARGET_PORT}"

  if [ -n "$BANDWIDTH" ]; then
    cmd="${cmd} -b ${BANDWIDTH}"
  fi

  if [ "$TRANSFER_MODE" = "-R" ]; then
    cmd="${cmd} -R"
  fi

  cmd="${cmd} -t ${DURATION_SEC}"

  touch "$LOG_FILE"
  chmod 644 "$LOG_FILE"

  cat > "$SERVICE_FILE" <<EOF_SVC
[Unit]
Description=iperf3 client hourly runner
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -lc '${cmd}'
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF_SVC
}

run_once_with_saved_config() {
  local iperf3_bin
  local -a cmd
  local exit_code

  check_or_install_iperf3 || return 1
  load_selected_config

  if [ -z "${TARGET_IP:-}" ] || [ -z "${TARGET_PORT:-}" ] || [ -z "${DURATION_SEC:-}" ]; then
    err "未找到已保存参数，请先执行“启用整点定时 + 开机自启”完成配置。"
    return 1
  fi

  iperf3_bin="$(command -v iperf3 || true)"
  if [ -z "$iperf3_bin" ]; then
    err "未找到 iperf3 可执行文件。"
    return 1
  fi

  cmd=("$iperf3_bin" -c "$TARGET_IP" -p "$TARGET_PORT")
  if [ -n "${BANDWIDTH:-}" ]; then
    cmd+=(-b "$BANDWIDTH")
  fi
  if [ "${TRANSFER_MODE:-}" = "-R" ]; then
    cmd+=(-R)
  fi
  cmd+=(-t "$DURATION_SEC")

  touch "$LOG_FILE"
  chmod 644 "$LOG_FILE"

  info "开始按已设参数立即运行一次："
  info "目标=${TARGET_IP}:${TARGET_PORT}, 模式=${TRANSFER_MODE:-normal}, 时长=${DURATION_SEC}s, 限速=${BANDWIDTH:-不限速}"
  echo ""

  "${cmd[@]}" 2>&1 | tee -a "$LOG_FILE"
  exit_code=${PIPESTATUS[0]}

  echo ""
  if [ "$exit_code" -eq 0 ]; then
    ok "iperf3 运行完成，返回码=0（看起来运行正常）。"
  else
    err "iperf3 运行失败，返回码=${exit_code}。请结合上方输出和日志排查。"
  fi

  return "$exit_code"
}

write_timer_file() {
  cat > "$TIMER_FILE" <<EOF_TMR
[Unit]
Description=Run iperf3 client at every hour

[Timer]
OnCalendar=*-*-* *:00:00
Persistent=true
AccuracySec=1s
Unit=${SERVICE_NAME}

[Install]
WantedBy=timers.target
EOF_TMR
}

enable_autostart() {
  if systemctl is-enabled "$TIMER_NAME" >/dev/null 2>&1; then
    ok "检测到整点定时任务已启用，无需重复设置。"
    return 0
  fi

  check_or_install_iperf3 || return 1
  configure_task_params || return 1
  write_service_file || return 1
  write_timer_file || return 1

  systemctl daemon-reload
  systemctl enable --now "$TIMER_NAME"

  if systemctl is-enabled "$TIMER_NAME" >/dev/null 2>&1; then
    ok "已启用开机自启与整点任务。"
    echo "  Timer : ${TIMER_NAME}"
    echo "  每小时整点自动执行一次。"
    echo "  日志 : ${LOG_FILE}"
  else
    err "启用失败，请检查 systemctl 状态。"
    return 1
  fi
}

disable_autostart() {
  if systemctl list-unit-files | grep -q "^${TIMER_NAME}"; then
    systemctl disable --now "$TIMER_NAME" >/dev/null 2>&1 || true
    ok "已关闭整点定时任务与开机自启。"
  else
    warn "未找到 ${TIMER_NAME}，可能尚未启用。"
  fi

  if [ -f "$TIMER_FILE" ]; then
    rm -f "$TIMER_FILE"
    ok "定时器文件已删除：${TIMER_FILE}"
  fi

  if [ -f "$SERVICE_FILE" ]; then
    rm -f "$SERVICE_FILE"
    ok "服务文件已删除：${SERVICE_FILE}"
  fi

  systemctl daemon-reload
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
  if [ -n "${TARGET_IP:-}" ] && [ -n "${TARGET_PORT:-}" ] && [ -n "${DURATION_SEC:-}" ]; then
    info "目标：${TARGET_IP}:${TARGET_PORT}"
    info "持续：${DURATION_SEC}s"
    info "模式：${TRANSFER_MODE:-normal}"
    if [ -n "${BANDWIDTH:-}" ]; then
      info "限速：${BANDWIDTH}"
    else
      info "限速：不限速"
    fi
  else
    warn "尚未配置任务参数"
  fi

  if systemctl is-enabled "$TIMER_NAME" >/dev/null 2>&1; then
    ok "开机自启/定时：已启用"
  else
    warn "开机自启/定时：未启用"
  fi

  if systemctl is-active "$TIMER_NAME" >/dev/null 2>&1; then
    ok "定时器运行：运行中"
  else
    warn "定时器运行：未运行"
  fi

  if systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
    ok "最近任务执行：执行中"
  else
    info "最近任务执行：非执行中（整点触发时会短暂运行）"
  fi

  info "日志文件：${LOG_FILE}"
}

show_menu() {
  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║    iperf3 客户端整点任务管理工具 (Linux)      ║"
  echo "╚══════════════════════════════════════════════╝"
  show_status
  echo ""
  echo "  1) 启用整点定时 + 开机自启"
  echo "  2) 关闭整点定时 + 关闭自启"
  echo "  3) 启动（按已设参数立即运行一次）"
  echo "  0) 退出"
  echo ""
  read -r -p "请选择操作 [0-3]: " choice

  case "$choice" in
    1)
      enable_autostart || true
      ;;
    2)
      disable_autostart || true
      ;;
    3)
      run_once_with_saved_config || true
      ;;
    0)
      ok "已退出。"
      exit 0
      ;;
    *)
      err "无效选项，请输入 0-3。"
      ;;
  esac

  echo ""
  read -r -n 1 -s -p "按任意键返回菜单..." _
  echo ""
}

main() {
  check_root
  while true; do
    clear
    show_menu
  done
}

main
