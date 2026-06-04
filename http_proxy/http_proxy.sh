#!/bin/bash
# ============================================================================
# Tinyproxy HTTP 代理管理脚本（交互式）
# ============================================================================
set -Euo pipefail

# ---------- 常量 ----------
CONF="/etc/tinyproxy/tinyproxy.conf"
CONF_BAK="/etc/tinyproxy/tinyproxy.conf.bak"
WHITELIST_URL="https://raw.githubusercontent.com/Bluepants94/script/refs/heads/main/http_proxy/whitelist"
WHITELIST_FILE="/etc/tinyproxy/whitelist"
IP_ALLOW_FILE="/etc/tinyproxy/allow_ip.txt"

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

print_info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
print_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
print_err()   { echo -e "${RED}[ERR]${NC}   $1"; }

# ---------- 信号 ----------
trap '' INT

# ---------- 工具 ----------
check_sudo() { command -v sudo &>/dev/null || { print_err "未找到 sudo 命令。"; exit 1; }; }

is_active() { systemctl -q is-active tinyproxy 2>/dev/null; }

# ---------- 安装 ----------
install_tinyproxy() {
  local pm=""
  for p in apt dnf yum pacman; do command -v "$p" &>/dev/null && { pm="$p"; break; }; done
  [ -z "$pm" ] && { print_err "未识别包管理器，请手动安装 tinyproxy。"; exit 1; }
  check_sudo
  print_info "正在通过 ${pm} 安装 tinyproxy..."
  case "$pm" in
    apt)    sudo apt update && sudo apt install -y tinyproxy ;;
    dnf)    sudo dnf install -y tinyproxy ;;
    yum)    sudo yum install -y epel-release && sudo yum install -y tinyproxy ;;
    pacman) sudo pacman -Sy --noconfirm tinyproxy ;;
  esac
  command -v tinyproxy &>/dev/null && { print_ok "tinyproxy 安装成功。"; return 0; }
  print_err "tinyproxy 安装失败。"; exit 1
}

check_tinyproxy() {
  command -v tinyproxy &>/dev/null && return 0
  print_warn "tinyproxy 未安装，正在自动安装..."
  install_tinyproxy
}

# ---------- 域名白名单下载（静默） ----------
download_whitelist() {
  [ -f "$WHITELIST_FILE" ] && [ -s "$WHITELIST_FILE" ] && return 0
  check_sudo
  sudo mkdir -p /etc/tinyproxy 2>/dev/null || true
  local tool=""
  command -v curl  &>/dev/null && tool="curl"
  command -v wget  &>/dev/null && tool="wget"
  [ -z "$tool" ] && return 1
  if [ "$tool" = "curl" ]; then
    sudo curl -sSL -o "$WHITELIST_FILE" "$WHITELIST_URL" 2>/dev/null \
      || { sudo rm -f "$WHITELIST_FILE"; return 1; }
  else
    sudo wget -q  -O "$WHITELIST_FILE" "$WHITELIST_URL" 2>/dev/null \
      || { sudo rm -f "$WHITELIST_FILE"; return 1; }
  fi
  [ -s "$WHITELIST_FILE" ] || { sudo rm -f "$WHITELIST_FILE"; return 1; }
}

# ---------- 配置文件有效性 ----------
filter_has_rules() {
  [ -f "$1" ] && [ -s "$1" ] || return 1
  awk 'NF>0 && !/^[[:space:]]*#/{exit 0} END{exit 1}' "$1"
}

allow_has_ips() {
  [ -f "$1" ] && [ -s "$1" ] || return 1
  awk 'NF>0 && !/^[[:space:]]*#/{exit 0} END{exit 1}' "$1"
}

# ================================================================
#  配置修改（sed 原地编辑 /etc/tinyproxy/tinyproxy.conf）
# ================================================================

# 首次运行时备份原始配置
backup_conf() {
  [ -f "$CONF" ] && [ ! -f "$CONF_BAK" ] && sudo cp "$CONF" "$CONF_BAK"
}

