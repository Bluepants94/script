#!/usr/bin/env bash
set -euo pipefail

# ======= UI colors =======
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# ======= constants =======
XRAYR_REPO="XrayR-project/XrayR"
XRAYR_RELEASE_REPO="XrayR-project/XrayR-release"
BASE_DIR="/etc/XrayR"
VERSIONS_DIR="${BASE_DIR}/version"

# ======= helpers =======
err() { echo -e "${red}错误：${plain}$*"; }
info() { echo -e "${green}${plain}$*"; }
warn() { echo -e "${yellow}${plain}$*"; }

need_root() {
  [[ ${EUID} -ne 0 ]] && err "必须使用 root 用户运行此脚本！" && exit 1
}

detect_os() {
  local release=""
  if [[ -f /etc/redhat-release ]]; then
    release="centos"
  elif grep -Eqi "debian" /etc/issue 2>/dev/null || grep -Eqi "debian" /proc/version 2>/dev/null; then
    release="debian"
  elif grep -Eqi "ubuntu" /etc/issue 2>/dev/null || grep -Eqi "ubuntu" /proc/version 2>/dev/null; then
    release="ubuntu"
  elif grep -Eqi "centos|red hat|redhat" /etc/issue 2>/dev/null || grep -Eqi "centos|red hat|redhat" /proc/version 2>/dev/null; then
    release="centos"
  else
    err "未检测到系统版本，请联系脚本作者！"
    exit 1
  fi
  echo "${release}"
}

detect_os_version_major() {
  local os_version=""
  if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release || true)
  fi
  if [[ -z "${os_version}" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release || true)
  fi
  echo "${os_version:-0}"
}

check_os_compat() {
  local release="$1"
  local vmaj
  vmaj="$(detect_os_version_major)"

  case "${release}" in
    centos)
      [[ "${vmaj}" -le 6 ]] && err "请使用 CentOS 7 或更高版本的系统！" && exit 1
      ;;
    ubuntu)
      [[ "${vmaj}" -lt 16 ]] && err "请使用 Ubuntu 16 或更高版本的系统！" && exit 1
      ;;
    debian)
      [[ "${vmaj}" -lt 8 ]] && err "请使用 Debian 8 或更高版本的系统！" && exit 1
      ;;
  esac
}

detect_arch() {
  local arch
  arch="$(arch || true)"
  case "${arch}" in
    x86_64|x64|amd64) echo "64" ;;
    aarch64|arm64)    echo "arm64-v8a" ;;
    s390x)            echo "s390x" ;;
    *)
      warn "检测架构失败，使用默认架构: 64"
      echo "64"
      ;;
  esac
}

check_64bit() {
  if [[ "$(getconf WORD_BIT)" == "32" ]] || [[ "$(getconf LONG_BIT)" != "64" ]]; then
    err "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)。"
    exit 2
  fi
}

install_deps() {
  local release="$1"
  if [[ "${release}" == "centos" ]]; then
    yum install -y epel-release
    yum install -y wget curl unzip tar crontabs socat
  else
    apt update -y
    apt install -y wget curl unzip tar cron socat
  fi
}

latest_version() {
  # GitHub API: releases/latest
  local v
  v="$(curl -fsSL "https://api.github.com/repos/${XRAYR_REPO}/releases/latest" \
        | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)"
  if [[ -z "${v}" ]]; then
    err "检测 XrayR 最新版本失败（可能触发 GitHub API 限制）。请稍后再试，或手动指定版本。"
    exit 1
  fi
  echo "${v}"
}

normalize_version_tag() {
  local in="${1:-}"
  if [[ -z "${in}" ]]; then
    echo ""
    return 0
  fi
  if [[ "${in}" == v* ]]; then
    echo "${in}"
  else
    echo "v${in}"
  fi
}

instance_dir() {
  local name="$1"
  echo "${VERSIONS_DIR}/${name}"
}

service_name() {
  local name="$1"
  echo "XrayR-${name}.service"
}

