#!/bin/bash

# 流量消耗器（Linux Bash + 终端菜单 UI）
# 目标：每小时约消耗 50MB 流量
#
# 功能：
# 1) 开启
# 2) 关闭
# 3) 开机自启（systemd）
# 4) 关闭自启
# 5) 状态查看
#
# 说明：
# - 优先使用 speedtest-cli 触发流量（若可用）
# - 失败时自动切换到 curl 分片下载（更可控）
# - 自启功能通常需要 sudo 权限

set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

PID_FILE="/tmp/traffic_consumer.pid"
LOG_FILE="/tmp/traffic_consumer.log"
CONFIG_FILE="/tmp/traffic_consumer.conf"
SERVICE_NAME="traffic-consumer.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

DEFAULT_TARGET_MB_PER_HOUR=50
TARGET_MB_PER_HOUR="$DEFAULT_TARGET_MB_PER_HOUR"
CHUNK_MB=5

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

print_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
print_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_err() { echo -e "${RED}[ERR]${NC} $1"; }

is_positive_int() {
  local v="$1"
  [[ "$v" =~ ^[1-9][0-9]*$ ]]
}

load_target_mb_config() {
  TARGET_MB_PER_HOUR="$DEFAULT_TARGET_MB_PER_HOUR"
  if [ -f "$CONFIG_FILE" ]; then
    local v
    v="$(cat "$CONFIG_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
    if is_positive_int "$v"; then
      TARGET_MB_PER_HOUR="$v"
    fi
  fi
}

save_target_mb_config() {
  local mb="$1"
  echo "$mb" > "$CONFIG_FILE"
}

prompt_target_mb() {
  load_target_mb_config
  local default_mb="$TARGET_MB_PER_HOUR"
  local input
  while true; do
    read -r -p "请输入每小时目标流量（MB，默认 ${default_mb}）: " input
    input="${input:-$default_mb}"
    if is_positive_int "$input"; then
      echo "$input"
      return 0
    fi
    print_warn "请输入大于 0 的整数（单位 MB）。"
  done
}

need_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    print_err "缺少命令：${cmd}"
    return 1
  fi
  return 0
}

is_running() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

cleanup_stale_pid() {
  if [ -f "$PID_FILE" ] && ! is_running; then
    rm -f "$PID_FILE"
  fi
}

consume_with_speedtest() {
  # speedtest-cli 的流量消耗量不可精确控制，仅作优先方案
  if ! command -v speedtest-cli >/dev/null 2>&1; then
    return 1
  fi

  print_info "尝试使用 speedtest-cli 消耗流量..."
  if timeout 180 speedtest-cli --secure --no-upload >/dev/null 2>&1; then
    print_ok "speedtest-cli 执行成功。"
    return 0
  fi

  return 1
}

consume_with_curl() {
  need_cmd curl || return 1

  local target_mb="$TARGET_MB_PER_HOUR"
  local chunk_mb="$CHUNK_MB"

  local urls=(
    "https://speed.hetzner.de/100MB.bin"
    "https://proof.ovh.net/files/100Mb.dat"
    "https://download.thinkbroadband.com/100MB.zip"
  )

  print_info "使用 curl 分片下载，目标约 ${target_mb}MB/小时（每片 ${chunk_mb}MB）。"

  local remaining_mb="$target_mb"
  local piece_idx=0
  while [ "$remaining_mb" -gt 0 ]; do
    piece_idx=$((piece_idx + 1))
    local current_chunk_mb="$chunk_mb"
    if [ "$remaining_mb" -lt "$chunk_mb" ]; then
      current_chunk_mb="$remaining_mb"
    fi
    local chunk_bytes=$((current_chunk_mb * 1024 * 1024))

    local ok=0
    local url
    for url in "${urls[@]}"; do
      # 优先尝试 Range 下载，避免一次拉取过大文件
      if timeout 120 curl -L --fail --silent --show-error \
        --range "0-$((chunk_bytes - 1))" \
        --output /dev/null "$url"; then
        ok=1
        break
      fi

      # 兜底：流式读取前 chunk_bytes 字节
      if timeout 120 bash -c "curl -L --fail --silent '$url' | head -c ${chunk_bytes} >/dev/null"; then
        ok=1
        break
      fi
    done

    if [ "$ok" -eq 1 ]; then
      print_info "第 ${piece_idx} 片完成（约 ${current_chunk_mb}MB）。"
    else
      print_warn "第 ${piece_idx} 片失败，跳过。"
    fi

    remaining_mb=$((remaining_mb - current_chunk_mb))
    sleep 2
  done

  print_ok "本小时 curl 流量任务完成（目标约 ${target_mb}MB）。"
  return 0
}

