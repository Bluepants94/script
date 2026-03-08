#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")")"

TARGET_SCRIPT="docker-compose-auto-update.sh"
TARGET_CONFIG="docker-compose-projects.list"
TARGET_SCRIPT_PATH="${SCRIPT_DIR}/${TARGET_SCRIPT}"
TARGET_CONFIG_PATH="${SCRIPT_DIR}/${TARGET_CONFIG}"

BASE_URL="https://raw.githubusercontent.com/Bluepants94/script/refs/heads/main/docker-compose-auto-update"
SCRIPT_URL="${BASE_URL}/${TARGET_SCRIPT}"
CONFIG_URL="${BASE_URL}/${TARGET_CONFIG}"

CRON_TAG="# docker-compose-auto-update-managed"
DEFAULT_INTERVAL_HOURS=6

get_crontab_content() {
  crontab -l 2>/dev/null || true
}

get_managed_cron_line() {
  get_crontab_content | grep -F "$CRON_TAG" | tail -n 1 || true
}

get_managed_schedule() {
  local line
  line="$(get_managed_cron_line)"
  if [[ -z "$line" ]]; then
    echo "未设置"
  else
    echo "$line" | awk '{print $1" "$2" "$3" "$4" "$5}'
  fi
}

get_managed_interval() {
  local line hour_field
  line="$(get_managed_cron_line)"
  hour_field="$(echo "$line" | awk '{print $2}')"
  if [[ "$hour_field" =~ ^\*/([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

cron_status() {
  if [[ -n "$(get_managed_cron_line)" ]]; then
    echo "已启用"
  else
    echo "未启用"
  fi
}

script_status() {
  if [[ -f "$TARGET_SCRIPT_PATH" ]]; then
    echo "已下载"
  else
    echo "未下载"
  fi
}

config_status() {
  if [[ -f "$TARGET_CONFIG_PATH" ]]; then
    echo "已下载"
  else
    echo "未下载"
  fi
}

render_home() {
  clear
  echo "=============================================="
  echo " docker-compose-auto-update 控制台"
  echo "=============================================="
  echo "脚本目录        : $SCRIPT_DIR"
  echo "Crontab 状态    : $(cron_status)"
  echo "Crontab 定时    : $(get_managed_schedule)"
  echo "更新脚本状态    : $(script_status)"
  echo "配置文件状态    : $(config_status)"
  echo "----------------------------------------------"
  echo "1) 安装/更新"
  echo "2) 卸载"
  echo "3) 更新间隔（crontab 定时间隔）"
  echo "0) 退出"
  echo "=============================================="
}

safe_download() {
  local url="$1"
  local dest="$2"
  local tmp_file
  tmp_file="${dest}.tmp.$$"

  if ! command -v curl >/dev/null 2>&1; then
    echo "[错误] 未找到 curl，请先安装 curl。"
    return 1
  fi

  if ! curl -fsSL "$url" -o "$tmp_file"; then
    echo "[错误] 下载失败: $url"
    rm -f "$tmp_file"
    return 1
  fi

  mv "$tmp_file" "$dest"
  return 0
}

write_managed_cron() {
  local interval="$1"
  local cron_line current

  cron_line="0 */${interval} * * * \"${TARGET_SCRIPT_PATH}\" ${CRON_TAG}"
  current="$(get_crontab_content | grep -vF "$CRON_TAG" || true)"

  {
    if [[ -n "${current//[[:space:]]/}" ]]; then
      echo "$current"
    fi
    echo "$cron_line"
  } | crontab -
}

remove_managed_cron() {
  local current
  current="$(get_crontab_content | grep -vF "$CRON_TAG" || true)"
  if [[ -n "${current//[[:space:]]/}" ]]; then
    echo "$current" | crontab -
  else
    crontab -r 2>/dev/null || true
  fi
}

install_or_update() {
  local interval
  echo
  echo "[安装/更新] 开始下载文件..."

  if ! safe_download "$SCRIPT_URL" "$TARGET_SCRIPT_PATH"; then
    echo "[失败] 更新脚本下载失败。"
    return
  fi

  chmod +x "$TARGET_SCRIPT_PATH"

  if [[ -f "$TARGET_CONFIG_PATH" ]]; then
    echo "[提示] 检测到已存在配置文件，默认保留本地配置：$TARGET_CONFIG_PATH"
  else
    if ! safe_download "$CONFIG_URL" "$TARGET_CONFIG_PATH"; then
      echo "[警告] 配置文件下载失败，请稍后手动创建：$TARGET_CONFIG_PATH"
    else
      echo "[成功] 配置文件已下载：$TARGET_CONFIG_PATH"
    fi
  fi

  interval="$(get_managed_interval)"
  if [[ -z "$interval" ]]; then
    interval="$DEFAULT_INTERVAL_HOURS"
  fi

  write_managed_cron "$interval"
  echo "[成功] 安装/更新完成，当前定时：每 ${interval} 小时执行一次。"
}

uninstall_all() {
  echo
  read -r -p "确认卸载？将移除 crontab 任务及本目录所有相关文件（含日志与控制脚本）[y/N]: " ans
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    echo "[取消] 未执行卸载。"
    return
  fi

  remove_managed_cron
  rm -f \
    "$TARGET_SCRIPT_PATH" \
    "$TARGET_CONFIG_PATH" \
    "${SCRIPT_DIR}/docker-compose-auto-update.log"

  echo "[成功] 已移除 crontab 任务与相关文件。"
  echo "[提示] 控制脚本将自删除并退出。"

  # 延迟自删除，避免脚本运行中直接删除自身导致异常
  (sleep 1; rm -f "$SELF_PATH") >/dev/null 2>&1 &
  exit 0
}

update_interval() {
  local hours
  echo
  read -r -p "请输入间隔小时（1-23）: " hours
  if [[ ! "$hours" =~ ^[0-9]+$ ]] || (( hours < 1 || hours > 23 )); then
    echo "[错误] 请输入 1 到 23 的整数。"
    return
  fi

  if [[ ! -f "$TARGET_SCRIPT_PATH" ]]; then
    echo "[错误] 未检测到更新脚本：$TARGET_SCRIPT_PATH"
    echo "请先执行“1) 安装/更新”。"
    return
  fi

  write_managed_cron "$hours"
  echo "[成功] 定时已更新为每 ${hours} 小时执行一次。"
}

main() {
  while true; do
    render_home
    read -r -p "请选择操作 [0-3]: " choice
    case "$choice" in
      1)
        install_or_update
        ;;
      2)
        uninstall_all
        ;;
      3)
        update_interval
        ;;
      0)
        echo "已退出。"
        exit 0
        ;;
      *)
        echo "无效选择，请输入 0-3。"
        ;;
    esac

    echo
    read -r -p "按回车键返回首页..." _
  done
}

main
