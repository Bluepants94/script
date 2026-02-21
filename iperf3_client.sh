#!/bin/bash

# ============================================
#  iperf3 客户端整点定时任务管理工具
#  功能：
#    1) 填写/修改参数
#    2) 启用整点定时连接（systemd timer）
#    3) 关闭整点定时连接
#    4) 启动
#    0) 退出
# ============================================

set -u

SERVICE_NAME="iperf3-client-hourly.service"
TIMER_NAME="iperf3-client-hourly.timer"

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
TIMER_FILE="/etc/systemd/system/${TIMER_NAME}"
STATE_FILE="/etc/iperf3-client-hourly.conf"
LOG_FILE="/var/log/iperf3-client-hourly.log"
RUNNER_FILE="/usr/local/bin/iperf3-client-hourly-runner.sh"

DEFAULT_PORT="5201"
DEFAULT_INTERVAL_HOURS="1"

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

prompt_interval_hours() {
  local input_hours
  read -r -p "请输入运行间隔小时数(例如 1=每小时整点，2=每2小时整点，默认 ${DEFAULT_INTERVAL_HOURS}): " input_hours
  RUN_INTERVAL_HOURS="${input_hours:-$DEFAULT_INTERVAL_HOURS}"

  if ! [[ "$RUN_INTERVAL_HOURS" =~ ^[0-9]+$ ]] || [ "$RUN_INTERVAL_HOURS" -le 0 ]; then
    err "运行间隔小时数必须为正整数。"
    return 1
  fi
}

save_selected_config() {
  cat > "$STATE_FILE" <<EOF_CFG
TARGET_IP="${TARGET_IP}"
TARGET_PORT="${TARGET_PORT}"
BANDWIDTH="${BANDWIDTH}"
TRANSFER_MODE="${TRANSFER_MODE}"
DURATION_SEC="${DURATION_SEC}"
RUN_INTERVAL_HOURS="${RUN_INTERVAL_HOURS:-$DEFAULT_INTERVAL_HOURS}"
LAST_RUN_TIME="${LAST_RUN_TIME:-}"
LAST_RUN_STATUS="${LAST_RUN_STATUS:-}"
EOF_CFG
}

load_selected_config() {
  if [ -f "$STATE_FILE" ]; then
    # shellcheck source=/dev/null
    source "$STATE_FILE"
  fi
}

is_saved_config_complete() {
  [ -n "${TARGET_IP:-}" ] && [ -n "${TARGET_PORT:-}" ] && [ -n "${DURATION_SEC:-}" ] && [ -n "${RUN_INTERVAL_HOURS:-}" ]
}

ensure_log_file() {
  touch "$LOG_FILE"
  chmod 644 "$LOG_FILE"
}

update_last_run_result() {
  local exit_code="$1"
  LAST_RUN_TIME="$(date '+%Y/%m/%d %H:%M')"
  if [ "$exit_code" -eq 0 ]; then
    LAST_RUN_STATUS="success"
  else
    LAST_RUN_STATUS="failure"
  fi
  save_selected_config
}

has_saved_config() {
  load_selected_config
  if is_saved_config_complete; then
    return 0
  fi
  return 1
}

confirm_reconfigure_if_exists() {
  local choice

  if has_saved_config; then
    warn "检测到参数已添加：${TARGET_IP}:${TARGET_PORT}, 模式=${TRANSFER_MODE:-normal}, 时长=${DURATION_SEC}s, 限速=${BANDWIDTH:-不限速}, 间隔=${RUN_INTERVAL_HOURS}小时"
    read -r -p "是否需要重新修改添加？[Y/N]: " choice
    case "$choice" in
      y|Y|yes|YES)
        return 0
        ;;
      *)
        info "保留原有参数，不做修改。"
        return 1
        ;;
    esac
  fi

  return 0
}

write_runner_file() {
  cat > "$RUNNER_FILE" <<'EOF_RUNNER'
#!/bin/bash

set -u

STATE_FILE="/etc/iperf3-client-hourly.conf"
LOG_FILE="/var/log/iperf3-client-hourly.log"

if [ ! -f "$STATE_FILE" ]; then
  exit 1
fi

# shellcheck source=/dev/null
source "$STATE_FILE"

if [ -z "${TARGET_IP:-}" ] || [ -z "${TARGET_PORT:-}" ] || [ -z "${DURATION_SEC:-}" ]; then
  exit 1
fi

RUN_INTERVAL_HOURS="${RUN_INTERVAL_HOURS:-1}"

iperf3_bin="$(command -v iperf3 || true)"
if [ -z "$iperf3_bin" ]; then
  exit 1
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

"${cmd[@]}" >> "$LOG_FILE" 2>&1
exit_code=$?

LAST_RUN_TIME="$(date '+%Y/%m/%d %H:%M')"
if [ "$exit_code" -eq 0 ]; then
  LAST_RUN_STATUS="success"
else
  LAST_RUN_STATUS="failure"
fi

cat > "$STATE_FILE" <<EOF_CFG
TARGET_IP="${TARGET_IP}"
TARGET_PORT="${TARGET_PORT}"
BANDWIDTH="${BANDWIDTH:-}"
TRANSFER_MODE="${TRANSFER_MODE:-}"
DURATION_SEC="${DURATION_SEC}"
RUN_INTERVAL_HOURS="${RUN_INTERVAL_HOURS}"
LAST_RUN_TIME="${LAST_RUN_TIME}"
LAST_RUN_STATUS="${LAST_RUN_STATUS}"
EOF_CFG

exit "$exit_code"
EOF_RUNNER

  chmod 755 "$RUNNER_FILE"
}

