#!/usr/bin/env bash
set -euo pipefail

# =========================
# 远程安装来源（用于 curl|bash 场景下“安装/更新”把脚本落地）
# 若你已放到 GitHub，请改成你自己的：
GITHUB_RAW_URL_DEFAULT="https://raw.githubusercontent.com/<YOU>/<REPO>/main/tc-port-limit.sh"
# 也可运行时覆盖：TCPL_SCRIPT_URL="..." bash tc-port-limit.sh
# =========================

APP="tc-port-limit"
CONF_DIR="/etc/tc-port-limit"
CONF_FILE="${CONF_DIR}/rules.conf"
IFB_DEV="ifb0"
STATE_DIR="/run/tc-port-limit"

# root class rate 给个很大值，避免成为瓶颈（只限特定端口）
ROOT_RATE="10000mbit"

SERVICE_NAME="tc-port-limit.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
INSTALL_PATH="/usr/local/sbin/tc-port-limit"

# -------------------------
# 基础工具
# -------------------------
is_root() { [[ "${EUID}" -eq 0 ]]; }

need_root() {
  if ! is_root; then
    echo "ERROR: 请使用 root 运行（sudo）"
    exit 1
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_dirs() {
  mkdir -p "${CONF_DIR}" "${STATE_DIR}"
  touch "${CONF_FILE}"
}

apt_install_if_missing() {
  local pkg="$1"
  dpkg -s "${pkg}" >/dev/null 2>&1 && return 0
  apt-get update -y
  apt-get install -y "${pkg}"
}

ensure_deps() {
  if ! cmd_exists apt-get; then
    echo "ERROR: 未找到 apt-get（该脚本面向 Debian/Ubuntu 系）"
    exit 1
  fi

  # tc/ip 都在 iproute2
  if ! cmd_exists tc || ! cmd_exists ip; then
    echo "[*] 安装依赖：iproute2 ..."
    apt_install_if_missing iproute2
  fi

  if ! cmd_exists curl; then
    echo "[*] 安装依赖：curl ..."
    apt_install_if_missing curl
  fi

  # 可选：更美观的交互 UI
  if ! cmd_exists whiptail; then
    # 不强制安装，纯文本 UI 也可以
    true
  fi

  ensure_dirs
}

detect_iface() {
  # 默认路由网卡优先
  local dev
  dev="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
  if [[ -n "${dev}" ]]; then
    echo "${dev}"
    return
  fi
  # 兜底：第一个 UP 的非 lo/ifb
  dev="$(ip -o link show up | awk -F': ' '{print $2}' | grep -Ev '^(lo|ifb[0-9]+)$' | head -n1 || true)"
  if [[ -n "${dev}" ]]; then
    echo "${dev}"
    return
  fi
  echo "ERROR: 无法检测到可用网卡"
  exit 1
}

validate_port() {
  local p="$1"
  [[ "${p}" =~ ^[0-9]+$ ]] || { echo "ERROR: 端口必须是数字：${p}"; exit 1; }
  (( p>=1 && p<=65535 )) || { echo "ERROR: 端口范围 1-65535：${p}"; exit 1; }
}

normalize_rate() {
  local r="$1"
  # 纯数字默认 mbit
  if [[ "${r}" =~ ^[0-9]+$ ]]; then
    echo "${r}mbit"
    return
  fi
  if [[ "${r}" =~ ^[0-9]+(kbit|mbit|gbit)$ ]]; then
    echo "${r}"
    return
  fi
  echo "ERROR: 非法速率：${r}（示例：10 / 10mbit / 500kbit / 1gbit）"
  exit 1
}

# -------------------------
# TC 逻辑
# -------------------------
ensure_ifb_redirect() {
  local dev="$1"

  modprobe ifb >/dev/null 2>&1 || true

  if ! ip link show "${IFB_DEV}" >/dev/null 2>&1; then
    ip link add "${IFB_DEV}" type ifb
  fi
  ip link set "${IFB_DEV}" up

  # ingress qdisc on dev
  if ! tc qdisc show dev "${dev}" | grep -q "ingress ffff:"; then
    tc qdisc add dev "${dev}" handle ffff: ingress
  fi

  # 清理旧 ingress filter，避免叠加
  tc filter del dev "${dev}" parent ffff: 2>/dev/null || true
  tc filter add dev "${dev}" parent ffff: protocol ip u32 match u32 0 0 \
    action mirred egress redirect dev "${IFB_DEV}"
}

clear_all() {
  local dev="$1"
  tc qdisc del dev "${dev}" root 2>/dev/null || true
  tc qdisc del dev "${dev}" ingress 2>/dev/null || true
  tc qdisc del dev "${IFB_DEV}" root 2>/dev/null || true
  ip link del "${IFB_DEV}" 2>/dev/null || true
}

setup_base() {
  local dev="$1"

  # egress
  tc qdisc add dev "${dev}" root handle 1: htb default 30
  tc class add dev "${dev}" parent 1: classid 1:1 htb rate "${ROOT_RATE}"
  tc class add dev "${dev}" parent 1:1 classid 1:30 htb rate "${ROOT_RATE}" ceil "${ROOT_RATE}"

  # ingress via ifb
  ensure_ifb_redirect "${dev}"

  tc qdisc add dev "${IFB_DEV}" root handle 2: htb default 30
  tc class add dev "${IFB_DEV}" parent 2: classid 2:1 htb rate "${ROOT_RATE}"
  tc class add dev "${IFB_DEV}" parent 2:1 classid 2:30 htb rate "${ROOT_RATE}" ceil "${ROOT_RATE}"
}

apply_rules() {
  local dev="$1"

  clear_all "${dev}"
  setup_base "${dev}"

  local idx=0
  while read -r line; do
    [[ -z "${line// /}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue

    # line: port up [down]
    # shellcheck disable=SC2206
    local parts=( ${line} )
    local port="${parts[0]:-}"
    local up="${parts[1]:-}"
    local down="${parts[2]:-}"

    [[ -n "${port}" && -n "${up}" ]] || { echo "WARN: 跳过无效行：${line}"; continue; }
    validate_port "${port}"
    up="$(normalize_rate "${up}")"
    if [[ -z "${down}" ]]; then
      down="${up}"
    else
      down="$(normalize_rate "${down}")"
    fi

    idx=$((idx+1))
    local minor=$((10 + idx))  # 1:11.. 2:11..
    if (( minor > 4095 )); then
      echo "ERROR: 规则太多（minor 超界）"
      exit 1
    fi

    # egress: sport port（服务端对外发送时源端口是服务端口）
    tc class add dev "${dev}" parent 1:1 classid 1:"${minor}" htb rate "${up}" ceil "${up}"
    tc filter add dev "${dev}" protocol ip parent 1: prio 1 u32 \
      match ip sport "${port}" 0xffff flowid 1:"${minor}"

    # ingress via ifb: dport port（客户端访问该服务端口）
    tc class add dev "${IFB_DEV}" parent 2:1 classid 2:"${minor}" htb rate "${down}" ceil "${down}"
    tc filter add dev "${IFB_DEV}" protocol ip parent 2: prio 1 u32 \
      match ip dport "${port}" 0xffff flowid 2:"${minor}"

  done < "${CONF_FILE}"

  echo "[OK] 已应用规则（dev=${dev}）"
}

list_rules() {
  if [[ ! -s "${CONF_FILE}" ]]; then
    echo "(empty) ${CONF_FILE}"
    return 0
  fi
  echo "当前规则（port up [down]）："
  nl -ba "${CONF_FILE}"
}

remove_rule_port() {
  local port="$1"
  validate_port "${port}"

  local tmp
  tmp="$(mktemp)"
  awk -v p="${port}" '
    { if ($1==p) next; print }
  ' "${CONF_FILE}" > "${tmp}"
  mv "${tmp}" "${CONF_FILE}"
}

add_rule_port() {
  local port="$1" up="$2" down="${3:-}"
  validate_port "${port}"
  up="$(normalize_rate "${up}")"
  if [[ -n "${down}" ]]; then down="$(normalize_rate "${down}")"; fi

  # 去重：先删再加
  remove_rule_port "${port}" 2>/dev/null || true
  if [[ -z "${down}" ]]; then
    echo "${port} ${up}" >> "${CONF_FILE}"
  else
    echo "${port} ${up} ${down}" >> "${CONF_FILE}"
  fi
}

# -------------------------
# systemd
# -------------------------
write_service() {
  cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=TC port-based bandwidth limiter (egress+ingress via ifb)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${INSTALL_PATH} apply
ExecStop=${INSTALL_PATH} clear
ExecReload=${INSTALL_PATH} apply

[Install]
WantedBy=multi-user.target
EOF
}

install_or_update() {
  need_root
  ensure_deps

  # 1) 落地脚本
  # - 如果当前是文件运行：直接复制自身
  # - 如果是 curl|bash：用 TCPL_SCRIPT_URL 或默认 GitHub URL 再拉一次写入 INSTALL_PATH
  if [[ -f "${0}" && "${0}" != "bash" && "${0}" != "/bin/bash" && "${0}" != "/usr/bin/bash" ]]; then
    install -m 755 "${0}" "${INSTALL_PATH}"
  else
    local url="${TCPL_SCRIPT_URL:-${GITHUB_RAW_URL_DEFAULT}}"
    if [[ "${url}" == *"<YOU>"* || "${url}" == *"<REPO>"* ]]; then
      echo "ERROR: 你正在通过管道运行，且尚未设置脚本来源 URL。"
      echo "请先把脚本上传到 GitHub，并修改脚本顶部的 GITHUB_RAW_URL_DEFAULT，或临时指定："
      echo "  sudo TCPL_SCRIPT_URL='https://raw.githubusercontent.com/你/仓库/分支/tc-port-limit.sh' bash -c 'curl -fsSL ... | bash'"
      exit 1
    fi
    curl -fsSL "${url}" -o "${INSTALL_PATH}"
    chmod +x "${INSTALL_PATH}"
  fi

  # 2) 配置目录
  ensure_dirs

  # 3) systemd service
  write_service
  systemctl daemon-reload

  echo "[OK] 已安装/更新：${INSTALL_PATH}"
  echo "[OK] 已安装 systemd：${SERVICE_NAME}"
}

uninstall_all() {
  need_root
  ensure_deps

  systemctl stop tc-port-limit 2>/dev/null || true
  systemctl disable tc-port-limit 2>/dev/null || true

  # 清 TC
  local dev
  dev="$(detect_iface)"
  clear_all "${dev}" || true

  rm -f "${SERVICE_PATH}"
  rm -f "${INSTALL_PATH}"
  systemctl daemon-reload

  # 是否删除配置
  if cmd_exists whiptail; then
    if whiptail --title "${APP}" --yesno "是否删除配置目录 ${CONF_DIR}（含 rules.conf）？" 10 60; then
      rm -rf "${CONF_DIR}"
    fi
  else
    echo -n "是否删除配置目录 ${CONF_DIR}（含 rules.conf）？[y/N]: "
    read -r ans
    if [[ "${ans}" =~ ^[Yy]$ ]]; then
      rm -rf "${CONF_DIR}"
    fi
  fi

  echo "[OK] 已卸载完成"
}

svc_start() { systemctl start tc-port-limit; }
svc_stop() { systemctl stop tc-port-limit; }
svc_restart() { systemctl restart tc-port-limit; }
svc_status() { systemctl status tc-port-limit --no-pager; }
svc_enable_now() { systemctl enable --now tc-port-limit; }
svc_disable() { systemctl disable tc-port-limit; }

# -------------------------
# 交互 UI
# -------------------------
prompt_text() {
  local msg="$1" default="${2:-}"
  local out=""
  if cmd_exists whiptail; then
    out="$(whiptail --title "${APP}" --inputbox "${msg}" 10 70 "${default}" 3>&1 1>&2 2>&3 || true)"
  else
    if [[ -n "${default}" ]]; then
      echo -n "${msg} [默认: ${default}]: "
    else
      echo -n "${msg}: "
    fi
    read -r out || true
    [[ -z "${out}" ]] && out="${default}"
  fi
  echo "${out}"
}

msg_box() {
  local msg="$1"
  if cmd_exists whiptail; then
    whiptail --title "${APP}" --msgbox "${msg}" 12 70
  else
    echo -e "\n${msg}\n"
  fi
}

confirm_box() {
  local msg="$1"
  if cmd_exists whiptail; then
    whiptail --title "${APP}" --yesno "${msg}" 10 70
    return $?
  else
    echo -n "${msg} [y/N]: "
    local ans
    read -r ans || true
    [[ "${ans}" =~ ^[Yy]$ ]]
    return $?
  fi
}

ui_add_rules() {
  need_root
  ensure_deps

  local ports up down
  ports="$(prompt_text "请输入要限速的端口（支持多个，逗号分隔，如 443,8443）" "443")"
  up="$(prompt_text "请输入上行限速（如 10mbit / 500kbit / 1gbit；只写数字默认 mbit）" "20mbit")"
  down="$(prompt_text "请输入下行限速（留空=与上行相同）" "")"

  [[ -n "${ports// /}" ]] || { msg_box "未输入端口。"; return 0; }
  [[ -n "${up// /}" ]] || { msg_box "未输入上行速率。"; return 0; }

  # 处理多个端口
  IFS=',' read -r -a arr <<< "${ports}"
  for p in "${arr[@]}"; do
    p="${p// /}"
    [[ -z "${p}" ]] && continue
    add_rule_port "${p}" "${up}" "${down}"
  done

  msg_box "已写入规则。\n你可以选择【应用规则】立即生效，或通过 systemd 启动服务。"
}

ui_remove_rules() {
  need_root
  ensure_deps

  local ports
  ports="$(prompt_text "请输入要移除限速的端口（支持多个，逗号分隔）" "443")"
  [[ -n "${ports// /}" ]] || { msg_box "未输入端口。"; return 0; }

  IFS=',' read -r -a arr <<< "${ports}"
  for p in "${arr[@]}"; do
    p="${p// /}"
    [[ -z "${p}" ]] && continue
    remove_rule_port "${p}"
  done

  msg_box "已从规则文件移除。\n记得【应用规则】或 systemd 重启服务使其生效。"
}

ui_apply() {
  need_root
  ensure_deps
  local dev
  dev="$(detect_iface)"
  apply_rules "${dev}"
  msg_box "已应用规则到：${dev}"
}

ui_clear() {
  need_root
  ensure_deps
  local dev
  dev="$(detect_iface)"
  clear_all "${dev}"
  msg_box "已清除所有 tc 限速（dev=${dev}）"
}

ui_list() {
  ensure_deps
  local content
  content="$( (list_rules) 2>&1 || true )"
  msg_box "${content}"
}

ui_iface() {
  ensure_deps
  local dev
  dev="$(detect_iface)"
  msg_box "检测到默认网卡：${dev}"
}

ui_install() {
  need_root
  ensure_deps
  install_or_update
  msg_box "安装/更新完成。\n可用命令：${INSTALL_PATH}\n服务：systemctl enable --now tc-port-limit"
}

ui_uninstall() {
  if confirm_box "确认卸载 ${APP}（会停止服务并清除 tc 规则）？"; then
    uninstall_all
    msg_box "卸载完成。"
  fi
}

ui_service_menu() {
  need_root
  ensure_deps

  local choice=""
  if cmd_exists whiptail; then
    choice="$(whiptail --title "${APP} - systemd" --menu "选择操作" 18 70 10 \
      "1" "enable --now（开机自启并立即启动）" \
      "2" "start（启动）" \
      "3" "stop（停止）" \
      "4" "restart（重启）" \
      "5" "status（状态）" \
      "6" "disable（取消自启）" \
      "0" "返回" 3>&1 1>&2 2>&3 || true)"
  else
    echo "1) enable --now"
    echo "2) start"
    echo "3) stop"
    echo "4) restart"
    echo "5) status"
    echo "6) disable"
    echo "0) back"
    echo -n "选择: "
    read -r choice || true
  fi

  case "${choice}" in
    1) svc_enable_now; msg_box "已 enable --now";;
    2) svc_start; msg_box "已 start";;
    3) svc_stop; msg_box "已 stop";;
    4) svc_restart; msg_box "已 restart";;
    5) msg_box "$(svc_status 2>&1 || true)";;
    6) svc_disable; msg_box "已 disable";;
    *) true;;
  esac
}

