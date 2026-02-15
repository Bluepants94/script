#!/usr/bin/env bash
set -euo pipefail

XRAYR_REPO="XrayR-project/XrayR"
BASE_DIR="/etc/XrayR"
VERSIONS_DIR="${BASE_DIR}/version"

# ===== Colors =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ===== Utilities =====
die() { echo -e "${RED}ERROR: $*${NC}" >&2; }
info() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
header() { echo -e "${BOLD}${CYAN}$*${NC}"; }

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { die "Must run as root."; return 1; }; }

check_64bit() {
  [[ "$(getconf LONG_BIT 2>/dev/null || echo 0)" == "64" ]] || { die "Only 64-bit systems are supported."; return 1; }
}

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf"; return; fi
  if command -v yum >/dev/null 2>&1; then echo "yum"; return; fi
  die "No supported package manager found (apt-get/dnf/yum)."
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
    *) die "Unsupported arch: ${a}"; return 1 ;;
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
  [[ -n "$v" ]] || { die "Failed to fetch latest version from GitHub API."; return 1; }
  echo "$v"
}

instance_dir() { echo "${VERSIONS_DIR}/$1"; }
service_name() { echo "XrayR-$1.service"; }

# ===== Drawing Helpers =====
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
  echo -e "${YELLOW}Press Enter to return to the main menu...${NC}"
  read -r
}

# ===== Core Functions =====
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
  info "Installing instance: ${name}"
  echo -e "  Version : ${BOLD}${version_tag}${NC}"
  echo -e "  Arch    : ${BOLD}${arch}${NC}"
  echo -e "  Dir     : ${BOLD}${dir}${NC}"
  echo -e "  URL     : ${url}"
  echo ""

  wget -q -O "${tmp}/xrayr.zip" "$url" || { die "Download failed. Check version/tag and GitHub connectivity."; return 1; }
  unzip -q -o "${tmp}/xrayr.zip" -d "${tmp}" || { die "Unzip failed."; return 1; }
  [[ -f "${tmp}/XrayR" ]] || { die "XrayR binary not found in archive."; return 1; }

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
    info "✔ Service running: $(service_name "$name")"
  else
    warn "⚠ Service not active. Check:"
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
    warn "No instances found in ${VERSIONS_DIR}"
    return 0
  fi

  echo ""
  printf "  ${BOLD}%-20s %-15s %-12s${NC}\n" "NAME" "VERSION" "STATUS"
  draw_line "-" 52
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    local d="${VERSIONS_DIR}/${name}"
    local ver="unknown"
    [[ -f "$d/.installed_version" ]] && ver="$(cat "$d/.installed_version" 2>/dev/null || echo unknown)"
    local svc; svc="$(service_name "$name")"
    local status
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      status="${GREEN}running${NC}"
    else
      status="${RED}stopped${NC}"
    fi
    printf "  %-20s %-15s " "$name" "$ver"
    echo -e "$status"
  done <<< "$names"
  echo ""
}

uninstall_instance_no_confirm() {
  local name="$1"
  [[ -n "$name" ]] || { die "Name required for uninstall."; return 1; }

  local dir; dir="$(instance_dir "$name")"
  [[ -d "$dir" ]] || { die "Instance dir not found: $dir"; return 1; }

  local svc; svc="$(service_name "$name")"

  systemctl stop "$svc" >/dev/null 2>&1 || true
  systemctl disable "$svc" >/dev/null 2>&1 || true

  rm -f "/etc/systemd/system/${svc}"
  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true

  rm -rf "$dir"
  info "✔ Uninstalled '${name}' (service + ${dir})"
}

# ===== System Control =====
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

# ===== UI Menus =====

