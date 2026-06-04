#!/bin/bash
# ============================================================================
# Gost HTTP/SOCKS5 代理管理脚本（交互式 - Gost v3）
# ============================================================================
set -Euo pipefail

# ---------- 常量 ----------
CONF_DIR="/etc/gost"
YAML_CONF="${CONF_DIR}/config.yaml"
STATE_FILE="${CONF_DIR}/state.env"
DOMAIN_WL_FILE="${CONF_DIR}/domain_whitelist.txt"
IP_WL_FILE="${CONF_DIR}/ip_whitelist.txt"
WHITELIST_URL="https://raw.githubusercontent.com/Bluepants94/script/refs/heads/main/gost_proxy/whitelist.txt"

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

is_active() { systemctl -q is-active gost 2>/dev/null; }

get_gost_version() {
    if command -v gost &>/dev/null; then
        gost -V 2>&1 | head -n 1 | awk '{print $2}' || echo "未知版本"
    else
        echo "未安装"
    fi
}

# ---------- 环境与状态初始化 ----------
init_env() {
    check_sudo
    sudo mkdir -p "$CONF_DIR"
    
    if [ ! -f "$STATE_FILE" ]; then
        sudo bash -c "cat > $STATE_FILE" <<EOF
GOST_PORT=8888
GOST_AUTH=
IP_WL_ON=false
DOMAIN_WL_ON=false
EOF
    fi

    if [ ! -f "$IP_WL_FILE" ]; then
        sudo bash -c "cat > $IP_WL_FILE" <<EOF
127.0.0.1
::1
EOF
    fi
}

load_state() { source "$STATE_FILE"; }

save_state() {
    local key="$1" val="$2"
    if grep -qE "^${key}=" "$STATE_FILE" 2>/dev/null; then
        sudo sed -i -E "s|^${key}=.*|${key}=${val}|" "$STATE_FILE"
    else
        echo "${key}=${val}" | sudo tee -a "$STATE_FILE" >/dev/null
    fi
}

# ---------- 直连 API 下载与安装模块 ----------
download_and_install_gost() {
    local arch=""
    case $(uname -m) in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) print_err "暂不支持的架构: $(uname -m)"; return 1 ;;
    esac

    print_info "正在获取 Gost 最新稳定版信息..."
    local latest_version
    # 调用 Github API 获取最新的 Release Tag
    latest_version=$(curl -s https://api.github.com/repos/go-gost/gost/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [ -z "$latest_version" ]; then
        print_err "获取最新版本失败，请检查网络连接。"
        return 1
    fi

    local version_num="${latest_version#v}"
    local filename="gost_${version_num}_linux_${arch}.tar.gz"
    local download_url="https://github.com/go-gost/gost/releases/download/${latest_version}/${filename}"

    print_info "发现新版本 ${latest_version}，正在下载..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    
    if ! curl -fsSL "$download_url" -o "${tmp_dir}/${filename}"; then
        print_err "文件下载失败！"
        rm -rf "$tmp_dir"
        return 1
    fi

    tar -xzf "${tmp_dir}/${filename}" -C "$tmp_dir"
    
    sudo mv "${tmp_dir}/gost" /usr/local/bin/gost
    sudo chmod +x /usr/local/bin/gost
    rm -rf "$tmp_dir"
    return 0
}

install_gost() {
    check_sudo
    download_and_install_gost || exit 1
    
    sudo bash -c "cat > /etc/systemd/system/gost.service" <<EOF
[Unit]
Description=GO Simple Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -C $YAML_CONF
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    print_ok "Gost v3 及 Systemd 服务安装成功。"
}

check_gost() {
    command -v gost &>/dev/null && return 0
    print_warn "Gost 未安装，正在自动安装..."
    install_gost
}

update_gost() {
    check_sudo
    echo ""
    if download_and_install_gost; then
        if is_active; then
            sudo systemctl restart gost 2>/dev/null
            print_ok "Gost 更新成功，并且代理服务已重启！"
        else
            print_ok "Gost 更新成功！"
        fi
    else
        print_err "Gost 更新失败。"
    fi
    echo ""
    read -r -p "按 回车键 返回菜单..."
}

