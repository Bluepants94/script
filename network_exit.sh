#!/usr/bin/env bash
# 注意：本脚本为交互式运维脚本，未启用 set -e（允许部分命令失败后继续）
set -u
set -o pipefail

# ============================================================
# 默认出站源地址管理脚本（安全增强版）
# 目标：
#   - 默认新建连接优先使用内网 IP 作为源地址
#   - 实际下一跳保持当前公网网关
#   - 保留公网 IP 独立策略，降低 SSH/公网入站回包异常风险
# ============================================================

# ---------- 颜色定义 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------- 路径与常量 ----------
STATE_DIR="/var/lib/default-src-ip"
STATE_FILE="${STATE_DIR}/state.env"
LOCK_DIR="${STATE_DIR}/.lock"
APPLY_BIN="/usr/local/sbin/default-src-ip-apply"
SERVICE_NAME="default-src-ip.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
SYSCTL_FILE="/etc/sysctl.d/90-default-src-ip.conf"
PROBE_TARGET="1.1.1.1"

RULE_PREF_PRIVATE=100
RULE_PREF_PUBLIC=110
TABLE_PRIVATE=100
TABLE_PUBLIC=200

LAST_RESULT_TYPE=""
LAST_RESULT_MSG=""

ORIG_DEFAULT_VIA=""
ORIG_DEFAULT_DEV=""
ORIG_DEFAULT_SRC=""

IFACE=""
PUBLIC_GW=""
PUBLIC_IP=""
PUBLIC_CIDR=""
PRIVATE_IP=""
PRIVATE_CIDR=""

LOCK_PID_FILE="${LOCK_DIR}/pid"

# ---------- UI ----------
print_banner() {
  clear 2>/dev/null || true
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════════╗"
  echo "║      默认出站源地址管理器（安全增强版）      ║"
  echo "╚══════════════════════════════════════════════╝"
  echo -e "${NC}"
}

print_section() {
  echo
  echo -e "${BLUE}[ $1 ]${NC}"
  echo "------------------------------------------------------------"
}

print_info()    { echo -e "${CYAN}[信息]${NC} $1"; }
print_warn()    { echo -e "${YELLOW}[警告]${NC} $1"; }
print_error()   { echo -e "${RED}[错误]${NC} $1" >&2; }
print_success() { echo -e "${GREEN}[成功]${NC} $1"; }

set_last_result() { LAST_RESULT_TYPE="$1"; LAST_RESULT_MSG="$2"; }

show_last_result() {
  [[ -z "$LAST_RESULT_MSG" ]] && return
  case "$LAST_RESULT_TYPE" in
    success) print_success "$LAST_RESULT_MSG" ;;
    warn)    print_warn "$LAST_RESULT_MSG" ;;
    error)   print_error "$LAST_RESULT_MSG" ;;
    *)       print_info "$LAST_RESULT_MSG" ;;
  esac
  echo
  LAST_RESULT_TYPE=""
  LAST_RESULT_MSG=""
}

kv() {
  # 使用制表符分隔，减少中文字段在不同终端下的对齐偏差
  printf "  %s\t%s\n" "$1" "$2"
}

pause() {
  echo
  read -r -p "按回车继续..." _
}

read_menu_choice() {
  local prompt="$1" regex="$2" value
  while true; do
    read -r -p "$prompt" value
    [[ "$value" =~ $regex ]] && { echo "$value"; return 0; }
    print_error "输入无效，请重新输入！"
  done
}

read_confirm_yn_default() {
  local prompt="$1" default_value="$2" value
  while true; do
    read -r -p "$prompt" value
    value=${value:-$default_value}
    case "$value" in
      Y|y) echo "Y"; return 0 ;;
      N|n) echo "N"; return 0 ;;
      *)   print_error "输入无效，请输入 Y 或 N" ;;
    esac
  done
}