# --- 域名白名单 ---
# 通用：设置配置项。存在未注释的则修改；否则追加到末尾。不修改带 # 的系统注释说明。
conf_set() {
  local key="$1" val="$2"
  if grep -qE "^[[:space:]]*${key}[[:space:]]" "$CONF" 2>/dev/null; then
    sudo sed -i -E "s|^[[:space:]]*(${key})[[:space:]].*|${key} ${val}|" "$CONF"
  else
    echo "${key} ${val}" | sudo tee -a "$CONF" >/dev/null
  fi
}
# 通用：删除生效的配置项（恢复默认行为）
conf_delete() {
  local key="$1"
  sudo sed -i -E "/^[[:space:]]*${key}[[:space:]]/d" "$CONF"
}

enable_domain_whitelist() {
  backup_conf
  # 确保 whitelist 文件已下载
  download_whitelist || { print_err "白名单文件下载失败。"; return 1; }

  conf_set 'Filter'              '"/etc/tinyproxy/whitelist"'
  conf_set 'FilterDefaultDeny'   'Yes'
  conf_set 'FilterExtended'      'On'
  conf_set 'FilterCaseSensitive' 'No'
  conf_set 'FilterURLs'          'No'
}

disable_domain_whitelist() {
  backup_conf
  # 删除我们添加的生效配置项（恢复默认状态）
  conf_delete 'Filter'
  conf_delete 'FilterDefaultDeny'
  conf_delete 'FilterExtended'
  conf_delete 'FilterCaseSensitive'
  conf_delete 'FilterURLs'
}

# --- IP 白名单 ---
enable_ip_whitelist() {
  backup_conf
  check_sudo
  sudo mkdir -p /etc/tinyproxy 2>/dev/null || true
  # 如果 allow_ip.txt 不存在，创建模板
  if [ ! -f "$IP_ALLOW_FILE" ]; then
    sudo tee "$IP_ALLOW_FILE" >/dev/null <<'IPEOF'
# 每行一个 IP 或 CIDR
# 例如: 192.168.1.0/24
IPEOF
  fi
  # 先清除外部的 Allow 行，但保留默认的 127.0.0.1 和 ::1
  sudo sed -i -E '/^Allow[[:space:]]+(127\.0\.0\.1|::1)[[:space:]]*$/!{/^Allow[[:space:]]/d;}' "$CONF"
  # 确保默认的 localhost 在文件里
  grep -qE '^Allow[[:space:]]+127\.0\.0\.1' "$CONF" 2>/dev/null || echo "Allow 127.0.0.1" | sudo tee -a "$CONF" >/dev/null
  grep -qE '^Allow[[:space:]]+::1' "$CONF" 2>/dev/null || echo "Allow ::1" | sudo tee -a "$CONF" >/dev/null

  # 从 allow_ip.txt 读取并追加
  if allow_has_ips "$IP_ALLOW_FILE"; then
    awk 'NF>0 && !/^[[:space:]]*#/{print "Allow "$0}' "$IP_ALLOW_FILE" \
      | sudo tee -a "$CONF" >/dev/null
  fi
}

disable_ip_whitelist() {
  backup_conf
  # 删除外部 Allow 行，保留默认的 127.0.0.1 和 ::1
  sudo sed -i -E '/^Allow[[:space:]]+(127\.0\.0\.1|::1)[[:space:]]*$/!{/^Allow[[:space:]]/d;}' "$CONF"
  # 确保默认的 localhost 在文件里
  grep -qE '^Allow[[:space:]]+127\.0\.0\.1' "$CONF" 2>/dev/null || echo "Allow 127.0.0.1" | sudo tee -a "$CONF" >/dev/null
  grep -qE '^Allow[[:space:]]+::1' "$CONF" 2>/dev/null || echo "Allow ::1" | sudo tee -a "$CONF" >/dev/null
}

# ---------- 状态读取 ----------
# 域名白名单是否开启：检查 conf 中是否存在未注释的 Filter 行
is_domain_whitelist_on() {
  grep -qE '^Filter[[:space:]]' "$CONF" 2>/dev/null
}

# IP 白名单是否开启：检查 conf 中是否存在未注释的 Allow 行
is_ip_whitelist_on() {
  # 检查是否存在除 127.0.0.1 和 ::1 之外的 Allow 行
  grep -E '^Allow[[:space:]]' "$CONF" 2>/dev/null | grep -qvE 'Allow[[:space:]]+(127\.0\.0\.1|::1)[[:space:]]*$'
}

