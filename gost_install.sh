#!/usr/bin/env bash
set -euo pipefail

XRAYR_REPO="XrayR-project/XrayR"
BASE_DIR="/etc/XrayR"
VERSIONS_DIR="${BASE_DIR}/version"

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # 无颜色

# ===== 工具函数 =====
die() { echo -e "${RED}错误: $*${NC}" >&2; }
info() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
header() { echo -e "${BOLD}${CYAN}$*${NC}"; }

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { die "请以 root 用户运行此脚本。"; return 1; }; }

check_64bit() {
  [[ "$(getconf LONG_BIT 2>/dev/null || echo 0)" == "64" ]] || { die "仅支持 64 位系统。"; return 1; }
}

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf"; return; fi
  if command -v yum >/dev/null 2>&1; then echo "yum"; return; fi
  die "未找到支持的包管理器 (apt-get/dnf/yum)。"
  return 1
}

install_deps() {
  local pm="$1"
  case "$pm" in
    apt)
      apt-get update -y >/dev/null 2>&1 || apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget unzip ca-certificates systemd >/dev/null
      ;;
    dnf)
      dnf install -y curl wget unzip ca-certificates systemd >/dev/null
      ;;
    yum)
      yum install -y curl wget unzip ca-certificates systemd >/dev/null
      ;;
  esac
}

detect_arch() {
  local a
  a="$(uname -m)"
  case "$a" in
    x86_64|amd64) echo "64" ;;
    aarch64|arm64) echo "arm64-v8a" ;;
    s390x) echo "s390x" ;;
    *) die "不支持的架构: ${a}"; return 1 ;;
  esac
}

normalize_version_tag() {
  local v="${1:-}"
  [[ -z "$v" ]] && echo "" && return
  [[ "$v" == v* ]] && echo "$v" || echo "v${v}"
}

latest_version() {
  local v
  v="$(curl -fsSL "https://api.github.com/repos/${XRAYR_REPO}/releases/latest" \
      | grep -m1 '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)"
  [[ -n "$v" ]] || { die "从 GitHub API 获取最新版本失败。"; return 1; }
  echo "$v"
}

instance_dir() { echo "${VERSIONS_DIR}/$1"; }
service_name() { echo "XrayR-$1.service"; }

# ===== 绘制辅助函数 =====
draw_line() {
  local char="${1:--}"
  local len="${2:-56}"
  printf '%*s\n' "$len" '' | tr ' ' "$char"
}

draw_box_header() {
  local title="$1"
  echo ""
  echo -e "${CYAN}"
  draw_line "═" 56
  printf "║  %-52s║\n" "$title"
  draw_line "═" 56
  echo -e "${NC}"
}

draw_menu_item() {
  local num="$1"
  local text="$2"
  echo -e "  ${BOLD}${YELLOW}${num})${NC}  ${text}"
}

press_any_key() {
  echo ""
  echo -e "${YELLOW}按 Enter 键返回主菜单...${NC}"
  read -r
}