configure_task_params() {
  confirm_reconfigure_if_exists || return 0

  prompt_target_ip || return 1
  prompt_port_with_default || return 1
  prompt_bandwidth_optional || return 1
  prompt_transfer_mode_optional || return 1
  prompt_duration_sec || return 1
  prompt_interval_hours || return 1
  save_selected_config

  ok "配置已保存：IP=${TARGET_IP}, PORT=${TARGET_PORT}, MODE=${TRANSFER_MODE:-normal}, DURATION=${DURATION_SEC}s, INTERVAL=${RUN_INTERVAL_HOURS}h"
  if [ -n "$BANDWIDTH" ]; then
    info "限速：${BANDWIDTH}"
  else
    info "限速：不限速"
  fi
}

write_service_file() {
  ensure_log_file

  cat > "$SERVICE_FILE" <<EOF_SVC
[Unit]
Description=iperf3 client hourly runner
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${RUNNER_FILE}
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

  ensure_log_file

  info "开始运行："
  info "目标=${TARGET_IP}:${TARGET_PORT}, 模式=${TRANSFER_MODE:-normal}, 时长=${DURATION_SEC}s, 限速=${BANDWIDTH:-不限速}"
  echo ""

  "${cmd[@]}" 2>&1 | tee -a "$LOG_FILE"
  exit_code=${PIPESTATUS[0]}

  update_last_run_result "$exit_code"

  echo ""
  if [ "$exit_code" -eq 0 ]; then
    ok "iperf3 正常运行。"
  else
    err "iperf3 运行失败。请结合上方输出和日志排查。"
  fi

  return "$exit_code"
}

write_timer_file() {
  cat > "$TIMER_FILE" <<EOF_TMR
[Unit]
Description=Run iperf3 client at every hour

[Timer]
OnCalendar=*-*-* 0/${RUN_INTERVAL_HOURS}:00:00
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
  if ! has_saved_config; then
    err "未检测到已保存参数，请先选择“1) 填写/修改参数”。"
    return 1
  fi
  write_runner_file || return 1
  write_service_file || return 1
  write_timer_file || return 1

  systemctl daemon-reload
  systemctl enable --now "$TIMER_NAME"

  if systemctl is-enabled "$TIMER_NAME" >/dev/null 2>&1; then
    ok "已启用开机自启与整点任务。"
    echo "  Timer : ${TIMER_NAME}"
    echo "  每${RUN_INTERVAL_HOURS}小时整点自动执行一次。"
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

  if [ -f "$RUNNER_FILE" ]; then
    rm -f "$RUNNER_FILE"
    ok "运行脚本已删除：${RUNNER_FILE}"
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
    RUN_INTERVAL_HOURS="${RUN_INTERVAL_HOURS:-$DEFAULT_INTERVAL_HOURS}"
    info "目标：${TARGET_IP}:${TARGET_PORT}"
    info "持续：${DURATION_SEC}s"
    info "运行间隔：每${RUN_INTERVAL_HOURS}小时整点"
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

  if [ -n "${LAST_RUN_TIME:-}" ] && [ -n "${LAST_RUN_STATUS:-}" ]; then
    if [ "$LAST_RUN_STATUS" = "success" ]; then
      echo -e "${GREEN}[INFO]${NC} 上次运行：${LAST_RUN_TIME} 成功"
    elif [ "$LAST_RUN_STATUS" = "failure" ]; then
      echo -e "${RED}[INFO]${NC} 上次运行：${LAST_RUN_TIME} 失败"
    else
      warn "上次运行：状态未知"
    fi
  else
    warn "上次运行：暂无记录"
  fi

  info "日志文件：${LOG_FILE}"
}

show_menu() {
  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║    iperf3 客户端整点任务管理工具 (Linux)     ║"
  echo "╚══════════════════════════════════════════════╝"
  show_status
  echo ""
  echo "  1) 填写/修改参数"
  echo "  2) 启用整点定时 + 开机自启"
  echo "  3) 关闭整点定时 + 关闭自启"
  echo "  4) 启动"
  echo "  0) 退出"
  echo ""
  read -r -p "请选择操作 [0-4]: " choice

  case "$choice" in
    1)
      configure_task_params || true
      ;;
    2)
      enable_autostart || true
      ;;
    3)
      disable_autostart || true
      ;;
    4)
      run_once_with_saved_config || true
      ;;
    0)
      ok "已退出。"
      exit 0
      ;;
    *)
      err "无效选项，请输入 0-4。"
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
