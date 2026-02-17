#!/bin/bash

# ============================================================
# 流量消耗器（Linux Bash + 终端菜单 UI）
# ============================================================
# 功能：
#   1) 开启（输入每小时目标流量，必须为 100MB 的倍数）
#   2) 关闭（同时清理所有脚本产生的文件）
#   3) 开机自启（systemd）
#   4) 关闭自启（同时清理所有脚本产生的文件）
#   5) 状态查看
#
# 流量来源：curl 下载 100MB 测试文件
# 依赖：curl（启动时自动检测并安装）
#
# 用法：
#   chmod +x traffic_consumer.sh
#   ./traffic_consumer.sh
# ============================================================

set -uo pipefail

SCRIPT_PATH="$(readlink -f "$0")"

PID_FILE="/tmp/traffic_consumer.pid"
LOG_FILE="/tmp/traffic_consumer.log"
CONFIG_FILE="/tmp/traffic_consumer.conf"
SERVICE_NAME="traffic-consumer.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
SERVICE_TMP_PATH="/tmp/${SERVICE_NAME}"

DEFAULT_TARGET_MB_PER_HOUR=100
TARGET_MB_PER_HOUR="$DEFAULT_TARGET_MB_PER_HOUR"

# 每次下载 100MB，按次数拆分
CHUNK_MB=100

# 下载源（优先级从高到低）
DOWNLOAD_URLS=(
  "http://ipv4.download.thinkbroadband.com/100MB.zip"
  "http://proof.ovh.net/files/100Mb.dat"
  "http://speedtest.tele2.net/100MB.zip"
)

# ---- 颜色 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

print_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
print_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_err()  { echo -e "${RED}[ERR]${NC} $1"; }

# ---- 包管理器检测 ----

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  elif command -v pacman >/dev/null 2>&1; then echo "pacman"
  elif command -v apk >/dev/null 2>&1; then echo "apk"
  else echo ""
  fi
}

# ---- 依赖安装 ----

install_curl() {
  local pm
  pm="$(detect_pkg_manager)"
  print_info "正在安装 curl..."
  case "$pm" in
    apt)    sudo apt-get update -qq && sudo apt-get install -y -qq curl ;;
    dnf)    sudo dnf install -y -q curl ;;
    yum)    sudo yum install -y -q curl ;;
    pacman) sudo pacman -Sy --noconfirm curl ;;
    apk)    sudo apk add --no-cache curl ;;
    *)
      print_err "未识别的包管理器，请手动安装 curl。"
      return 1
      ;;
  esac
  if command -v curl >/dev/null 2>&1; then
    print_ok "curl 安装成功。"
    return 0
  fi
  print_err "curl 安装失败。"
  return 1
}

check_and_install_deps() {
  if command -v curl >/dev/null 2>&1; then
    print_ok "curl 已安装。"
  else
    print_warn "curl 未安装，正在自动安装..."
    if ! install_curl; then
      print_err "curl 是必需依赖，无法继续。"
      return 1
    fi
  fi

  # 测试网络连通性
  print_info "测试网络连通性..."
  local test_ok=0
  local test_url
  for test_url in "${DOWNLOAD_URLS[@]}"; do
    local http_code
    http_code="$(timeout 15 curl -sL -o /dev/null -w '%{http_code}' --range '0-1023' "$test_url" 2>/dev/null || echo '000')"
    if [ "$http_code" = "200" ] || [ "$http_code" = "206" ]; then
      print_ok "网络连通：$test_url（HTTP $http_code）"
      test_ok=1
      break
    fi
  done

  if [ "$test_ok" -eq 0 ]; then
    print_warn "所有下载源连通性测试失败，流量消耗可能无法正常工作。请检查网络。"
  fi

  return 0
}

# ---- 工具函数 ----

is_positive_int() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

is_multiple_of_100() {
  local v="${1:-0}"
  is_positive_int "$v" && [ $((v % 100)) -eq 0 ]
}

load_target_mb_config() {
  TARGET_MB_PER_HOUR="$DEFAULT_TARGET_MB_PER_HOUR"
  if [ -f "$CONFIG_FILE" ]; then
    local v
    v="$(tr -d '[:space:]' < "$CONFIG_FILE" 2>/dev/null || true)"
    if is_multiple_of_100 "$v"; then
      TARGET_MB_PER_HOUR="$v"
    fi
  fi
}

save_target_mb_config() {
  echo "$1" > "$CONFIG_FILE"
}