# ===== 核心功能 =====
create_service_unit() {
  local name="$1"
  local dir="$2"
  local unit="/etc/systemd/system/$(service_name "$name")"

  cat > "$unit" <<EOF
[Unit]
Description=XrayR (${name})
After=network.target nss-lookup.target

[Service]
Type=simple
WorkingDirectory=${dir}
ExecStart=${dir}/XrayR --config ${dir}/config.yml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

install_instance() {
  local name="$1"
  local version_tag="$2"
  local arch="$3"
  local dir; dir="$(instance_dir "$name")"
  mkdir -p "$dir"

  local tmp=""
  tmp="$(mktemp -d)"
  trap '[[ -n "${tmp:-}" ]] && rm -rf "${tmp}"' EXIT

  local url="https://github.com/${XRAYR_REPO}/releases/download/${version_tag}/XrayR-linux-${arch}.zip"
  echo ""
  info "正在安装实例: ${name}"
  echo -e "  版本   : ${BOLD}${version_tag}${NC}"
  echo -e "  架构   : ${BOLD}${arch}${NC}"
  echo -e "  目录   : ${BOLD}${dir}${NC}"
  echo -e "  下载地址: ${url}"
  echo ""

  wget -q -O "${tmp}/xrayr.zip" "$url" || { die "下载失败，请检查版本号和 GitHub 连通性。"; return 1; }
  unzip -q -o "${tmp}/xrayr.zip" -d "${tmp}" || { die "解压失败。"; return 1; }
  [[ -f "${tmp}/XrayR" ]] || { die "压缩包中未找到 XrayR 可执行文件。"; return 1; }

  install -m 0755 "${tmp}/XrayR" "${dir}/XrayR"
  [[ -f "${tmp}/geoip.dat" ]]   && install -m 0644 "${tmp}/geoip.dat"   "${dir}/geoip.dat"
  [[ -f "${tmp}/geosite.dat" ]] && install -m 0644 "${tmp}/geosite.dat" "${dir}/geosite.dat"

  if [[ -f "${tmp}/config.yml" && ! -f "${dir}/config.yml" ]]; then
    install -m 0644 "${tmp}/config.yml" "${dir}/config.yml"
  fi
  for f in dns.json route.json custom_outbound.json custom_inbound.json rulelist; do
    [[ -f "${tmp}/${f}" && ! -f "${dir}/${f}" ]] && install -m 0644 "${tmp}/${f}" "${dir}/${f}"
  done

  echo "${version_tag}" > "${dir}/.installed_version"

  create_service_unit "$name" "$dir"
  systemctl enable "$(service_name "$name")" >/dev/null
  systemctl restart "$(service_name "$name")" || true

  if systemctl is-active --quiet "$(service_name "$name")"; then
    info "✔ 服务已启动: $(service_name "$name")"
  else
    warn "⚠ 服务未能启动，请检查:"
    echo "  journalctl -u $(service_name "$name") -e --no-pager"
  fi

  rm -rf "${tmp}"
  tmp=""
}

list_instances() {
  mkdir -p "$VERSIONS_DIR"

  local names
  names="$(find "$VERSIONS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | LC_ALL=C sort || true)"
  if [[ -z "$names" ]]; then
    warn "在 ${VERSIONS_DIR} 中未找到任何实例"
    return 0
  fi

  echo ""
  printf "  ${BOLD}%-20s %-15s %-12s${NC}\n" "名称" "版本" "状态"
  draw_line "-" 52
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    local d="${VERSIONS_DIR}/${name}"
    local ver="未知"
    [[ -f "$d/.installed_version" ]] && ver="$(cat "$d/.installed_version" 2>/dev/null || echo 未知)"
    local svc; svc="$(service_name "$name")"
    local status
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      status="${GREEN}运行中${NC}"
    else
      status="${RED}已停止${NC}"
    fi
    printf "  %-20s %-15s " "$name" "$ver"
    echo -e "$status"
  done <<< "$names"
  echo ""
}

uninstall_instance_no_confirm() {
  local name="$1"
  [[ -n "$name" ]] || { die "卸载需要提供实例名称。"; return 1; }

  local dir; dir="$(instance_dir "$name")"
  [[ -d "$dir" ]] || { die "实例目录未找到: $dir"; return 1; }

  local svc; svc="$(service_name "$name")"

  systemctl stop "$svc" >/dev/null 2>&1 || true
  systemctl disable "$svc" >/dev/null 2>&1 || true

  rm -f "/etc/systemd/system/${svc}"
  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true

  rm -rf "$dir"
  info "✔ 已卸载 '${name}' (服务 + ${dir})"
}

# ===== 系统控制 =====
list_xrayr_units() {
  local units=""
  units="$(systemctl list-unit-files --no-legend 2>/dev/null \
          | awk '{print $1}' \
          | grep -E '^XrayR-.*\.service$' \
          | LC_ALL=C sort -u || true)"

  if [[ -z "$units" ]]; then
    units="$(find /etc/systemd/system -maxdepth 1 -type f -name 'XrayR-*.service' -printf '%f\n' 2>/dev/null \
            | LC_ALL=C sort -u || true)"
  fi

  echo "$units"
}

# ===== 交互式菜单 =====