consume_once() {
  local start_ts end_ts
  start_ts="$(date +%s)"

  if consume_with_speedtest; then
    print_info "本小时使用 speedtest-cli 模式。"
  else
    print_warn "speedtest-cli 不可用或失败，自动切换 curl 模式。"
    consume_with_curl || print_err "curl 模式也失败，请检查网络。"
  fi

  end_ts="$(date +%s)"
  print_info "本轮耗时：$((end_ts - start_ts)) 秒。"
}

daemon_loop() {
  local mb_from_arg="${1:-}"

  if is_positive_int "$mb_from_arg"; then
    TARGET_MB_PER_HOUR="$mb_from_arg"
  else
    load_target_mb_config
  fi

  cleanup_stale_pid
  if is_running; then
    print_warn "已在运行中，无需重复启动。"
    return 0
  fi

  echo "$$" > "$PID_FILE"
  trap 'rm -f "$PID_FILE"' EXIT

  print_ok "流量消耗守护进程已启动，PID=$$"
  while true; do
    local round_start now elapsed sleep_s
    round_start="$(date +%s)"

    print_info "开始新一轮流量消耗任务：$(date '+%F %T')"
    consume_once

    now="$(date +%s)"
    elapsed=$((now - round_start))
    if [ "$elapsed" -lt 3600 ]; then
      sleep_s=$((3600 - elapsed))
      print_info "本轮完成，休眠 ${sleep_s} 秒后进入下一轮。"
      sleep "$sleep_s"
    else
      print_warn "本轮执行超过 1 小时，将立即开始下一轮。"
    fi
  done
}

start_consumer() {
  local mb_input="${1:-}"

  if ! is_positive_int "$mb_input"; then
    if [ -t 0 ]; then
      mb_input="$(prompt_target_mb)"
    else
      load_target_mb_config
      mb_input="$TARGET_MB_PER_HOUR"
    fi
  fi

  TARGET_MB_PER_HOUR="$mb_input"
  save_target_mb_config "$TARGET_MB_PER_HOUR"

  cleanup_stale_pid
  if is_running; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    print_warn "已在运行中（PID: ${pid}）。"
    return 0
  fi

  need_cmd nohup || return 1

  nohup bash "$SCRIPT_PATH" daemon "$TARGET_MB_PER_HOUR" >> "$LOG_FILE" 2>&1 &
  sleep 1

  if is_running; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    print_ok "已开启流量消耗器（PID: ${pid}）。"
    print_info "当前目标流量：${TARGET_MB_PER_HOUR}MB/小时"
    print_info "日志文件：${LOG_FILE}"
  else
    print_err "启动失败，请检查日志：${LOG_FILE}"
    return 1
  fi
}

stop_consumer() {
  cleanup_stale_pid

  if ! is_running; then
    print_warn "当前未运行。"
    return 0
  fi

  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"

  if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    sleep 1
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill -9 "$pid" >/dev/null 2>&1 || true
    fi
    print_ok "已关闭流量消耗器（PID: ${pid}）。"
  fi

  rm -f "$PID_FILE"
}