ui_main() {
  need_root
  ensure_deps

  while true; do
    local choice=""
    if cmd_exists whiptail; then
      choice="$(whiptail --title "${APP}" --menu "TC 端口限速管理" 20 75 12 \
        "1" "安装/更新（写入 /usr/local/sbin + systemd）" \
        "2" "卸载（停止服务+清 tc+删文件）" \
        "3" "添加端口限速（支持多个端口）" \
        "4" "移除端口限速（支持多个端口）" \
        "5" "查看规则" \
        "6" "应用规则（立即生效）" \
        "7" "清除全部限速（tc clear）" \
        "8" "systemd 控制（start/stop/restart/enable）" \
        "9" "查看默认网卡" \
        "0" "退出" 3>&1 1>&2 2>&3 || true)"
    else
      echo
      echo "==== ${APP} ===="
      echo "1) 安装/更新"
      echo "2) 卸载"
      echo "3) 添加端口限速"
      echo "4) 移除端口限速"
      echo "5) 查看规则"
      echo "6) 应用规则"
      echo "7) 清除全部限速"
      echo "8) systemd 控制"
      echo "9) 查看默认网卡"
      echo "0) 退出"
      echo -n "选择: "
      read -r choice || true
    fi

    case "${choice}" in
      1) ui_install;;
      2) ui_uninstall;;
      3) ui_add_rules;;
      4) ui_remove_rules;;
      5) ui_list;;
      6) ui_apply;;
      7) ui_clear;;
      8) ui_service_menu;;
      9) ui_iface;;
      0|"") break;;
      *) msg_box "无效选择";;
    esac
  done
}

