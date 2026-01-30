#!/usr/bin/env bash
set -euo pipefail

XRAYR_REPO="XrayR-project/XrayR"
BASE_DIR="/etc/XrayR"
VERSIONS_DIR="${BASE_DIR}/version"

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Must run as root."; }

check_64bit() {
  [[ "$(getconf LONG_BIT 2>/dev/null || echo 0)" == "64" ]] || die "Only 64-bit systems are supported."
}

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf"; return; fi
  if command -v yum >/dev/null 2>&1; then echo "yum"; return; fi
  die "No supported package manager found (apt-get/dnf/yum)."
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
    *) die "Unsupported arch: ${a}" ;;
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
  [[ -n "$v" ]] || die "Failed to fetch latest version from GitHub API."
  echo "$v"
}

instance_dir() { echo "${VERSIONS_DIR}/$1"; }
service_name() { echo "XrayR-$1.service"; }

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

  # Fix: avoid "tmp: unbound variable" under set -u
  local tmp=""
  tmp="$(mktemp -d)"
  trap '[[ -n "${tmp:-}" ]] && rm -rf "${tmp}"' EXIT

  local url="https://github.com/${XRAYR_REPO}/releases/download/${version_tag}/XrayR-linux-${arch}.zip"
  echo "Installing instance: ${name}"
  echo "Version: ${version_tag}"
  echo "Arch: ${arch}"
  echo "Dir: ${dir}"
  echo "Download: ${url}"

  wget -q -O "${tmp}/xrayr.zip" "$url" || die "Download failed. Check version/tag and GitHub connectivity."
  unzip -q -o "${tmp}/xrayr.zip" -d "${tmp}" || die "Unzip failed."
  [[ -f "${tmp}/XrayR" ]] || die "XrayR binary not found in archive."

  install -m 0755 "${tmp}/XrayR" "${dir}/XrayR"
  [[ -f "${tmp}/geoip.dat" ]]   && install -m 0644 "${tmp}/geoip.dat"   "${dir}/geoip.dat"
  [[ -f "${tmp}/geosite.dat" ]] && install -m 0644 "${tmp}/geosite.dat" "${dir}/geosite.dat"

  # Create config only once
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
    echo "OK: service running: $(service_name "$name")"
  else
    echo "WARN: service not active. Check:"
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
    echo "No instances found in ${VERSIONS_DIR}"
    return 0
  fi

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    local d="${VERSIONS_DIR}/${name}"
    local ver="unknown"
    [[ -f "$d/.installed_version" ]] && ver="$(cat "$d/.installed_version" 2>/dev/null || echo unknown)"
    echo "${name} (${ver})"
  done <<< "$names"
}

uninstall_instance_no_confirm() {
  local name="$1"
  [[ -n "$name" ]] || die "Name required for uninstall. Use: uninstall -n <name>"

  local dir; dir="$(instance_dir "$name")"
  [[ -d "$dir" ]] || die "Instance dir not found: $dir"

  local svc; svc="$(service_name "$name")"

  systemctl stop "$svc" >/dev/null 2>&1 || true
  systemctl disable "$svc" >/dev/null 2>&1 || true

  rm -f "/etc/systemd/system/${svc}"
  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true

  rm -rf "$dir"
  echo "OK: Uninstalled '${name}' (service + ${dir})"
}

# ===== system control =====
list_xrayr_units() {
  local units=""

  # list-unit-files covers enabled/disabled/static units
  units="$(systemctl list-unit-files --no-legend 2>/dev/null \
          | awk '{print $1}' \
          | grep -E '^XrayR-.*\.service$' \
          | LC_ALL=C sort -u || true)"

  # fallback scan
  if [[ -z "$units" ]]; then
    units="$(find /etc/systemd/system -maxdepth 1 -type f -name 'XrayR-*.service' -printf '%f\n' 2>/dev/null \
            | LC_ALL=C sort -u || true)"
  fi

  echo "$units"
}