# ---------- 代理控制 ----------
start_proxy() {
  check_tinyproxy; check_sudo; backup_conf

  # 读取当前配置端口
  local cur_port
  cur_port="$(awk '/^Port[[:space:]]+/{print $2;exit}' "$CONF" 2>/dev/null || echo "8888")"

  local input_port
  read -r -p "代理端口 (默认 ${cur_port}): " input_port
  input_port="${input_port:-$cur_port}"

  # 如果端口变了，写入配置
  if [ "$input_port" != "$cur_port" ]; then
    sudo sed -i -E "s|^(Port[[:space:]]+).*|Port ${input_port}|" "$CONF"
  fi

  sudo systemctl restart tinyproxy 2>/dev/null \
    && print_ok "代理已启动（端口 ${input_port}）。" \
    || print_err "启动失败。"
}

stop_proxy() {
  check_sudo
  sudo systemctl stop tinyproxy 2>/dev/null \
    && print_ok "代理已停止。" \
    || print_err "停止失败。"
}

reload_proxy() {
  if ! is_active; then
    print_warn "代理未运行，无需重载。"; return 1
  fi
  check_sudo
  sudo systemctl reload tinyproxy 2>/dev/null \
    && print_ok "代理配置已重载。" \
    || print_err "重载失败。"
}

# ---------- 开关 ----------
toggle_proxy() {
  if is_active; then stop_proxy; else start_proxy; fi
}

toggle_ip_whitelist() {
  if is_ip_whitelist_on; then
    disable_ip_whitelist
  else
    enable_ip_whitelist
  fi
  is_active && reload_proxy
}

toggle_domain_whitelist() {
  if is_domain_whitelist_on; then
    disable_domain_whitelist
  else
    enable_domain_whitelist
  fi
  is_active && reload_proxy
}

# ---------- UI ----------
show_banner() {
  local ps="" pi=""
  if is_active && [ -f "$CONF" ]; then
    local p l
    p="$(awk '/^Port[[:space:]]+/{print $2;exit}'   "$CONF" 2>/dev/null || echo "?")"
    l="$(awk '/^Listen[[:space:]]+/{print $2;exit}' "$CONF" 2>/dev/null || echo "?")"
    ps="${GREEN}● 已启动${NC}"; pi="  监听:       ${l}:${p}"
  else
    ps="${RED}○ 未启动${NC}"
  fi
  echo ""
  echo "=================================================="
  echo "        Tinyproxy HTTP 代理管理工具"
  echo "=================================================="
  echo "  配置路径: /etc/tinyproxy"
  echo -e "  代理状态: $ps"
  [ -n "$pi" ] && echo "$pi"
  echo -e "  IP 白名单:  $(is_ip_whitelist_on     && echo "${GREEN}● 已开启${NC}" || echo "${RED}○ 未开启${NC}")"
  echo -e "  域名白名单: $(is_domain_whitelist_on  && echo "${GREEN}● 已开启${NC}" || echo "${RED}○ 未开启${NC}")"
}

show_menu() {
  local r=false; is_active && r=true
  echo ""
  echo "  1) $($r && echo '关闭' || echo '开启')代理"
  echo "  2) $(is_ip_whitelist_on    && echo '关闭' || echo '开启')IP白名单"
  echo "  3) $(is_domain_whitelist_on && echo '关闭' || echo '开启')域名白名单"
  echo "  4) 重载代理"
  echo "  0) 退出"
  printf "输入选项 [0-4]: "
}

run_ui() {
  check_tinyproxy
  # 后台静默下载白名单文件
  [ -f "$WHITELIST_FILE" ] && [ -s "$WHITELIST_FILE" ] || (download_whitelist &>/dev/null &)

  while true; do
    show_banner; show_menu
    IFS= read -r c
    case "${c}" in
      1) toggle_proxy            ; continue ;;
      2) toggle_ip_whitelist     ; continue ;;
      3) toggle_domain_whitelist ; continue ;;
      4) reload_proxy            ; continue ;;
      0) exit 0 ;;
      *) continue ;;
    esac
  done
}

run_ui