# ---------- 基础检查 ----------
require_root() {
  [[ $EUID -eq 0 ]] || { print_error "请使用 root 运行"; exit 1; }
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    print_error "缺少命令: $1"
    exit 1
  }
}

check_dependencies() {
  local c
  for c in ip awk grep sed sysctl systemctl; do
    need_cmd "$c"
  done
  command -v curl >/dev/null 2>&1 || print_warn "未检测到 curl，公网 IP 测试功能将受限"
  command -v ping >/dev/null 2>&1 || print_warn "未检测到 ping，连通性测试功能将受限"
}

init_runtime() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_PID_FILE" 2>/dev/null || true
    return 0
  fi

  if [[ -f "$LOCK_PID_FILE" ]]; then
    local lock_pid
    lock_pid="$(sed -n '1p' "$LOCK_PID_FILE" 2>/dev/null || true)"
    if [[ "$lock_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
      print_warn "检测到陈旧锁，正在清理..."
      rm -f "$LOCK_PID_FILE" 2>/dev/null || true
      rmdir "$LOCK_DIR" 2>/dev/null || true
      if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_PID_FILE" 2>/dev/null || true
        return 0
      fi
    fi
  fi

  print_error "检测到另一个实例正在运行，请稍后再试。"
  exit 1
}

release_lock() {
  rm -f "$LOCK_PID_FILE" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

# ---------- 校验 ----------
is_private_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^10\. ]] && return 0
  [[ "$ip" =~ ^192\.168\. ]] && return 0
  [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  return 1
}

is_valid_ipv4() {
  local ip="$1" o1 o2 o3 o4
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    [[ "$o" -ge 0 && "$o" -le 255 ]] || return 1
  done
  return 0
}

is_valid_cidr_prefix() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 0 && "$p" -le 32 ]]
}

is_valid_iface() {
  local iface="$1"
  [[ "$iface" =~ ^[a-zA-Z0-9_.:-]+$ ]]
}

get_field_after_token() {
  local text="$1" token="$2"
  awk -v t="$token" '{for(i=1;i<=NF;i++) if($i==t){print $(i+1); exit}}' <<< "$text"
}

# ---------- 状态读取与保存（安全解析，不 source） ----------
save_state() {
  local tmp_file="${STATE_FILE}.tmp.$$"

  # 仅允许单行值，避免破坏 key=value 结构
  case "$IFACE$PUBLIC_GW$PUBLIC_IP$PUBLIC_CIDR$PRIVATE_IP$PRIVATE_CIDR" in
    *$'\n'*|*$'\r'*|'='*)
      return 1
      ;;
  esac

  {
    printf 'IFACE=%s\n' "$IFACE"
    printf 'PUBLIC_GW=%s\n' "$PUBLIC_GW"
    printf 'PUBLIC_IP=%s\n' "$PUBLIC_IP"
    printf 'PUBLIC_CIDR=%s\n' "$PUBLIC_CIDR"
    printf 'PRIVATE_IP=%s\n' "$PRIVATE_IP"
    printf 'PRIVATE_CIDR=%s\n' "$PRIVATE_CIDR"
  } > "$tmp_file" || { rm -f "$tmp_file"; return 1; }

  chmod 600 "$tmp_file" || { rm -f "$tmp_file"; return 1; }
  mv -f "$tmp_file" "$STATE_FILE" || { rm -f "$tmp_file"; return 1; }
}

load_state_safely() {
  [[ -f "$STATE_FILE" ]] || return 1

  IFACE=""
  PUBLIC_GW=""
  PUBLIC_IP=""
  PUBLIC_CIDR=""
  PRIVATE_IP=""
  PRIVATE_CIDR=""

  local key value
  while IFS='=' read -r key value; do
    [[ -z "$key" ]] && continue
    [[ "$key" == \#* ]] && continue
    case "$key" in
      IFACE|PUBLIC_GW|PUBLIC_IP|PUBLIC_CIDR|PRIVATE_IP|PRIVATE_CIDR)
        printf -v "$key" '%s' "$value"
        ;;
      *) ;;
    esac
  done < "$STATE_FILE"

  is_valid_iface "$IFACE" || return 1
  is_valid_ipv4 "$PUBLIC_GW" || return 1
  is_valid_ipv4 "$PUBLIC_IP" || return 1
  is_valid_ipv4 "$PRIVATE_IP" || return 1
  is_valid_cidr_prefix "$PUBLIC_CIDR" || return 1
  is_valid_cidr_prefix "$PRIVATE_CIDR" || return 1
  return 0
}