# ---------- 域名白名单下载 ----------
download_whitelist() {
    [ -f "$DOMAIN_WL_FILE" ] && [ -s "$DOMAIN_WL_FILE" ] && return 0
    check_sudo
    local tool=""
    command -v curl  &>/dev/null && tool="curl"
    command -v wget  &>/dev/null && tool="wget"
    [ -z "$tool" ] && return 1
    
    if [ "$tool" = "curl" ]; then
        sudo curl -sSL -o "$DOMAIN_WL_FILE" "$WHITELIST_URL" 2>/dev/null || return 1
    else
        sudo wget -q -O "$DOMAIN_WL_FILE" "$WHITELIST_URL" 2>/dev/null || return 1
    fi
}

# ---------- 配置生成 ----------
generate_yaml() {
    load_state
    local yaml_content="services:
  - name: default-proxy
    addr: \":${GOST_PORT}\"
    handler:
      type: auto"

    if [ -n "${GOST_AUTH:-}" ]; then
        local user="${GOST_AUTH%%:*}"
        local pass="${GOST_AUTH#*:}"
        yaml_content="${yaml_content}\n      auth:\n        username: \"${user}\"\n        password: \"${pass}\""
    fi

    yaml_content="${yaml_content}\n    listener:\n      type: tcp"

    if [ "${IP_WL_ON:-false}" = "true" ]; then
        yaml_content="${yaml_content}\n    admission: client-ip-wl"
    fi

    if [ "${DOMAIN_WL_ON:-false}" = "true" ]; then
        yaml_content="${yaml_content}\n    bypass: target-domain-wl"
    fi

    if [ "${IP_WL_ON:-false}" = "true" ]; then
        yaml_content="${yaml_content}\n
admissions:
  - name: client-ip-wl
    whitelist: true
    matchers:
      - \"file:${IP_WL_FILE}\""
    fi

    if [ "${DOMAIN_WL_ON:-false}" = "true" ]; then
        yaml_content="${yaml_content}\n
bypasses:
  - name: target-domain-wl
    whitelist: true
    matchers:
      - \"file:${DOMAIN_WL_FILE}\""
    fi

    echo -e "$yaml_content" | sudo tee "$YAML_CONF" >/dev/null
}

# ---------- 代理控制 ----------
start_proxy() {
    check_gost; init_env; load_state

    local input_port
    read -r -p "代理端口 (当前: ${GOST_PORT}, 直接回车保持): " input_port
    input_port="${input_port:-$GOST_PORT}"
    [ "$input_port" != "$GOST_PORT" ] && save_state "GOST_PORT" "$input_port"

    local display_auth="${GOST_AUTH:-未设置(免密)}"
    local input_auth
    echo ""
    read -r -p "设置账号密码 [格式 user:pass] (当前: ${display_auth}, 直接回车跳过, 输入 'none' 清除): " input_auth
    if [ "$input_auth" = "none" ]; then
        save_state "GOST_AUTH" ""
    elif [ -n "$input_auth" ]; then
        save_state "GOST_AUTH" "$input_auth"
    fi

    generate_yaml
    sudo systemctl enable gost --now &>/dev/null \
        && print_ok "代理已启动（端口 ${input_port}）。" \
        || print_err "启动失败。"
}

stop_proxy() {
    check_sudo
    sudo systemctl stop gost 2>/dev/null \
        && print_ok "代理已停止。" \
        || print_err "停止失败。"
}

reload_proxy() {
    if ! is_active; then return 1; fi
    check_sudo
    if [ "${DOMAIN_WL_ON:-false}" = "true" ]; then
        sudo rm -f "$DOMAIN_WL_FILE"
        download_whitelist || print_warn "更新白名单失败，尝试使用旧配置。"
    fi
    
    generate_yaml
    sudo systemctl restart gost 2>/dev/null \
        && print_ok "配置已重载生效。" \
        || print_err "配置应用失败。"
}