ui_install() {
  draw_box_header "安装新实例"

  local name=""
  while true; do
    echo -ne "  ${BOLD}实例名称${NC} (例如 nodeA): "
    read -r name
    if [[ -z "$name" ]]; then
      die "名称不能为空，请重新输入。"
      continue
    fi
    if [[ ! "$name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      die "名称只能包含: [a-zA-Z0-9._-]，请重新输入。"
      continue
    fi
    break
  done

  echo -ne "  ${BOLD}版本号${NC} (留空则安装最新版): "
  read -r version_in

  echo ""
  echo -e "  ${BOLD}确认安装信息:${NC}"
  echo -e "    名称   : ${YELLOW}${name}${NC}"
  echo -e "    版本   : ${YELLOW}${version_in:-最新版}${NC}"
  echo ""
  echo -ne "  ${BOLD}确认安装? (y/n):${NC} "
  read -r confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    warn "安装已取消。"
    return
  fi

  echo ""
  info "正在准备安装..."

  local pm; pm="$(detect_pm)" || return
  install_deps "$pm"

  local arch; arch="$(detect_arch)" || return
  local tag; tag="$(normalize_version_tag "$version_in")"
  [[ -n "$tag" ]] || tag="$(latest_version)" || return

  install_instance "$name" "$tag" "$arch"
}

ui_list() {
  draw_box_header "已安装的实例"
  list_instances
}

ui_uninstall() {
  draw_box_header "卸载实例"

  mkdir -p "$VERSIONS_DIR"
  local names
  names="$(find "$VERSIONS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | LC_ALL=C sort || true)"

  if [[ -z "$names" ]]; then
    warn "未找到任何实例，无需卸载。"
    return
  fi

  echo "  可用实例列表:"
  echo ""

  local i=0
  local arr=()
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    i=$((i+1))
    local ver="未知"
    [[ -f "${VERSIONS_DIR}/${n}/.installed_version" ]] && ver="$(cat "${VERSIONS_DIR}/${n}/.installed_version" 2>/dev/null || echo 未知)"
    draw_menu_item "$i" "${n} (${ver})"
    arr+=("$n")
  done <<< "$names"

  echo ""
  echo -ne "  ${BOLD}请选择要卸载的实例编号 (输入 0 取消):${NC} "
  read -r idx

  if [[ "$idx" == "0" ]]; then
    warn "已取消。"
    return
  fi

  [[ "$idx" =~ ^[0-9]+$ ]] || { die "无效的选择。"; return; }
  [[ "$idx" -ge 1 && "$idx" -le "${#arr[@]}" ]] || { die "超出范围。"; return; }

  local selected="${arr[$((idx-1))]}"
  echo ""
  echo -e "  ${RED}${BOLD}警告:${NC} 此操作将永久删除实例 '${YELLOW}${selected}${NC}'"
  echo -e "  包括服务、可执行文件和所有配置文件。"
  echo ""
  echo -ne "  ${BOLD}请输入实例名称以确认删除:${NC} "
  read -r confirm_name

  if [[ "$confirm_name" != "$selected" ]]; then
    warn "名称不匹配，卸载已取消。"
    return
  fi

  uninstall_instance_no_confirm "$selected"
}

ui_system_control() {
  draw_box_header "系统控制"

  local units
  units="$(list_xrayr_units)"
  if [[ -z "$units" ]]; then
    warn "未找到任何 XrayR 系统服务。"
    return
  fi

  echo "  可用服务列表:"
  echo ""

  local i=0
  local arr=()
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    i=$((i+1))
    local status
    if systemctl is-active --quiet "$u" 2>/dev/null; then
      status="${GREEN}● 运行中${NC}"
    else
      status="${RED}● 已停止${NC}"
    fi
    printf "  ${BOLD}${YELLOW}%d)${NC}  %-30s " "$i" "$u"
    echo -e "$status"
    arr+=("$u")
  done <<< "$units"

  echo ""
  echo -ne "  ${BOLD}请选择服务编号 (输入 0 取消):${NC} "
  read -r idx

  if [[ "$idx" == "0" ]]; then
    warn "已取消。"
    return
  fi

  [[ "$idx" =~ ^[0-9]+$ ]] || { die "无效的选择。"; return; }
  [[ "$idx" -ge 1 && "$idx" -le "${#arr[@]}" ]] || { die "超出范围。"; return; }

  local selected="${arr[$((idx-1))]}"

  echo ""
  echo -e "  已选择: ${BOLD}${selected}${NC}"
  echo ""
  draw_menu_item "1" "启动"
  draw_menu_item "2" "停止"
  draw_menu_item "3" "重启"
  draw_menu_item "4" "查看状态"
  draw_menu_item "5" "查看日志 (最近 50 行)"
  echo ""
  echo -ne "  ${BOLD}请选择操作 (1-5):${NC} "
  read -r act

  echo ""
  case "$act" in
    1) systemctl start "$selected";   info "✔ 已启动 $selected" ;;
    2) systemctl stop "$selected";    info "✔ 已停止 $selected" ;;
    3) systemctl restart "$selected"; info "✔ 已重启 $selected" ;;
    4) systemctl status "$selected" --no-pager -l ;;
    5) journalctl -u "$selected" --no-pager -n 50 ;;
    *) die "无效的操作。" ;;
  esac
}

