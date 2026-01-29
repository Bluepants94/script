#!/usr/bin/env bash
set -euo pipefail

XRAYR_BIN="/usr/local/bin/XrayR"
XRAYR_DIR="/etc/XrayR"
SYSTEMD_DIR="/etc/systemd/system"

log() {
  echo "[install.sh] $*"
}

ensure_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

install_systemd_units() {
  log "Installing systemd unit templates for multi-instance support"
  mkdir -p "$SYSTEMD_DIR"

  cat >"$SYSTEMD_DIR/XrayR@.service" <<'UNIT'
[Unit]
Description=XrayR Service (%i)
After=network.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/XrayR-%i
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
ExecStart=/usr/local/bin/XrayR -config /etc/XrayR/config.yml
Restart=on-failure
RestartSec=5s
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
}

ensure_default_config() {
  mkdir -p "$XRAYR_DIR"
  if [[ ! -f "$XRAYR_DIR/config.yml" ]]; then
    log "Creating default config placeholder at $XRAYR_DIR/config.yml"
    cat >"$XRAYR_DIR/config.yml" <<'CFG'
# Default single-instance configuration for XrayR
# Replace this with your actual XrayR configuration.
CFG
  fi
}

create_instance() {
  local name="$1"
  local config_path="$XRAYR_DIR/${name}.yml"
  local env_path="/etc/default/XrayR-${name}"

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

show_usage() {
  cat <<'USAGE'
Usage:
  install.sh install               Install systemd units and default config
  install.sh instance <name>       Create and start a named instance

Examples:
  install.sh install
  install.sh instance east
  install.sh instance west

Notes:
  - Each instance uses /etc/XrayR/<name>.yml as its config.
  - Environment overrides live in /etc/default/XrayR-<name>.
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
    *)
      show_usage
      exit 1
      ;;
  esac
}

main "$@"