choose_xrayr_unit() {
  local units
  units="$(list_xrayr_units)"
  [[ -n "$units" ]] || die "No systemd units found with prefix 'XrayR-'."

  # IMPORTANT: menu output must go to stderr to avoid polluting command substitution
  echo "XrayR systemd units:" >&2

  local i=0
  local arr=()
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    i=$((i+1))
    echo "  ${i}) ${u}" >&2
    arr+=("$u")
  done <<< "$units"

  echo "" >&2
  read -r -p "Select number: " idx

  [[ "$idx" =~ ^[0-9]+$ ]] || die "Invalid selection."
  [[ "$idx" -ge 1 && "$idx" -le "${#arr[@]}" ]] || die "Out of range."

  # ONLY this line goes to stdout
  printf '%s\n' "${arr[$((idx-1))]}"
}

system_menu() {
  local unit
  unit="$(choose_xrayr_unit)"

  echo "" >&2
  echo "Selected: ${unit}" >&2
  echo "1) Start" >&2
  echo "2) Stop" >&2
  echo "3) Restart" >&2
  echo "4) Status" >&2
  echo "" >&2

  read -r -p "Choose action (1-4): " act
  case "$act" in
    1) systemctl start "$unit";   echo "OK: started $unit" ;;
    2) systemctl stop "$unit";    echo "OK: stopped $unit" ;;
    3) systemctl restart "$unit"; echo "OK: restarted $unit" ;;
    4) systemctl status "$unit" --no-pager -l ;;
    *) die "Invalid action." ;;
  esac
}

usage() {
  cat <<EOF
Usage:
  bash install.sh install   <name> [version]
  bash install.sh install   -n <name> [-v <version>]
  bash install.sh list
  bash install.sh uninstall -n <name>
  bash install.sh system

Notes:
  - Files: ${VERSIONS_DIR}/<name>/
  - Service: XrayR-<name>.service
  - Uninstall performs NO confirmation prompt.
EOF
}

main() {
  need_root
  check_64bit
  mkdir -p "$VERSIONS_DIR"

  local action="${1:-help}"
  shift || true

  local name=""
  local version_in=""

  # Positional args supported ONLY for install
  if [[ "$action" == "install" ]]; then
    if [[ $# -gt 0 && "${1:-}" != -* ]]; then
      name="$1"; shift
    fi
    if [[ $# -gt 0 && "${1:-}" != -* ]]; then
      version_in="$1"; shift
    fi
  fi

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--name) name="${2:-}"; shift 2 ;;
      -v|--version) version_in="${2:-}"; shift 2 ;;
      -h|--help) action="help"; shift ;;
      *)
        if [[ "$action" == "uninstall" ]]; then
          die "Uninstall requires -n <name>. Example: ./install.sh uninstall -n nodeB"
        fi
        die "Unknown arg: $1"
        ;;
    esac
  done

  case "$action" in
    install)
      [[ -n "$name" ]] || read -r -p "Instance name: " name
      [[ -n "$name" ]] || die "Name required."
      [[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Name allowed chars: [a-zA-Z0-9._-]"

      local pm; pm="$(detect_pm)"
      install_deps "$pm"

      local arch; arch="$(detect_arch)"
      local tag; tag="$(normalize_version_tag "$version_in")"
      [[ -n "$tag" ]] || tag="$(latest_version)"

      install_instance "$name" "$tag" "$arch"
      ;;
    list)
      list_instances
      ;;
    uninstall)
      [[ -n "$name" ]] || die "Uninstall requires -n <name>. Example: ./install.sh uninstall -n nodeB"
      uninstall_instance_no_confirm "$name"
      ;;
    system)
      system_menu
      ;;
    help|-h|--help|"")
      usage
      ;;
    *)
      usage
      die "Unknown action: $action"
      ;;
  esac
}

main "$@"
