#!/usr/bin/env bash
set -u -o pipefail

INSTALL_DIR="/opt/docker-compose-auto-update"

TARGET_SCRIPT="docker-compose-auto-update.sh"
TARGET_CONFIG="docker-compose-projects.list"
TARGET_SCRIPT_PATH="${INSTALL_DIR}/${TARGET_SCRIPT}"
TARGET_CONFIG_PATH="${INSTALL_DIR}/${TARGET_CONFIG}"
TARGET_LOG_PATH="${INSTALL_DIR}/docker-compose-auto-update.log"

BASE_URL="https://raw.githubusercontent.com/Bluepants94/script/refs/heads/main/docker-compose-auto-update"
SCRIPT_URL="${BASE_URL}/${TARGET_SCRIPT}"
CONFIG_URL="${BASE_URL}/${TARGET_CONFIG}"

CRON_TAG="# docker-compose-auto-update-managed"
DEFAULT_INTERVAL_HOURS=6

clear_screen() {
  if command -v clear >/dev/null 2>&1; then
    clear
  fi
}

get_crontab_content() {
  crontab -l 2>/dev/null || true
}

get_managed_cron_line() {
  get_crontab_content \
    | grep -F "\"${TARGET_SCRIPT_PATH}\"" \
    | grep -F "$CRON_TAG" \
    | tail -n 1 || true
}

filter_out_managed_cron() {
  get_crontab_content | awk -v script="$TARGET_SCRIPT_PATH" -v tag="$CRON_TAG" '
    !(index($0, script) > 0 && index($0, tag) > 0)
  '
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
  if [[ -f "$TARGET_SCRIPT_PATH" && -f "$TARGET_CONFIG_PATH" ]]; then
    echo "已下载"
  else
    echo "未下载"
  fi
}

render_home() {
  clear_screen
  echo "=============================================="
  echo " docker-compose-auto-update 控制台"
  echo "=============================================="
  echo "安装目录        : $INSTALL_DIR"
  echo "Crontab 状态    : $(cron_status)"
  echo "Crontab 定时    : $(get_managed_schedule)"
  echo "脚本状态        : $(script_status)"
  echo "----------------------------------------------"
  echo "1) 安装/更新"
  echo "2) 卸载"
  echo "3) 更新间隔（crontab 定时间隔）"
  echo "4) 立即更新（立刻执行一次）"
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

  if ! mv "$tmp_file" "$dest"; then
    echo "[错误] 写入文件失败: $dest"
    rm -f "$tmp_file"
    return 1
  fi

  return 0
}

ensure_installed_script() {
  if [[ ! -f "$TARGET_SCRIPT_PATH" ]]; then
    echo "[错误] 未检测到更新脚本：$TARGET_SCRIPT_PATH"
    echo "请先执行“1) 安装/更新”。"
    return 1
  fi

  if [[ ! -x "$TARGET_SCRIPT_PATH" ]]; then
    if ! chmod +x "$TARGET_SCRIPT_PATH"; then
      echo "[错误] 更新脚本不可执行，且无法自动修复权限：$TARGET_SCRIPT_PATH"
      return 1
    fi
  fi

  return 0
}

write_managed_cron() {
  local interval="$1"
  local cron_line current

  cron_line="0 */${interval} * * * \"${TARGET_SCRIPT_PATH}\" ${CRON_TAG}"
  current="$(filter_out_managed_cron || true)"

  if ! {
    if [[ -n "${current//[[:space:]]/}" ]]; then
      echo "$current"
    fi
    echo "$cron_line"
  } | crontab -; then
    echo "[错误] 写入 crontab 失败。"
    return 1
  fi

  return 0
}

remove_managed_cron() {
  local current
  current="$(filter_out_managed_cron || true)"
  if [[ -n "${current//[[:space:]]/}" ]]; then
    if ! echo "$current" | crontab -; then
      echo "[错误] 更新 crontab 失败。"
      return 1
    fi
  else
    if ! crontab -r 2>/dev/null; then
      echo "[错误] 清空 crontab 失败。"
      return 1
    fi
  fi

  return 0
}

install_or_update() {
  local interval
  echo
  echo "[安装/更新] 开始下载文件..."

  if ! mkdir -p "$INSTALL_DIR"; then
    echo "[错误] 无法创建安装目录: $INSTALL_DIR"
    return
  fi

  if [[ ! -w "$INSTALL_DIR" ]]; then
    echo "[错误] 安装目录不可写: $INSTALL_DIR"
    echo "[提示] 请使用 root 权限运行。"
    return
  fi

  if ! safe_download "$SCRIPT_URL" "$TARGET_SCRIPT_PATH"; then
    echo "[失败] 更新脚本下载失败。"
    return
  fi

  if ! chmod +x "$TARGET_SCRIPT_PATH"; then
    echo "[错误] 无法设置可执行权限：$TARGET_SCRIPT_PATH"
    return
  fi

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

  if ! write_managed_cron "$interval"; then
    echo "[失败] 定时任务写入失败。"
    return
  fi

  echo "[成功] 安装/更新完成，当前定时：每 ${interval} 小时执行一次。"
}

uninstall_all() {
  echo
  read -r -p "确认卸载？将移除 crontab 任务及本目录相关文件（脚本/配置/日志）[y/N]: " ans
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    echo "[取消] 未执行卸载。"
    return
  fi

  if ! remove_managed_cron; then
    echo "[失败] 卸载过程中移除 crontab 失败。"
    return
  fi

  rm -f \
    "$TARGET_SCRIPT_PATH" \
    "$TARGET_CONFIG_PATH" \
    "$TARGET_LOG_PATH"

  rmdir "$INSTALL_DIR" 2>/dev/null || true
  echo "[成功] 已移除 crontab 任务与相关文件。"
}

update_interval() {
  local hours
  echo
  read -r -p "请输入间隔小时（1-23）: " hours
  if [[ ! "$hours" =~ ^[0-9]+$ ]] || (( hours < 1 || hours > 23 )); then
    echo "[错误] 请输入 1 到 23 的整数。"
    return
  fi

  if ! ensure_installed_script; then
    return
  fi

  if ! write_managed_cron "$hours"; then
    echo "[失败] 定时更新失败。"
    return
  fi

  echo "[成功] 定时已更新为每 ${hours} 小时执行一次。"
}

run_update_now() {
  echo
  if ! ensure_installed_script; then
    return
  fi

  echo "[执行] 正在立即运行更新脚本..."
  if "$TARGET_SCRIPT_PATH"; then
    echo "[成功] 立即更新执行完成。"
  else
    echo "[失败] 立即更新执行失败，请检查日志：$TARGET_LOG_PATH"
  fi
}

main() {
  while true; do
    render_home
    read -r -p "请选择操作 [0-4]: " choice
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
      4)
        run_update_now
        ;;
      0)
        echo "已退出。"
        exit 0
        ;;
      *)
        echo "无效选择，请输入 0-4。"
        ;;
    esac

    echo
    read -r -p "按回车键返回首页..." _
  done
}

main