# ---------- 环境检测 ----------
detect_env() {
  local default_line
  default_line="$(ip -4 route show default 2>/dev/null | awk 'NR==1')"
  [[ -n "$default_line" ]] || return 1

  IFACE="$(get_field_after_token "$default_line" "dev")"
  PUBLIC_GW="$(get_field_after_token "$default_line" "via")"
  PUBLIC_IP=""
  PUBLIC_CIDR=""
  PRIVATE_IP=""
  PRIVATE_CIDR=""

  local preferred_src
  preferred_src="$(get_field_after_token "$(ip -4 route get "$PROBE_TARGET" 2>/dev/null | awk 'NR==1')" "src")"

  [[ -n "$IFACE" ]] || return 1

  local linebuf cidr ip prefix
  while read -r linebuf; do
    cidr="$(awk '{print $4}' <<< "$linebuf")"
    ip="${cidr%/*}"
    prefix="${cidr#*/}"

    is_valid_ipv4 "$ip" || continue
    is_valid_cidr_prefix "$prefix" || continue

    if [[ -n "$preferred_src" ]] && [[ "$ip" == "$preferred_src" ]] && ! is_private_ipv4 "$ip"; then
      PUBLIC_IP="$ip"
      PUBLIC_CIDR="$prefix"
      continue
    fi

    if is_private_ipv4 "$ip"; then
      if [[ -z "$PRIVATE_IP" ]]; then
        PRIVATE_IP="$ip"
        PRIVATE_CIDR="$prefix"
      fi
    else
      if [[ -z "$PUBLIC_IP" ]]; then
        PUBLIC_IP="$ip"
        PUBLIC_CIDR="$prefix"
      fi
    fi
  done < <(ip -o -4 addr show dev "$IFACE" scope global 2>/dev/null)

  is_valid_iface "$IFACE" || return 1
  is_valid_ipv4 "$PUBLIC_GW" || return 1
  is_valid_ipv4 "$PUBLIC_IP" || return 1
  is_valid_ipv4 "$PRIVATE_IP" || return 1
  is_valid_cidr_prefix "$PUBLIC_CIDR" || return 1
  is_valid_cidr_prefix "$PRIVATE_CIDR" || return 1
  return 0
}

load_state_or_detect() {
  if load_state_safely; then
    return 0
  fi
  detect_env || return 1
  save_state || return 1
  return 0
}

refresh_state() {
  detect_env || return 1
  save_state || return 1
}

# ---------- 路由策略 ----------
flush_route_cache() {
  ip route flush cache >/dev/null 2>&1 || true
}

snapshot_default_route() {
  local line
  line="$(ip -4 route show default 2>/dev/null | awk 'NR==1')"
  [[ -n "$line" ]] || return 1

  ORIG_DEFAULT_VIA="$(get_field_after_token "$line" "via")"
  ORIG_DEFAULT_DEV="$(get_field_after_token "$line" "dev")"
  ORIG_DEFAULT_SRC="$(get_field_after_token "$line" "src")"

  is_valid_ipv4 "$ORIG_DEFAULT_VIA" || return 1
  is_valid_iface "$ORIG_DEFAULT_DEV" || return 1
  if [[ -n "$ORIG_DEFAULT_SRC" ]]; then
    is_valid_ipv4 "$ORIG_DEFAULT_SRC" || ORIG_DEFAULT_SRC=""
  fi
  return 0
}