prompt_target_mb() {
  load_target_mb_config
  local default_mb="$TARGET_MB_PER_HOUR"
  local input
  while true; do
    read -r -p "请输入每小时目标流量（必须为 100MB 的倍数，默认 ${default_mb}）: " input </dev/tty
    input="${input:-$default_mb}"
    if is_multiple_of_100 "$input"; then
      echo "$input"
      return 0
    fi
    echo -e "${YELLOW}[WARN]${NC} 请输入 100 的正整数倍（如 100、200、500、1000）。" >&2
  done
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

# ---- 流量消耗核心 ----

# 下载一次 100MB 文件，返回实际下载字节数
download_100mb() {
  local url dl_bytes

  for url in "${DOWNLOAD_URLS[@]}"; do
    dl_bytes="$(timeout 300 curl -L -s \
      --max-time 240 \
      --output /dev/null \
      -w '%{size_download}' \
      "$url" 2>/dev/null || echo '0')"

    dl_bytes="${dl_bytes%%.*}"
    dl_bytes="${dl_bytes:-0}"

    # 至少下载了 50MB 算成功
    if [ "$dl_bytes" -gt 52428800 ] 2>/dev/null; then
      echo "$dl_bytes"
      return 0
    fi
  done

  echo "0"
  return 1
}

consume_once() {
  local target_mb="$TARGET_MB_PER_HOUR"
  local times=$((target_mb / CHUNK_MB))
  local interval=$((3600 / times))
  local total_downloaded=0

  local start_ts
  start_ts="$(date +%s)"

  print_info "本轮目标：${target_mb}MB，拆分为 ${times} 次下载（每次 100MB），间隔约 ${interval} 秒。"

  local i
  for ((i = 1; i <= times; i++)); do
    print_info "第 ${i}/${times} 次下载开始..."

    local dl_bytes
    dl_bytes="$(download_100mb)"

    if [ "$dl_bytes" -gt 0 ] 2>/dev/null; then
      local dl_mb=$((dl_bytes / 1024 / 1024))
      total_downloaded=$((total_downloaded + dl_mb))
      print_ok "第 ${i}/${times} 次完成，本次 ${dl_mb}MB，累计 ${total_downloaded}MB。"
    else
      print_warn "第 ${i}/${times} 次所有下载源均失败。"
    fi

    # 如果不是最后一次，等待间隔时间
    if [ "$i" -lt "$times" ]; then
      local now elapsed remaining_time wait_s
      now="$(date +%s)"
      elapsed=$((now - start_ts))
      # 计算理想的下一次开始时间
      remaining_time=$(( i * interval - elapsed ))
      if [ "$remaining_time" -gt 0 ]; then
        wait_s="$remaining_time"
      else
        wait_s=5
      fi
      print_info "等待 ${wait_s} 秒后开始第 $((i + 1)) 次下载..."
      sleep "$wait_s" || true
    fi
  done

  local end_ts
  end_ts="$(date +%s)"
  print_ok "本轮完成。目标 ${target_mb}MB，实际约 ${total_downloaded}MB，耗时 $((end_ts - start_ts)) 秒。"
}

# ---- 守护进程 ----

daemon_loop() {
  local mb_from_arg="${1:-}"

  if is_multiple_of_100 "$mb_from_arg"; then
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
  trap 'rm -f "$PID_FILE"' EXIT INT TERM

  print_ok "流量消耗守护进程已启动，PID=$$，目标=${TARGET_MB_PER_HOUR}MB/小时"

  while true; do
    local round_start now elapsed sleep_s
    round_start="$(date +%s)"

    print_info "======= 新一轮开始：$(date '+%F %T') ======="
    consume_once || true

    now="$(date +%s)"
    elapsed=$((now - round_start))
    if [ "$elapsed" -lt 3600 ]; then
      sleep_s=$((3600 - elapsed))
      print_info "本轮完成，休眠 ${sleep_s} 秒后进入下一轮。"
      sleep "$sleep_s" || true
    else
      print_warn "本轮执行超过 1 小时，立即开始下一轮。"
    fi
  done
}

# ---- 开启 ----

start_consumer() {
  # 运行前检查并安装依赖
  print_info "检查依赖..."
  if ! check_and_install_deps; then
    print_err "依赖检查失败，无法启动。"
    return 1
  fi
  echo ""

  local mb_input
  mb_input="$(prompt_target_mb)"

  TARGET_MB_PER_HOUR="$mb_input"
  save_target_mb_config "$TARGET_MB_PER_HOUR"

  local times=$((TARGET_MB_PER_HOUR / CHUNK_MB))

  cleanup_stale_pid
  if is_running; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    print_warn "已在运行中（PID: ${pid}）。如需修改流量，请先关闭再重新开启。"
    return 0
  fi

  nohup bash "$SCRIPT_PATH" daemon "$TARGET_MB_PER_HOUR" >> "$LOG_FILE" 2>&1 &
  sleep 2

  if is_running; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    print_ok "已开启流量消耗器（PID: ${pid}）。"
    print_info "目标流量：${TARGET_MB_PER_HOUR}MB/小时（每小时 ${times} 次，每次 100MB）"
    print_info "日志文件：${LOG_FILE}"
  else
    print_err "启动失败，请检查日志：${LOG_FILE}"
    if [ -f "$LOG_FILE" ]; then
      echo "--- 最后 5 行日志 ---"
      tail -n 5 "$LOG_FILE" 2>/dev/null || true
    fi
    return 1
  fi
}

# ---- 关闭（含清理） ----

kill_process_tree() {
  local pid="$1"
  local pgid
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"

  if [ -n "$pgid" ] && [ "$pgid" != "0" ]; then
    kill -- -"$pgid" >/dev/null 2>&1 || true
    sleep 1
    kill -9 -- -"$pgid" >/dev/null 2>&1 || true
  else
    kill "$pid" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi
}

remove_systemd_service() {
  if ! command -v systemctl >/dev/null 2>&1; then
    print_warn "未检测到 systemctl，跳过 systemd 清理。"
    return 0
  fi
  print_info "移除 systemd 服务与自启（需要 sudo 权限）..."
  sudo systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  sudo systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  sudo rm -f "$SERVICE_PATH"
  sudo systemctl daemon-reload 2>/dev/null || true
  print_ok "systemd 服务已移除。"
}

cleanup_generated_files() {
  rm -f "$PID_FILE" "$LOG_FILE" "$CONFIG_FILE" "$SERVICE_TMP_PATH"
  print_ok "已清理脚本产生的本地文件（PID/LOG/CONFIG/TMP）。"
}

full_cleanup() {
  local was_running=0

  cleanup_stale_pid
  if is_running; then
    was_running=1
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
      kill_process_tree "$pid"
      print_ok "已停止流量消耗器（PID: ${pid}）及其子进程。"
    fi
  fi

  remove_systemd_service
  cleanup_generated_files

  if [ "$was_running" -eq 0 ]; then
    print_info "进程原本未运行。"
  fi
  print_ok "已完成关闭与清理（含自启、systemd 文件、配置和日志）。"
}

stop_consumer() {
  full_cleanup
}

uninstall_systemd_service() {
  full_cleanup
}

# ---- 开机自启 ----

install_systemd_service() {
  load_target_mb_config

  if [[ "$SCRIPT_PATH" == *" "* ]]; then
    print_warn "脚本路径含空格，可能导致 systemd ExecStart 解析异常。"
  fi

  cat > "$SERVICE_TMP_PATH" <<EOF_SERVICE
[Unit]
Description=Traffic Consumer (${TARGET_MB_PER_HOUR}MB/hour)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash ${SCRIPT_PATH} daemon ${TARGET_MB_PER_HOUR}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  print_info "写入 systemd 服务文件（需要 sudo 权限）..."
  sudo cp "$SERVICE_TMP_PATH" "$SERVICE_PATH"
  sudo chmod 644 "$SERVICE_PATH"
  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE_NAME"

  print_ok "开机自启已启用：${SERVICE_NAME}"
  print_info "目标流量：${TARGET_MB_PER_HOUR}MB/小时"
  print_info "如需立即启动可执行：sudo systemctl start ${SERVICE_NAME}"
}

# ---- 状态查看 ----

show_status() {
  load_target_mb_config
  local times=$((TARGET_MB_PER_HOUR / CHUNK_MB))

  echo ""
  echo "==================== 状态 ===================="

  if is_running; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    print_ok "运行状态：运行中（PID: ${pid}）"
  else
    print_warn "运行状态：未运行"
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

  echo ""
  echo "--- 依赖 ---"
  if command -v curl >/dev/null 2>&1; then
    print_ok "curl：已安装"
  else
    print_err "curl：未安装（必需）"
  fi

  echo ""
  print_info "目标流量：${TARGET_MB_PER_HOUR}MB/小时（每小时 ${times} 次，每次 100MB）"
  print_info "下载源：${DOWNLOAD_URLS[0]}"
  print_info "PID 文件：${PID_FILE}"
  print_info "日志文件：${LOG_FILE}"
  print_info "配置文件：${CONFIG_FILE}"

  if [ -f "$LOG_FILE" ]; then
    echo ""
    echo "------------- 最近日志（最后 15 行） -------------"
    tail -n 15 "$LOG_FILE" 2>/dev/null || true
  else
    print_info "暂无日志文件。"
  fi
  echo "================================================="
}

# ---- 菜单 UI ----

show_banner() {
  echo ""
  echo "=================================================="
  echo "           流量消耗器 Traffic Consumer"
  echo "=================================================="
}

show_menu() {
  echo ""
  echo "请选择操作："
  echo "  1) 开启"
  echo "  2) 关闭"
  echo "  3) 开机自启"
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

    case "${choice:-}" in
      1) start_consumer || true ;;
      2) stop_consumer || true ;;
      3) install_systemd_service || true ;;
      4) uninstall_systemd_service || true ;;
      5) show_status || true ;;
      0)
        print_ok "已退出。"
        exit 0
        ;;
      *)
        print_warn "无效选项，请输入 0-5。"
        ;;
    esac

    echo ""
    read -r -p "按回车键继续..." _ </dev/tty
  done
}

# ---- 入口 ----

main() {
  local cmd="${1:-}"

  case "$cmd" in
    daemon) daemon_loop "${2:-}" ;;
    *)      run_ui ;;
  esac
}

main "$@"