ui_install() {
  draw_box_header "Install New Instance"

  local name=""
  while true; do
    echo -ne "  ${BOLD}Instance name${NC} (e.g. nodeA): "
    read -r name
    if [[ -z "$name" ]]; then
      die "Name cannot be empty. Please try again."
      continue
    fi
    if [[ ! "$name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      die "Name can only contain: [a-zA-Z0-9._-]. Please try again."
      continue
    fi
    break
  done

  echo -ne "  ${BOLD}Version${NC} (leave empty for latest): "
  read -r version_in

  echo ""
  echo -e "  ${BOLD}Confirm installation:${NC}"
  echo -e "    Name    : ${YELLOW}${name}${NC}"
  echo -e "    Version : ${YELLOW}${version_in:-latest}${NC}"
  echo ""
  echo -ne "  ${BOLD}Proceed? (y/n):${NC} "
  read -r confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    warn "Installation cancelled."
    return
  fi

  echo ""
  info "Preparing installation..."

  local pm; pm="$(detect_pm)" || return
  install_deps "$pm"

  local arch; arch="$(detect_arch)" || return
  local tag; tag="$(normalize_version_tag "$version_in")"
  [[ -n "$tag" ]] || tag="$(latest_version)" || return

  install_instance "$name" "$tag" "$arch"
}

ui_list() {
  draw_box_header "Installed Instances"
  list_instances
}

ui_uninstall() {
  draw_box_header "Uninstall Instance"

  mkdir -p "$VERSIONS_DIR"
  local names
  names="$(find "$VERSIONS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | LC_ALL=C sort || true)"

  if [[ -z "$names" ]]; then
    warn "No instances found. Nothing to uninstall."
    return
  fi

  echo "  Available instances:"
  echo ""

  local i=0
  local arr=()
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    i=$((i+1))
    local ver="unknown"
    [[ -f "${VERSIONS_DIR}/${n}/.installed_version" ]] && ver="$(cat "${VERSIONS_DIR}/${n}/.installed_version" 2>/dev/null || echo unknown)"
    draw_menu_item "$i" "${n} (${ver})"
    arr+=("$n")
  done <<< "$names"

  echo ""
  echo -ne "  ${BOLD}Select instance number to uninstall (0 to cancel):${NC} "
  read -r idx

  if [[ "$idx" == "0" ]]; then
    warn "Cancelled."
    return
  fi

  [[ "$idx" =~ ^[0-9]+$ ]] || { die "Invalid selection."; return; }
  [[ "$idx" -ge 1 && "$idx" -le "${#arr[@]}" ]] || { die "Out of range."; return; }

  local selected="${arr[$((idx-1))]}"
  echo ""
  echo -e "  ${RED}${BOLD}WARNING:${NC} This will permanently remove instance '${YELLOW}${selected}${NC}'"
  echo -e "  Including service, binary, and all config files."
  echo ""
  echo -ne "  ${BOLD}Type the instance name to confirm:${NC} "
  read -r confirm_name

  if [[ "$confirm_name" != "$selected" ]]; then
    warn "Name does not match. Uninstall cancelled."
    return
  fi

  uninstall_instance_no_confirm "$selected"
}

ui_system_control() {
  draw_box_header "System Control"

  local units
  units="$(list_xrayr_units)"
  if [[ -z "$units" ]]; then
    warn "No XrayR systemd units found."
    return
  fi

  echo "  Available services:"
  echo ""

  local i=0
  local arr=()
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    i=$((i+1))
    local status
    if systemctl is-active --quiet "$u" 2>/dev/null; then
      status="${GREEN}● running${NC}"
    else
      status="${RED}● stopped${NC}"
    fi
    printf "  ${BOLD}${YELLOW}%d)${NC}  %-30s " "$i" "$u"
    echo -e "$status"
    arr+=("$u")
  done <<< "$units"

  echo ""
  echo -ne "  ${BOLD}Select service number (0 to cancel):${NC} "
  read -r idx

  if [[ "$idx" == "0" ]]; then
    warn "Cancelled."
    return
  fi

  [[ "$idx" =~ ^[0-9]+$ ]] || { die "Invalid selection."; return; }
  [[ "$idx" -ge 1 && "$idx" -le "${#arr[@]}" ]] || { die "Out of range."; return; }

  local selected="${arr[$((idx-1))]}"

  echo ""
  echo -e "  Selected: ${BOLD}${selected}${NC}"
  echo ""
  draw_menu_item "1" "Start"
  draw_menu_item "2" "Stop"
  draw_menu_item "3" "Restart"
  draw_menu_item "4" "Status"
  draw_menu_item "5" "View Logs (last 50 lines)"
  echo ""
  echo -ne "  ${BOLD}Choose action (1-5):${NC} "
  read -r act

  echo ""
  case "$act" in
    1) systemctl start "$selected";   info "✔ Started $selected" ;;
    2) systemctl stop "$selected";    info "✔ Stopped $selected" ;;
    3) systemctl restart "$selected"; info "✔ Restarted $selected" ;;
    4) systemctl status "$selected" --no-pager -l ;;
    5) journalctl -u "$selected" --no-pager -n 50 ;;
    *) die "Invalid action." ;;
  esac
}