restore_default_route_snapshot() {
  is_valid_ipv4 "$ORIG_DEFAULT_VIA" || return 1
  is_valid_iface "$ORIG_DEFAULT_DEV" || return 1

  if [[ -n "$ORIG_DEFAULT_SRC" ]]; then
    is_valid_ipv4 "$ORIG_DEFAULT_SRC" || ORIG_DEFAULT_SRC=""
  fi

  if [[ -n "$ORIG_DEFAULT_SRC" ]]; then
    ip route replace default via "$ORIG_DEFAULT_VIA" dev "$ORIG_DEFAULT_DEV" src "$ORIG_DEFAULT_SRC"
  else
    ip route replace default via "$ORIG_DEFAULT_VIA" dev "$ORIG_DEFAULT_DEV"
  fi
}

clean_policy_only() {
  while ip rule del pref "$RULE_PREF_PRIVATE" >/dev/null 2>&1; do :; done
  while ip rule del pref "$RULE_PREF_PUBLIC" >/dev/null 2>&1; do :; done
  ip route flush table "$TABLE_PRIVATE" >/dev/null 2>&1 || true
  ip route flush table "$TABLE_PUBLIC" >/dev/null 2>&1 || true
  flush_route_cache
}

apply_policy_private() {
  ip route replace default via "$PUBLIC_GW" dev "$IFACE" src "$PRIVATE_IP" || return 1
  ip route replace default via "$PUBLIC_GW" dev "$IFACE" src "$PRIVATE_IP" table "$TABLE_PRIVATE" || return 1
  ip route replace default via "$PUBLIC_GW" dev "$IFACE" src "$PUBLIC_IP" table "$TABLE_PUBLIC" || return 1
  ip rule add pref "$RULE_PREF_PRIVATE" from "$PRIVATE_IP/32" table "$TABLE_PRIVATE" || return 1
  ip rule add pref "$RULE_PREF_PUBLIC" from "$PUBLIC_IP/32" table "$TABLE_PUBLIC" || return 1
  flush_route_cache
  return 0
}

apply_private_as_default_src() {
  refresh_state || { set_last_result "error" "自动识别失败，无法应用"; return 1; }

  print_info "正在应用：默认新连接优先使用 ${PRIVATE_IP} 出站"
  print_info "下一跳保持：${PUBLIC_GW}"

  if ! snapshot_default_route; then
    print_warn "未能完整记录当前默认路由快照，失败时可能无法自动恢复原始 src"
  fi

  clean_policy_only
  if apply_policy_private; then
    set_last_result "success" "应用完成"
    return 0
  fi

  if restore_default_route_snapshot; then
    flush_route_cache
    set_last_result "error" "应用失败：已自动回滚到原默认路由"
  else
    set_last_result "error" "应用失败：策略已清理，但默认路由回滚失败，请手动检查"
  fi
  clean_policy_only
  return 1
}

rollback_public_as_default_src() {
  refresh_state || { set_last_result "error" "自动识别失败，无法回滚"; return 1; }

  print_info "正在恢复：默认新连接优先使用 ${PUBLIC_IP} 出站"

  clean_policy_only
  if ip route replace default via "$PUBLIC_GW" dev "$IFACE" src "$PUBLIC_IP"; then
    flush_route_cache
    set_last_result "success" "已恢复为公网 IP 默认出站"
    return 0
  fi

  set_last_result "error" "回滚失败：默认路由设置失败"
  return 1
}

