#!/usr/bin/env bash
set -euo pipefail

# XrayR 二进制路径（默认安装位置）
XRAYR_BIN="/usr/local/bin/XrayR"
# XrayR 配置根目录（默认）
XRAYR_DIR="/etc/XrayR"
# systemd 单元文件目录
SYSTEMD_DIR="/etc/systemd/system"

log() {
  echo "[install.sh] $*"
}

# 检查是否以 root 运行
ensure_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

# 安装 systemd 单元模板和默认服务
install_systemd_units() {
  log "Installing systemd unit templates for multi-instance support"
  mkdir -p "$SYSTEMD_DIR"

  cat >"$SYSTEMD_DIR/XrayR@.service" <<'UNIT'
[Unit]
Description=XrayR Service (%i)
After=network.target

[Service]
Type=simple
EnvironmentFile=-/etc/XrayR/%i/env
ExecStart=/usr/local/bin/XrayR -config ${XRAYR_CONFIG}
Restart=on-failure
RestartSec=5s
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
UNIT

  cat >"$SYSTEMD_DIR/XrayR.service" <<'UNIT'
[Unit]
Description=XrayR Service
After=network.target

[Service]
Type=simple
EnvironmentFile=-/etc/XrayR/default/env
ExecStart=/usr/local/bin/XrayR -config ${XRAYR_CONFIG}
Restart=on-failure
RestartSec=5s
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
}

# 生成默认单实例配置占位文件（如不存在）
ensure_default_config() {
  local default_dir="$XRAYR_DIR/default"
  local default_config="$default_dir/config.yml"
  local default_env="$default_dir/env"

  mkdir -p "$default_dir"
  if [[ ! -f "$default_config" ]]; then
    log "Creating default config placeholder at $default_config"
    cat >"$default_config" <<'CFG'
# Default single-instance configuration for XrayR
# Replace this with your actual XrayR configuration.
CFG
  fi

  if [[ ! -f "$default_env" ]]; then
    log "Writing default environment file $default_env"
    cat >"$default_env" <<ENV
XRAYR_CONFIG=$default_config
ENV
  fi
}

# 创建并启动一个具名实例
create_instance() {
  local name="$1"
  local instance_dir="$XRAYR_DIR/${name}"
  local config_path="$instance_dir/config.yml"
  local env_path="$instance_dir/env"

  mkdir -p "$instance_dir"
  if [[ -f "$config_path" ]]; then
    log "Config $config_path already exists; leaving in place"
  else
    log "Creating instance config placeholder at $config_path"
    cat >"$config_path" <<'CFG'
# Instance configuration for XrayR
# Replace this with your actual XrayR configuration.
CFG
  fi

  log "Writing environment file $env_path"
  cat >"$env_path" <<ENV
XRAYR_CONFIG=$config_path
ENV

  log "Enabling and starting XrayR@${name}.service"
  systemctl enable --now "XrayR@${name}.service"
}

# 卸载全部已安装内容（服务、单元、配置）
uninstall_all() {
  local instances=()
  local selection

  if [[ -d "$XRAYR_DIR" ]]; then
    while IFS= read -r -d '' dir; do
      instances+=("$(basename "$dir")")
    done < <(find "$XRAYR_DIR" -mindepth 1 -maxdepth 1 -type d -print0)
  fi

  if [[ ${#instances[@]} -eq 0 ]]; then
    log "No instances found under $XRAYR_DIR"
    return 0
  fi

  log "Available instances under $XRAYR_DIR:"
  local index=1
  for name in "${instances[@]}"; do
    echo "  [$index] $name"
    index=$((index + 1))
  done
  echo "  [a] all"

  read -r -p "Select instance numbers to uninstall (e.g. 1 3) or 'a' for all: " selection

  if [[ "$selection" == "a" || "$selection" == "A" ]]; then
    selection="$(seq 1 "${#instances[@]}")"
  fi

  for token in $selection; do
    if ! [[ "$token" =~ ^[0-9]+$ ]]; then
      log "Skipping invalid selection: $token"
      continue
    fi
    if (( token < 1 || token > ${#instances[@]} )); then
      log "Skipping out-of-range selection: $token"
      continue
    fi

    local name="${instances[$((token - 1))]}"
    local unit

    if [[ "$name" == "default" ]]; then
      unit="XrayR.service"
    else
      unit="XrayR@${name}.service"
    fi

    log "Stopping and disabling $unit"
    systemctl disable --now "$unit" 2>/dev/null || true

    log "Removing instance directory $XRAYR_DIR/$name"
    rm -rf "$XRAYR_DIR/$name"
  done

  if [[ ! -d "$XRAYR_DIR" || -z "$(ls -A "$XRAYR_DIR" 2>/dev/null)" ]]; then
    log "Removing systemd unit files (no remaining instances)"
    rm -f "$SYSTEMD_DIR/XrayR@.service" "$SYSTEMD_DIR/XrayR.service"
    systemctl daemon-reload
  fi
}

# 打印使用说明
show_usage() {
  cat <<'USAGE'
Usage:
  install.sh install               Install systemd units and default config
  install.sh instance <name>       Create and start a named instance
  install.sh uninstall             Remove all installed XrayR content

Examples:
  install.sh install
  install.sh instance east
  install.sh instance west

Notes:
  - Each instance (including default) stores files under /etc/XrayR/<name>/.
  - Each instance uses /etc/XrayR/<name>/config.yml as its config.
  - Environment overrides live in /etc/XrayR/<name>/env.
USAGE
}

main() {
  ensure_root

  case "${1:-}" in
    install)
      install_systemd_units
      ensure_default_config
      log "Install complete. Use: install.sh instance <name> to add instances."
      ;;
    instance)
      if [[ -z "${2:-}" ]]; then
        echo "Instance name is required." >&2
        show_usage
        exit 1
      fi
      install_systemd_units
      create_instance "$2"
      ;;
    uninstall)
      uninstall_all
      ;;
    *)
      show_usage
      exit 1
      ;;
  esac
}

main "$@"