ui_edit_config() {
  draw_box_header "Edit Instance Config"

  mkdir -p "$VERSIONS_DIR"
  local names
  names="$(find "$VERSIONS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | LC_ALL=C sort || true)"

  if [[ -z "$names" ]]; then
    warn "No instances found."
    return
  fi

  echo "  Available instances:"
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
  echo -ne "  ${BOLD}Select instance number (0 to cancel):${NC} "
  read -r idx

  if [[ "$idx" == "0" ]]; then
    warn "Cancelled."
    return
  fi

  [[ "$idx" =~ ^[0-9]+$ ]] || { die "Invalid selection."; return; }
  [[ "$idx" -ge 1 && "$idx" -le "${#arr[@]}" ]] || { die "Out of range."; return; }

  local selected="${arr[$((idx-1))]}"
  local config_file="${VERSIONS_DIR}/${selected}/config.yml"

  if [[ ! -f "$config_file" ]]; then
    die "Config file not found: $config_file"
    return
  fi

  local editor="${EDITOR:-vi}"
  info "Opening ${config_file} with ${editor}..."
  "$editor" "$config_file"

  echo ""
  echo -ne "  ${BOLD}Restart service to apply changes? (y/n):${NC} "
  read -r restart
  if [[ "$restart" == "y" || "$restart" == "Y" ]]; then
    local svc; svc="$(service_name "$selected")"
    systemctl restart "$svc" || true
    if systemctl is-active --quiet "$svc"; then
      info "✔ Service restarted successfully."
    else
      warn "⚠ Service may not have started properly."
      echo "  journalctl -u $svc -e --no-pager"
    fi
  fi
}

# ===== Main Menu =====
main_menu() {
  while true; do
    clear
    echo ""
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════╗"
    echo "  ║                                                  ║"
    echo "  ║           XrayR Instance Manager                 ║"
    echo "  ║                                                  ║"
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  ${BOLD}Base directory:${NC} ${VERSIONS_DIR}"
    echo ""
    draw_line "─" 56
    echo ""
    draw_menu_item "1" "Install new instance"
    draw_menu_item "2" "List installed instances"
    draw_menu_item "3" "Uninstall an instance"
    draw_menu_item "4" "System control (start/stop/restart)"
    draw_menu_item "5" "Edit instance config"
    echo ""
    draw_line "─" 56
    echo ""
    draw_menu_item "0" "Exit"
    echo ""
    echo -ne "  ${BOLD}Enter your choice [0-5]:${NC} "
    read -r choice

    case "$choice" in
      1) ui_install;          press_any_key ;;
      2) ui_list;             press_any_key ;;
      3) ui_uninstall;        press_any_key ;;
      4) ui_system_control;   press_any_key ;;
      5) ui_edit_config;      press_any_key ;;
      0)
        echo ""
        info "Goodbye!"
        exit 0
        ;;
      *)
        die "Invalid choice. Please select 0-5."
        sleep 1
        ;;
    esac
  done
}

# ===== Entry Point =====
main() {
  need_root || exit 1
  check_64bit || exit 1
  mkdir -p "$VERSIONS_DIR"
  main_menu
}

main