current_mode() {
  local line default_line default_src
  line="$(ip -4 route get "$PROBE_TARGET" 2>/dev/null | awk 'NR==1')"
  default_line="$(ip -4 route show default 2>/dev/null | awk 'NR==1')"
  default_src="$(get_field_after_token "$default_line" "src")"

  if [[ -n "${PRIVATE_IP:-}" ]] && { grep -Eq "src ${PRIVATE_IP}( |$)" <<< "$line" || [[ "$default_src" == "$PRIVATE_IP" ]]; }; then
    echo "${PRIVATE_IP}(内网)"
  elif [[ -n "${PUBLIC_IP:-}" ]] && { grep -Eq "src ${PUBLIC_IP}( |$)" <<< "$line" || [[ "$default_src" == "$PUBLIC_IP" ]]; }; then
    echo "${PUBLIC_IP}(公网)"
  else
    echo "未识别"
  fi
}

check_route_manager_conflict() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-enabled NetworkManager >/dev/null 2>&1 || systemctl is-active NetworkManager >/dev/null 2>&1; then
      print_warn "检测到 NetworkManager 运行中，路由可能被其重写。"
    fi
    if systemctl is-enabled systemd-networkd >/dev/null 2>&1 || systemctl is-active systemd-networkd >/dev/null 2>&1; then
      print_warn "检测到 systemd-networkd 运行中，请确认无冲突路由策略。"
    fi
  fi
}

# ---------- 展示 ----------
show_summary() {
  if ! load_state_or_detect; then
    print_warn "自动识别失败，请检查默认路由、网卡与 IP 配置。"
    return 1
  fi

  print_section "当前环境"
  kv "网卡名称" "$IFACE"
  kv "公网IP" "$PUBLIC_IP"
  kv "内网IP" "$PRIVATE_IP"
  kv "公网网关" "$PUBLIC_GW"
  kv "当前模式" "$(current_mode)"
}

show_route_status() {
  if ! load_state_or_detect; then
    print_warn "自动识别失败"
    return 1
  fi

  print_section "当前详细状态"
  kv "网卡名称" "$IFACE"
  kv "公网IP" "$PUBLIC_IP/$PUBLIC_CIDR"
  kv "内网IP" "$PRIVATE_IP/$PRIVATE_CIDR"
  kv "公网网关" "$PUBLIC_GW"
  kv "当前模式" "$(current_mode)"
  echo

  echo -e "${CYAN}主默认路由${NC}"
  ip route show default | sed 's/^/  /'
  echo

  echo -e "${CYAN}策略规则${NC}"
  ip rule | sed 's/^/  /'
  echo

  echo -e "${CYAN}表${TABLE_PRIVATE}（内网IP源）${NC}"
  ip route show table "$TABLE_PRIVATE" 2>/dev/null | sed 's/^/  /'
  echo

  echo -e "${CYAN}表${TABLE_PUBLIC}（公网IP源）${NC}"
  ip route show table "$TABLE_PUBLIC" 2>/dev/null | sed 's/^/  /'
  echo
}

test_now() {
  if ! load_state_or_detect; then
    print_warn "自动识别失败"
    return 1
  fi

  print_section "测试当前出站效果"
  echo -e "${CYAN}默认新连接选路${NC}"
  ip route get "$PROBE_TARGET" | sed 's/^/  /'
  echo

  echo -e "${CYAN}从内网IP出站选路${NC}"
  ip route get "$PROBE_TARGET" from "$PRIVATE_IP" | sed 's/^/  /'
  echo

  echo -e "${CYAN}从公网IP出站选路${NC}"
  ip route get "$PROBE_TARGET" from "$PUBLIC_IP" | sed 's/^/  /'
  echo

  if command -v ping >/dev/null 2>&1; then
    echo -e "${CYAN}Ping（绑定内网IP）${NC}"
    ping -I "$PRIVATE_IP" -c 3 "$PROBE_TARGET" || true
    echo
  fi

  if command -v curl >/dev/null 2>&1; then
    echo -e "${CYAN}公网IP查询（绑定内网IP）${NC}"
    curl -4 --interface "$PRIVATE_IP" --connect-timeout 5 --max-time 10 https://api.ipify.org; echo
    echo

    echo -e "${CYAN}公网IP查询（默认新连接）${NC}"
    curl -4 --connect-timeout 5 --max-time 10 https://api.ipify.org; echo
    echo
  fi
}