# -------------------------
# 非交互命令模式（可选）
# -------------------------
usage() {
  cat <<EOF
用法：
  ${0}            # 进入交互 UI
  ${0} ui         # 进入交互 UI
  ${0} install    # 安装/更新到 ${INSTALL_PATH} + systemd
  ${0} uninstall  # 卸载
  ${0} add 443 20mbit [down]    # 添加规则
  ${0} remove 443               # 移除规则
  ${0} list                     # 查看规则
  ${0} apply                    # 应用规则（立即生效）
  ${0} clear                    # 清除全部限速
EOF
}

main() {
  local cmd="${1:-ui}"
  shift || true

  case "${cmd}" in
    ui) ui_main;;
    install) install_or_update;;
    uninstall) uninstall_all;;
    add)
      need_root; ensure_deps
      [[ $# -ge 2 ]] || { usage; exit 1; }
      add_rule_port "$1" "$2" "${3:-}"
      ;;
    remove)
      need_root; ensure_deps
      [[ $# -ge 1 ]] || { usage; exit 1; }
      remove_rule_port "$1"
      ;;
    list) ensure_deps; list_rules;;
    apply)
      need_root; ensure_deps
      apply_rules "$(detect_iface)"
      ;;
    clear)
      need_root; ensure_deps
      clear_all "$(detect_iface)"
      ;;
    -h|--help|help) usage;;
    *) usage; exit 1;;
  esac
}

main "$@"