# ---------- 开关 ----------
toggle_proxy() {
    if is_active; then stop_proxy; else start_proxy; fi
}

toggle_ip_whitelist() {
    load_state
    if [ "${IP_WL_ON:-false}" = "true" ]; then
        save_state "IP_WL_ON" "false"
        print_ok "IP 白名单已关闭。所有人均可连接本代理。"
    else
        save_state "IP_WL_ON" "true"
        print_ok "IP 白名单已开启。请确保 ${IP_WL_FILE} 中有你的 IP。"
    fi
    is_active && reload_proxy
}

toggle_domain_whitelist() {
    load_state
    if [ "${DOMAIN_WL_ON:-false}" = "true" ]; then
        save_state "DOMAIN_WL_ON" "false"
        print_ok "域名白名单已关闭。允许访问所有网站。"
    else
        download_whitelist || print_warn "域名白名单文件下载可能失败，将尝试使用本地缓存。"
        save_state "DOMAIN_WL_ON" "true"
        print_ok "域名白名单已开启。"
    fi
    is_active && reload_proxy
}

# ---------- UI ----------
show_banner() {
    load_state
    local ps="" pi="" auth_status=""
    local cur_ver
    
    cur_ver=$(get_gost_version)
    [ -n "${GOST_AUTH:-}" ] && auth_status="${GREEN}● 已开启${NC} (${GOST_AUTH%%:*}:***)" || auth_status="${RED}○ 未设置${NC}"

    if is_active && [ -f "$YAML_CONF" ]; then
        ps="${GREEN}● 已启动${NC}"
        pi="  监听:       0.0.0.0:${GOST_PORT} (HTTP & SOCKS5)"
    else
        ps="${RED}○ 未启动${NC}"
    fi
    
    clear
    echo "=================================================="
    echo "        Gost v3 代理管理工具 (HTTP & SOCKS5)"
    echo "=================================================="
    echo -e "  Gost 版本:  ${CYAN}${cur_ver}${NC}"
    echo "  配置目录:   $CONF_DIR"
    echo "--------------------------------------------------"
    echo -e "  代理状态:   $ps"
    [ -n "$pi" ] && echo "$pi"
    echo -e "  身份认证:   $auth_status"
    echo -e "  IP 白名单:  $([ "${IP_WL_ON:-false}" = "true" ] && echo "${GREEN}● 已开启${NC}" || echo "${RED}○ 未开启${NC}")"
    echo -e "  域名白名单: $([ "${DOMAIN_WL_ON:-false}" = "true" ] && echo "${GREEN}● 已开启${NC}" || echo "${RED}○ 未开启${NC}")"
    echo "=================================================="
}

show_menu() {
    local r=false; is_active && r=true
    echo ""
    echo "  1) $($r && echo '关闭' || echo '开启(配置)')代理"
    echo "  2) $([ "${IP_WL_ON:-false}" = "true" ] && echo '关闭' || echo '开启')IP白名单"
    echo "  3) $([ "${DOMAIN_WL_ON:-false}" = "true" ] && echo '关闭' || echo '开启')域名白名单"
    echo "  4) 更新规则并重载配置"
    echo "  5) 更新 Gost 至最新版"
    echo "  0) 退出"
    echo ""
    printf "输入选项 [0-5]: "
}

run_ui() {
    init_env
    [ -f "$DOMAIN_WL_FILE" ] && [ -s "$DOMAIN_WL_FILE" ] || (download_whitelist &>/dev/null &)

    while true; do
        show_banner; show_menu
        IFS= read -r c
        case "${c}" in
            1) toggle_proxy            ; sleep 1.5 ; continue ;;
            2) toggle_ip_whitelist     ; sleep 1.5 ; continue ;;
            3) toggle_domain_whitelist ; sleep 1.5 ; continue ;;
            4) reload_proxy            ; sleep 1.5 ; continue ;;
            5) update_gost             ; continue ;;
            0) echo "已退出。"; exit 0 ;;
            *) continue ;;
        esac
    done
}

run_ui