install_systemd_service() {
  if [[ "$SCRIPT_PATH" == *" "* ]]; then
    print_warn "脚本路径含空格，可能导致 systemd ExecStart 解析异常。"
  fi

  local service_tmp
  service_tmp="/tmp/${SERVICE_NAME}"

  cat > "$service_tmp" <<EOF_SERVICE
[Unit]
Description=Traffic Consumer (50MB/hour)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash ${SCRIPT_PATH} daemon
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  print_info "写入 systemd 服务文件（需要 sudo 权限）..."
  sudo cp "$service_tmp" "$SERVICE_PATH"
  sudo chmod 644 "$SERVICE_PATH"
  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE_NAME"

  print_ok "开机自启已启用：${SERVICE_NAME}"
  print_info "如需立即启动可执行：sudo systemctl start ${SERVICE_NAME}"
}

uninstall_systemd_service() {
  print_info "关闭并移除 systemd 自启（需要 sudo 权限）..."
  sudo systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  sudo systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  sudo rm -f "$SERVICE_PATH"
  sudo systemctl daemon-reload

  print_ok "开机自启已关闭。"
}

show_status() {
  load_target_mb_config

  echo "================= 状态 ================="
  if is_running; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    print_ok "运行中（PID: ${pid}）"
  else
    print_warn "未运行"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
      print_ok "开机自启：已启用"
    else
      print_warn "开机自启：未启用"
    fi
  else
    print_warn "未检测到 systemctl，无法查询自启状态"
  fi

  print_info "当前配置目标：${TARGET_MB_PER_HOUR}MB/小时"

  if [ -f "$LOG_FILE" ]; then
    echo "----------- 最近日志（最后10行） -----------"
    tail -n 10 "$LOG_FILE" || true
  else
    print_info "暂无日志文件：${LOG_FILE}"
  fi
  echo "==========================================="
}

show_usage() {
  cat <<EOF_USAGE
用法：
  ./traffic_consumer.sh                # 交互式菜单 UI
  ./traffic_consumer.sh start [MB]     # 开启（可指定每小时MB，不指定则交互输入）
  ./traffic_consumer.sh stop           # 关闭
  ./traffic_consumer.sh enable-auto    # 开机自启（systemd）
  ./traffic_consumer.sh disable-auto   # 关闭自启
  ./traffic_consumer.sh status         # 查看状态

可选依赖：
  speedtest-cli    # 优先使用（失败自动回退到 curl）

必需依赖：
  curl, bash, nohup
EOF_USAGE
}

show_banner() {
  echo ""
  echo "=================================================="
  echo "             流量消耗器（约 50MB/小时）"
  echo "=================================================="
}

show_menu() {
  echo ""
  echo "请选择操作："
  echo "  1) 开启"
  echo "  2) 关闭"
  echo "  3) 开机自启（systemd）"
  echo "  4) 关闭自启"
  echo "  5) 状态查看"
  echo "  0) 退出"
  echo -n "输入选项 [0-5]: "
}

run_ui() {
  while true; do
    show_banner
    show_menu
    read -r choice

    case "$choice" in
      1)
        local mb
        mb="$(prompt_target_mb)"
        start_consumer "$mb" || true
        ;;
      2) stop_consumer || true ;;
      3) install_systemd_service || true ;;
      4) uninstall_systemd_service || true ;;
      5) show_status ;;
      0)
        print_ok "已退出。"
        exit 0
        ;;
      *)
        print_warn "无效选项，请输入 0-5。"
        ;;
    esac

    echo ""
    read -r -p "按回车键继续..." _
  done
}

main() {
  local cmd="${1:-}"

  case "$cmd" in
    "") run_ui ;;
    daemon) daemon_loop "${2:-}" ;;
    start) start_consumer "${2:-}" ;;
    stop) stop_consumer ;;
    enable-auto) install_systemd_service ;;
    disable-auto) uninstall_systemd_service ;;
    status) show_status ;;
    *)
      show_usage
      exit 1
      ;;
  esac
}

main "$@"