# ---------- 自启动 ----------
install_apply_bin() {
  cat > "$APPLY_BIN" <<'EOF_APPLY'
#!/usr/bin/env bash
set -e
set -u
set -o pipefail

STATE_FILE="/var/lib/default-src-ip/state.env"
RULE_PREF_PRIVATE=100
RULE_PREF_PUBLIC=110
TABLE_PRIVATE=100
TABLE_PUBLIC=200

is_valid_ipv4() {
  local ip="$1" o1 o2 o3 o4
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    [[ "$o" -ge 0 && "$o" -le 255 ]] || return 1
  done
  return 0
}

is_valid_iface() {
  [[ "$1" =~ ^[a-zA-Z0-9_.:-]+$ ]]
}

load_state() {
  [[ -f "$STATE_FILE" ]] || return 1
  local key value
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    case "$key" in
      IFACE|PUBLIC_GW|PUBLIC_IP|PRIVATE_IP) printf -v "$key" '%s' "$value" ;;
      *) ;;
    esac
  done < "$STATE_FILE"

  is_valid_iface "${IFACE:-}" || return 1
  is_valid_ipv4 "${PUBLIC_GW:-}" || return 1
  is_valid_ipv4 "${PUBLIC_IP:-}" || return 1
  is_valid_ipv4 "${PRIVATE_IP:-}" || return 1
  return 0
}

load_state || exit 1

while ip rule del pref "$RULE_PREF_PRIVATE" >/dev/null 2>&1; do :; done
while ip rule del pref "$RULE_PREF_PUBLIC" >/dev/null 2>&1; do :; done
ip route flush table "$TABLE_PRIVATE" >/dev/null 2>&1 || true
ip route flush table "$TABLE_PUBLIC" >/dev/null 2>&1 || true

ip route replace default via "$PUBLIC_GW" dev "$IFACE" src "$PRIVATE_IP"
ip route replace default via "$PUBLIC_GW" dev "$IFACE" src "$PRIVATE_IP" table "$TABLE_PRIVATE"
ip route replace default via "$PUBLIC_GW" dev "$IFACE" src "$PUBLIC_IP" table "$TABLE_PUBLIC"

ip rule add pref "$RULE_PREF_PRIVATE" from "$PRIVATE_IP/32" table "$TABLE_PRIVATE"
ip rule add pref "$RULE_PREF_PUBLIC" from "$PUBLIC_IP/32" table "$TABLE_PUBLIC"

ip route flush cache >/dev/null 2>&1 || true
EOF_APPLY

  chmod 700 "$APPLY_BIN"
}

install_sysctl() {
  cat > "$SYSCTL_FILE" <<'EOF_SYSCTL'
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
EOF_SYSCTL
  chmod 644 "$SYSCTL_FILE"
  sysctl --system >/dev/null 2>&1 || true
}

install_service() {
  refresh_state || {
    set_last_result "error" "自动识别失败，无法安装开机自启"
    return 1
  }

  install_apply_bin || { set_last_result "error" "写入应用脚本失败"; return 1; }
  install_sysctl

  cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Use private IP as default source for outbound traffic
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${APPLY_BIN}

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  if systemctl daemon-reload && systemctl enable --now "$SERVICE_NAME"; then
    set_last_result "success" "已安装开机自动应用"
    return 0
  fi

  set_last_result "error" "开机自动应用安装失败"
  return 1
}

remove_service() {
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$APPLY_BIN" "$SYSCTL_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  sysctl --system >/dev/null 2>&1 || true
  set_last_result "success" "已移除开机自动应用"
}

full_uninstall() {
  local confirm
  confirm=$(read_confirm_yn_default "确认卸载并恢复默认路由？[Y/N]（默认: N）: " "N")
  [[ "$confirm" == "N" ]] && { set_last_result "warn" "已取消卸载"; return 0; }

  remove_service
  rollback_public_as_default_src || true
  rm -f "$STATE_FILE"
  set_last_result "success" "卸载完成"
}