ui_edit_config() {
  draw_box_header "编辑实例配置"

  mkdir -p "$VERSIONS_DIR"
  local names
  names="$(find "$VERSIONS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | LC_ALL=C sort || true)"

  if [[ -z "$names" ]]; then
    warn "未找到任何实例。"
    return
  fi

  echo "  可用实例列表:"
  echo ""

  local i=0
  local arr=()
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    i=$((i+1))
    draw_menu_item "$i" "$n"
    arr+=("$n")
  done <<< "$names"

  echo ""
  echo -ne "  ${BOLD}请选择实例编号 (输入 0 取消):${NC} "
  read -r idx

  if [[ "$idx" == "0" ]]; then
    warn "已取消。"
    return
  fi

  [[ "$idx" =~ ^[0-9]+$ ]] || { die "无效的选择。"; return; }
  [[ "$idx" -ge 1 && "$idx" -le "${#arr[@]}" ]] || { die "超出范围。"; return; }

  local selected="${arr[$((idx-1))]}"
  local config_file="${VERSIONS_DIR}/${selected}/config.yml"

  if [[ ! -f "$config_file" ]]; then
    die "未找到配置文件: $config_file"
    return
  fi

  local editor="${EDITOR:-vi}"
  info "正在使用 ${editor} 打开 ${config_file}..."
  "$editor" "$config_file"

  echo ""
  echo -ne "  ${BOLD}是否重启服务以应用更改? (y/n):${NC} "
  read -r restart
  if [[ "$restart" == "y" || "$restart" == "Y" ]]; then
    local svc; svc="$(service_name "$selected")"
    systemctl restart "$svc" || true
    if systemctl is-active --quiet "$svc"; then
      info "✔ 服务已成功重启。"
    else
      warn "⚠ 服务可能未正常启动。"
      echo "  journalctl -u $svc -e --no-pager"
    fi
  fi
}

# ===== 主菜单 =====
main_menu() {
  while true; do
    clear
    echo ""
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════╗"
    echo "  ║                                                  ║"
    echo "  ║          XrayR 实例管理器                        ║"
    echo "  ║                                                  ║"
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  ${BOLD}安装目录:${NC} ${VERSIONS_DIR}"
    echo ""
    draw_line "─" 56
    echo ""
    draw_menu_item "1" "安装新实例"
    draw_menu_item "2" "查看已安装实例"
    draw_menu_item "3" "卸载实例"
    draw_menu_item "4" "系统控制 (启动/停止/重启)"
    draw_menu_item "5" "编辑实例配置"
    echo ""
    draw_line "─" 56
    echo ""
    draw_menu_item "0" "退出"
    echo ""
    echo -ne "  ${BOLD}请输入选项 [0-5]:${NC} "
    read -r choice

    case "$choice" in
      1) ui_install;          press_any_key ;;
      2) ui_list;             press_any_key ;;
      3) ui_uninstall;        press_any_key ;;
      4) ui_system_control;   press_any_key ;;
      5) ui_edit_config;      press_any_key ;;
      0)
        echo ""
        info "再见！"
        exit 0
        ;;
      *)
        die "无效的选项，请输入 0-5。"
        sleep 1
        ;;
    esac
  done
}

# ===== 入口 =====
main() {
  need_root || exit 1
  check_64bit || exit 1
  mkdir -p "$VERSIONS_DIR"
  main_menu
}

main