create_service_unit() {
  local name="$1"
  local dir="$2"
  local unit_path="/etc/systemd/system/$(service_name "${name}")"

  cat > "${unit_path}" <<EOF
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

download_and_install() {
  local name="$1"
  local version_tag="$2"
  local arch="$3"
  local dir
  dir="$(instance_dir "${name}")"

  mkdir -p "${dir}"

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT

  local url="https://github.com/${XRAYR_REPO}/releases/download/${version_tag}/XrayR-linux-${arch}.zip"
  info "开始安装实例: ${name}"
  info "目标目录: ${dir}"
  info "版本: ${version_tag}"
  info "下载: ${url}"

  if ! wget -q -N --no-check-certificate -O "${tmpdir}/XrayR-linux.zip" "${url}"; then
    err "下载失败：请确认服务器可访问 GitHub，且版本存在：${version_tag}"
    exit 1
  fi

  unzip -q -o "${tmpdir}/XrayR-linux.zip" -d "${tmpdir}"

  # 需要的文件：XrayR, geoip.dat, geosite.dat, config.yml, dns.json, route.json, custom_*.json, rulelist
  if [[ ! -f "${tmpdir}/XrayR" ]]; then
    err "解压后未找到 XrayR 可执行文件，安装终止。"
    exit 1
  fi

  # 二进制与数据文件：覆盖更新
  install -m 0755 "${tmpdir}/XrayR" "${dir}/XrayR"
  [[ -f "${tmpdir}/geoip.dat" ]]   && install -m 0644 "${tmpdir}/geoip.dat"   "${dir}/geoip.dat"
  [[ -f "${tmpdir}/geosite.dat" ]] && install -m 0644 "${tmpdir}/geosite.dat" "${dir}/geosite.dat"

  # 配置类文件：仅在不存在时写入，避免覆盖用户配置
  for f in config.yml dns.json route.json custom_outbound.json custom_inbound.json rulelist; do
    if [[ -f "${tmpdir}/${f}" && ! -f "${dir}/${f}" ]]; then
      install -m 0644 "${tmpdir}/${f}" "${dir}/${f}"
    fi
  done

  # 记录版本
  echo "${version_tag}" > "${dir}/.installed_version"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "${dir}/.installed_at_utc"

  create_service_unit "${name}" "${dir}"
  systemctl enable "$(service_name "${name}")" >/dev/null

  # 启动/重启实例
  systemctl restart "$(service_name "${name}")"

  sleep 1
  if systemctl is-active --quiet "$(service_name "${name}")"; then
    info "实例 ${name} 启动成功（systemd: $(service_name "${name}")）"
  else
    warn "实例 ${name} 可能启动失败，请检查日志：journalctl -u $(service_name "${name}") -e --no-pager"
  fi

  trap - EXIT
  rm -rf "${tmpdir}"
}

list_instances() {
  mkdir -p "${VERSIONS_DIR}"
  if [[ ! -d "${VERSIONS_DIR}" ]]; then
    echo ""
    return 0
  fi

  local items=()
  while IFS= read -r -d '' d; do
    items+=("$(basename "${d}")")
  done < <(find "${VERSIONS_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)

  if [[ ${#items[@]} -eq 0 ]]; then
    echo ""
    return 0
  fi

  # 按字母排序
  IFS=$'\n' items=($(sort <<<"${items[*]}")); unset IFS

  for n in "${items[@]}"; do
    local v="unknown"
    [[ -f "$(instance_dir "${n}")/.installed_version" ]] && v="$(cat "$(instance_dir "${n}")/.installed_version" 2>/dev/null || true)"
    echo "${n} (${v})"
  done
}

choose_instance_interactive() {
  local lines
  lines="$(list_instances)"
  if [[ -z "${lines}" ]]; then
    err "未发现任何已安装实例：${VERSIONS_DIR} 为空。"
    exit 1
  fi

  echo "已安装实例列表："
  local i=1
  local names=()
  while IFS= read -r line; do
    local name="${line%% *}"
    echo "  ${i}) ${line}"
    names+=("${name}")
    i=$((i+1))
  done <<< "${lines}"

  echo ""
  read -r -p "请输入要卸载的编号: " idx
  if [[ ! "${idx}" =~ ^[0-9]+$ ]] || [[ "${idx}" -lt 1 ]] || [[ "${idx}" -gt "${#names[@]}" ]]; then
    err "输入无效。"
    exit 1
  fi
  echo "${names[$((idx-1))]}"
}

uninstall_instance() {
  local name="$1"
  local dir
  dir="$(instance_dir "${name}")"
  local unit="/etc/systemd/system/$(service_name "${name}")"

  if [[ ! -d "${dir}" ]]; then
    err "实例目录不存在：${dir}"
    exit 1
  fi

  echo ""
  read -r -p "确认卸载实例 '${name}' 以及其 systemd 服务？[y/N]: " yn
  yn="${yn:-N}"
  if [[ ! "${yn}" =~ ^[Yy]$ ]]; then
    warn "已取消。"
    exit 0
  fi

  # stop/disable service
  if systemctl list-unit-files | grep -q "^$(service_name "${name}")"; then
    systemctl stop "$(service_name "${name}")" >/dev/null 2>&1 || true
    systemctl disable "$(service_name "${name}")" >/dev/null 2>&1 || true
  fi

  # remove unit file
  rm -f "${unit}"
  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true

  # remove instance dir
  rm -rf "${dir}"

  info "卸载完成：${name}"

  # 如果没有任何实例了，可选清理 BASE_DIR（仅保留空目录）
  if [[ -d "${VERSIONS_DIR}" ]] && [[ -z "$(ls -A "${VERSIONS_DIR}" 2>/dev/null || true)" ]]; then
    warn "当前已无任何实例残留：${VERSIONS_DIR} 为空。"
  fi
}

usage() {
  cat <<EOF
用法:
  bash install.sh install   -n <name> [-v <version>]
  bash install.sh uninstall [-n <name>]
  bash install.sh list
  bash install.sh help

说明:
  -n, --name       实例名/版本名（目录: ${VERSIONS_DIR}/<name>；服务: XrayR-<name>.service）
  -v, --version    指定 XrayR 版本（例如 v0.9.4 或 0.9.4）；不指定则安装最新版本

示例:
  bash install.sh install -n nodeA
  bash install.sh install -n nodeB -v v0.9.4
  bash install.sh list
  bash install.sh uninstall           # 交互选择要卸载的实例
  bash install.sh uninstall -n nodeA  # 直接卸载 nodeA
EOF
}

# ======= main =======
main() {
  need_root
  check_64bit

  local action="${1:-install}"
  shift || true

  local name=""
  local version_in=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--name)
        name="${2:-}"
        shift 2
        ;;
      -v|--version)
        version_in="${2:-}"
        shift 2
        ;;
      list|install|uninstall|help)
        # 允许 "bash install.sh install -n xxx" 这种位置之外的写法时，忽略
        shift
        ;;
      *)
        err "未知参数: $1"
        usage
        exit 1
        ;;
    esac
  done

  mkdir -p "${VERSIONS_DIR}"

  case "${action}" in
    help|-h|--help)
      usage
      exit 0
      ;;
    list)
      local out
      out="$(list_instances)"
      if [[ -z "${out}" ]]; then
        echo "暂无已安装实例（${VERSIONS_DIR} 为空）。"
      else
        echo "${out}"
      fi
      exit 0
      ;;
    install)
      if [[ -z "${name}" ]]; then
        read -r -p "请输入实例名（例如 nodeA、panel1 等）: " name
      fi
      if [[ -z "${name}" ]]; then
        err "实例名不能为空。"
        exit 1
      fi
      if [[ "${name}" =~ [^a-zA-Z0-9._-] ]]; then
        err "实例名仅允许字母/数字/点/下划线/短横线。"
        exit 1
      fi

      local release
      release="$(detect_os)"
      check_os_compat "${release}"
      install_deps "${release}"

      local arch
      arch="$(detect_arch)"
      echo "架构: ${arch}"

      local tag
      tag="$(normalize_version_tag "${version_in}")"
      if [[ -z "${tag}" ]]; then
        tag="$(latest_version)"
        info "检测到 XrayR 最新版本：${tag}"
      fi

      download_and_install "${name}" "${tag}" "${arch}"

      echo ""
      echo "管理建议："
      echo "  查看状态: systemctl status $(service_name "${name}") --no-pager -l"
      echo "  查看日志: journalctl -u $(service_name "${name}") -e --no-pager"
      echo "  配置路径: $(instance_dir "${name}")/config.yml"
      ;;
    uninstall)
      if [[ -z "${name}" ]]; then
        name="$(choose_instance_interactive)"
      fi
      uninstall_instance "${name}"
      ;;
    *)
      err "未知动作: ${action}"
      usage
      exit 1
      ;;
  esac
}

main "$@"