# ---------- 菜单 ----------
show_menu() {
  print_banner
  show_last_result
  show_summary || true

  print_section "功能菜单"
  echo -e "  ${GREEN}1)${NC} 重新自动识别环境"
  echo -e "  ${GREEN}2)${NC} 应用内网IP默认出站"
  echo -e "  ${GREEN}3)${NC} 测试当前出站效果"
  echo -e "  ${GREEN}4)${NC} 查看当前详细状态"
  echo -e "  ${GREEN}5)${NC} 回滚为公网IP默认出站"
  echo -e "  ${GREEN}6)${NC} 安装开机自动应用"
  echo -e "  ${GREEN}7)${NC} 移除开机自动应用"
  echo -e "  ${GREEN}8)${NC} 仅清理策略规则"
  echo -e "  ${RED}9)${NC} 卸载并恢复默认"
  echo -e "  ${NC}0)${NC} 退出"
  echo
}

menu_loop() {
  local choice
  while true; do
    show_menu
    choice=$(read_menu_choice "请输入编号 [0-9]: " '^[0-9]$')
    echo
    case "$choice" in
      1)
        if refresh_state; then
          set_last_result "success" "自动识别完成"
        else
          set_last_result "error" "自动识别失败"
        fi
        pause
        ;;
      2)
        apply_private_as_default_src
        show_route_status || true
        pause
        ;;
      3)
        test_now
        pause
        ;;
      4)
        show_route_status
        pause
        ;;
      5)
        rollback_public_as_default_src
        show_route_status || true
        pause
        ;;
      6)
        install_service
        if [[ "$LAST_RESULT_TYPE" == "success" ]]; then
          systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null || true
        fi
        pause
        ;;
      7)
        remove_service
        pause
        ;;
      8)
        clean_policy_only
        set_last_result "success" "策略规则已清理"
        pause
        ;;
      9)
        full_uninstall
        pause
        ;;
      0)
        echo
        print_info "已退出"
        exit 0
        ;;
    esac
  done
}

usage() {
  cat <<'EOF_USAGE'
用法:
  hkt.sh                 进入交互菜单
  hkt.sh --apply         应用内网IP默认出站
  hkt.sh --rollback      回滚为公网IP默认出站
  hkt.sh --status        查看当前详细状态
  hkt.sh --refresh       重新自动识别环境
  hkt.sh --clean         仅清理策略规则
  hkt.sh --install-service   安装开机自动应用
  hkt.sh --remove-service    移除开机自动应用
  hkt.sh --uninstall     卸载并恢复默认（含确认）
  hkt.sh --help          显示帮助
EOF_USAGE
}

run_non_interactive() {
  case "${1:-}" in
    --apply)
      apply_private_as_default_src
      show_last_result
      ;;
    --rollback)
      rollback_public_as_default_src
      show_last_result
      ;;
    --status)
      show_route_status
      ;;
    --refresh)
      if refresh_state; then set_last_result "success" "自动识别完成"; else set_last_result "error" "自动识别失败"; fi
      show_last_result
      ;;
    --clean)
      clean_policy_only
      set_last_result "success" "策略规则已清理"
      show_last_result
      ;;
    --install-service)
      install_service
      show_last_result
      ;;
    --remove-service)
      remove_service
      show_last_result
      ;;
    --uninstall)
      full_uninstall
      show_last_result
      ;;
    --help)
      usage
      ;;
    "")
      menu_loop
      ;;
    *)
      print_error "未知参数: $1"
      usage
      return 1
      ;;
  esac
}

main() {
  require_root
  check_dependencies
  init_runtime
  check_route_manager_conflict
  acquire_lock
  trap release_lock EXIT INT TERM HUP
  run_non_interactive "${1:-}"
}

main "$@"
