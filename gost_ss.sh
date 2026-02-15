#!/bin/bash

# ============================================================
#  GOST v3 - SOCKS5 → Shadowsocks 转发管理脚本
#  功能: 安装/卸载/配置/管理 GOST 转发服务
#  协议: SOCKS5 入站 → SS 出站 (TCP + UDP)
# ============================================================

# ---------- 颜色定义 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # 无颜色

# ---------- 路径定义 ----------
GOST_BIN="/usr/local/bin/gost"
SERVICE_FILE="/etc/systemd/system/gost-ss.service"
CONFIG_FILE="/etc/gost/config.yaml"
CONFIG_DIR="/etc/gost"

# ---------- 工具函数 ----------
print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║     GOST v3 SOCKS5 → SS 转发管理工具        ║"
    echo "║     支持 TCP + UDP 同时转发                  ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_info()    { echo -e "${GREEN}[信息]${NC} $1"; }
print_warn()    { echo -e "${YELLOW}[警告]${NC} $1"; }
print_error()   { echo -e "${RED}[错误]${NC} $1"; }
print_success() { echo -e "${GREEN}[成功]${NC} $1"; }

press_any_key() {
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo ""
}

print_entries() {
    for ((i=0; i<${#ss_ports[@]}; i++)); do
        local idx=$((i + 1))
        echo -e "  [${idx}] SS 密码:      ${GREEN}${ss_passwords[$i]}${NC}"
        echo -e "      加密方式:     ${GREEN}${ss_methods[$i]}${NC}"
        echo -e "      SS 监听端口:  ${GREEN}${ss_ports[$i]}${NC}"
        echo -e "      SOCKS5 地址:  ${GREEN}${socks5_addrs[$i]}${NC}"
        echo ""
    done
}

load_config_entries() {
    ss_passwords=()
    ss_methods=()
    ss_ports=()
    socks5_addrs=()

    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi

    local line reading=0
    local current_addr=""
    local current_method=""
    local current_password=""
    local current_socks5=""
    local trimmed=""

    while IFS= read -r line; do
        # 去除前后空白
        trimmed="$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

        # 检测 service name 行
        if [[ "$trimmed" == "- name: ss-forward-"*"-tcp" ]]; then
            reading=1
            current_addr=""
            current_method=""
            current_password=""
            current_socks5=""
            continue
        elif [[ "$trimmed" == "- name: ss-forward-"*"-udp" ]]; then
            reading=0
            continue
        elif [[ "$trimmed" == "- name:"* ]]; then
            reading=0
            continue
        fi

        if [[ $reading -eq 1 ]]; then
            # 匹配 addr: ":PORT"
            if [[ "$trimmed" == 'addr: ":'*'"' && -z "$current_addr" ]]; then
                current_addr="${trimmed#addr: \":}"
                current_addr="${current_addr%\"}"
            # 匹配 username: "METHOD"
            elif [[ "$trimmed" == 'username: "'*'"' ]]; then
                current_method="${trimmed#username: \"}"
                current_method="${current_method%\"}"
            # 匹配 password: "PASSWORD"
            elif [[ "$trimmed" == 'password: "'*'"' ]]; then
                current_password="${trimmed#password: \"}"
                current_password="${current_password%\"}"
            # 匹配 addr: "SOCKS5_ADDR" (不以冒号开头的 addr)
            elif [[ "$trimmed" == 'addr: "'*'"' && -n "$current_addr" ]]; then
                current_socks5="${trimmed#addr: \"}"
                current_socks5="${current_socks5%\"}"
            fi

            if [[ -n "$current_addr" && -n "$current_method" && -n "$current_password" && -n "$current_socks5" ]]; then
                ss_ports+=("$current_addr")
                ss_methods+=("$current_method")
                ss_passwords+=("$current_password")
                socks5_addrs+=("$current_socks5")
                reading=0
            fi
        fi
    done < "$CONFIG_FILE"

    return 0
}

choose_method() {
    local default_method="$1"
    echo ""
    echo -e "${CYAN}常用加密方式:${NC}"
    echo "  1) aes-128-gcm"
    echo "  2) aes-256-gcm"
    echo "  3) chacha20-ietf-poly1305"
    echo "  4) 自定义输入"
    echo ""
    if [[ -n "$default_method" ]]; then
        read -r -p "请选择加密方式 [1-4] (回车保持: ${default_method}): " method_choice
        if [[ -z "$method_choice" ]]; then
            ss_method="$default_method"
            return
        fi
    else
        read -r -p "请选择加密方式 [1-4] (默认: 3): " method_choice
    fi

    case "$method_choice" in
        1) ss_method="aes-128-gcm" ;;
        2) ss_method="aes-256-gcm" ;;
        3) ss_method="chacha20-ietf-poly1305" ;;
        4)
            read -r -p "请输入自定义加密方式: " ss_method
            if [[ -z "$ss_method" ]]; then
                ss_method="${default_method:-chacha20-ietf-poly1305}"
                print_warn "未输入，使用默认: ${ss_method}"
            fi
            ;;
        *) ss_method="${default_method:-chacha20-ietf-poly1305}" ;;
    esac
}

input_entry() {
    local default_password="$1"
    local default_method="$2"
    local default_port="$3"
    local default_socks5="$4"

    # SS 密码
    while true; do
        if [[ -n "$default_password" ]]; then
            read -r -p "请输入 SS 密码 [${default_password}]: " ss_password
            ss_password=${ss_password:-$default_password}
        else
            read -r -p "请输入 SS 密码: " ss_password
        fi
        if [[ -n "$ss_password" ]]; then
            break
        fi
        print_error "密码不能为空！"
    done

    # 加密方式
    choose_method "$default_method"

    # SS 监听端口
    while true; do
        if [[ -n "$default_port" ]]; then
            read -r -p "请输入 SS 监听端口 [${default_port}]: " ss_port
            ss_port=${ss_port:-$default_port}
        else
            read -r -p "请输入 SS 监听端口 (默认: 8388): " ss_port
            ss_port=${ss_port:-8388}
        fi
        if [[ "$ss_port" =~ ^[0-9]+$ ]] && [ "$ss_port" -ge 1 ] && [ "$ss_port" -le 65535 ]; then
            break
        fi
        print_error "端口号无效，请输入 1-65535 之间的数字！"
    done

    # SOCKS5 地址
    while true; do
        if [[ -n "$default_socks5" ]]; then
            read -r -p "请输入上游 SOCKS5 代理地址 [${default_socks5}]: " socks5_addr
            socks5_addr=${socks5_addr:-$default_socks5}
        else
            read -r -p "请输入上游 SOCKS5 代理地址 (如 127.0.0.1:1080): " socks5_addr
        fi
        if [[ -n "$socks5_addr" ]]; then
            break
        fi
        print_error "SOCKS5 地址不能为空！"
    done
}

# ---------- 检查 root 权限 ----------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "请使用 root 权限运行此脚本！"
        print_info "使用方法: sudo bash $0"
        exit 1
    fi
}

# ---------- 检测系统架构 ----------
get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        i686)    echo "386" ;;
        *)
            print_error "不支持的系统架构: $arch"
            exit 1
            ;;
    esac
}

# ---------- 检查 GOST 是否已安装 ----------
check_gost_installed() {
    if [[ -f "$GOST_BIN" ]]; then
        return 0
    else
        return 1
    fi
}

# ---------- 获取 GOST 版本 ----------
get_gost_version() {
    if check_gost_installed; then
        $GOST_BIN -V 2>&1 | head -n 1
    else
        echo "未安装"
    fi
}

# ---------- 下载安装 GOST v3 ----------
install_gost_binary() {
    if check_gost_installed; then
        local version
        version=$(get_gost_version)
        print_info "GOST 已安装: $version"
        echo ""
        read -r -p "是否重新安装/更新？[y/N]: " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            print_info "跳过安装 GOST 二进制文件"
            return 0
        fi
    fi

    # 检查依赖工具
    for cmd in curl tar gzip; do
        if ! command -v "$cmd" &>/dev/null; then
            print_error "缺少依赖工具: $cmd，请先安装"
            return 1
        fi
    done

    print_info "正在获取 GOST v3 最新版本信息..."

    # 获取最新版本号
    local latest_version
    latest_version=$(curl -sL --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/go-gost/gost/releases/latest" \
        | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')

    if [[ -z "$latest_version" ]]; then
        print_warn "无法从 GitHub API 获取版本信息，尝试备用方式..."
        latest_version=$(curl -sL --connect-timeout 10 --max-time 30 \
            -o /dev/null -w '%{redirect_url}' \
            "https://github.com/go-gost/gost/releases/latest" \
            | grep -oP 'tag/\K.*')
        if [[ -z "$latest_version" ]]; then
            print_error "无法获取最新版本信息，请检查网络连接"
            return 1
        fi
    fi

    print_info "最新版本: $latest_version"

    local arch
    arch=$(get_arch)
    local version_num="${latest_version#v}"
    local filename="gost_${version_num}_linux_${arch}.tar.gz"
    local download_url="https://github.com/go-gost/gost/releases/download/${latest_version}/${filename}"

    print_info "正在下载: $filename"
    print_info "下载地址: $download_url"

    # 创建临时目录
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local filepath="${tmp_dir}/${filename}"

    # 下载文件（使用 -L 跟随重定向，显示进度）
    if ! curl -L --connect-timeout 15 --max-time 300 --retry 3 --retry-delay 3 \
        -o "$filepath" --progress-bar "$download_url"; then
        print_error "下载失败，请检查网络连接"
        rm -rf "$tmp_dir"
        return 1
    fi

    # 验证下载的文件
    local filesize
    filesize=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null || echo "0")

    if [[ "$filesize" -lt 1000000 ]]; then
        print_error "下载的文件大小异常 (${filesize} bytes)，可能下载失败"
        print_warn "文件内容预览:"
        head -c 200 "$filepath" 2>/dev/null
        echo ""
        rm -rf "$tmp_dir"
        return 1
    fi

    print_info "文件大小: $(( filesize / 1024 / 1024 )) MB"

    # 验证文件是否为 gzip 格式
    if ! file "$filepath" 2>/dev/null | grep -qi "gzip\|compressed"; then
        # 备用检查：检查 gzip 魔数 (1f 8b)
        local magic
        magic=$(xxd -l 2 -p "$filepath" 2>/dev/null)
        if [[ "$magic" != "1f8b" ]]; then
            print_error "下载的文件不是有效的 gzip 格式"
            print_warn "文件头信息:"
            xxd -l 16 "$filepath" 2>/dev/null || head -c 50 "$filepath"
            echo ""
            rm -rf "$tmp_dir"
            return 1
        fi
    fi

    print_info "正在解压安装..."

    # 解压
    if ! tar -xzf "$filepath" -C "$tmp_dir" 2>&1; then
        print_error "解压失败"
        rm -rf "$tmp_dir"
        return 1
    fi

    # 查找 gost 可执行文件（可能在子目录中）
    local gost_file
    gost_file=$(find "$tmp_dir" -name "gost" -type f | head -n 1)

    if [[ -n "$gost_file" ]]; then
        mv "$gost_file" "$GOST_BIN"
        chmod +x "$GOST_BIN"
        print_success "GOST 安装成功: $GOST_BIN"
    else
        print_error "解压后未找到 gost 可执行文件"
        print_warn "解压目录内容:"
        ls -la "$tmp_dir"
        rm -rf "$tmp_dir"
        return 1
    fi

    # 清理临时文件
    rm -rf "$tmp_dir"

    # 验证安装
    local version
    version=$(get_gost_version)
    print_success "安装版本: $version"
    return 0
}

# ---------- 用户输入配置 ----------
input_config() {
    echo ""
    echo -e "${BOLD}${BLUE}========== 请输入转发配置 ==========${NC}"
    echo ""

    # 清空旧数组
    ss_passwords=()
    ss_methods=()
    ss_ports=()
    socks5_addrs=()

    local entry_index=1
    while true; do
        echo ""
        echo -e "${BOLD}${CYAN}--- 第 ${entry_index} 条转发 ---${NC}"

        input_entry "" "" "" ""

        ss_passwords+=("$ss_password")
        ss_methods+=("$ss_method")
        ss_ports+=("$ss_port")
        socks5_addrs+=("$socks5_addr")

        read -r -p "是否继续添加下一条转发？[Y/n]: " add_more
        if [[ "$add_more" == "n" || "$add_more" == "N" ]]; then
            break
        fi
        entry_index=$((entry_index + 1))
    done

    # 显示配置确认
    echo ""
    echo -e "${BOLD}${BLUE}========== 配置确认 ==========${NC}"
    print_entries
    echo -e "${BOLD}${BLUE}===============================${NC}"
    echo ""

    read -r -p "确认以上配置？[Y/n]: " confirm
    if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
        print_warn "已取消，请重新输入"
        return 1
    fi

    return 0
}

# ---------- 创建配置文件 ----------
create_config() {
    mkdir -p "$CONFIG_DIR"

    cat > "$CONFIG_FILE" <<EOF
# GOST v3 配置文件 - SOCKS5 → Shadowsocks 转发
# 自动生成，请勿手动修改（可通过脚本修改配置菜单修改）

services:
EOF

    for ((i=0; i<${#ss_ports[@]}; i++)); do
        local idx=$((i + 1))
        cat >> "$CONFIG_FILE" <<EOF
  - name: ss-forward-${idx}-tcp
    addr: ":${ss_ports[$i]}"
    handler:
      type: ss
      auth:
        username: "${ss_methods[$i]}"
        password: "${ss_passwords[$i]}"
    listener:
      type: tcp
    forwarder:
      nodes:
        - name: socks5-upstream-${idx}-tcp
          addr: "${socks5_addrs[$i]}"
          connector:
            type: socks5

  - name: ss-forward-${idx}-udp
    addr: ":${ss_ports[$i]}"
    handler:
      type: ss
      auth:
        username: "${ss_methods[$i]}"
        password: "${ss_passwords[$i]}"
    listener:
      type: udp
    forwarder:
      nodes:
        - name: socks5-upstream-${idx}-udp
          addr: "${socks5_addrs[$i]}"
          connector:
            type: socks5
EOF
    done

    print_success "配置文件已创建: $CONFIG_FILE"
}

# ---------- 创建 Systemd 服务 ----------
create_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GOST v3 SOCKS5 to Shadowsocks Forwarding Service
Documentation=https://gost.run
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${GOST_BIN} -C "$CONFIG_FILE"
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    print_success "服务文件已创建: $SERVICE_FILE"

    # 重新加载 systemd
    systemctl daemon-reload
}

# ---------- 安装完整流程 ----------
do_install() {
    print_banner
    echo -e "${BOLD}${GREEN}[ 安装 GOST 并配置转发 ]${NC}"
    echo ""

    # 步骤1: 安装 GOST 二进制文件
    print_info "步骤 1/4: 安装 GOST..."
    if ! install_gost_binary; then
        print_error "GOST 安装失败！"
        press_any_key
        return
    fi

    # 步骤2: 用户输入配置
    echo ""
    print_info "步骤 2/4: 配置转发参数..."
    while true; do
        if input_config; then
            break
        fi
    done

    # 步骤3: 创建配置文件和服务文件
    echo ""
    print_info "步骤 3/4: 创建配置文件和系统服务..."
    create_config
    create_service

    # 步骤4: 启用并启动服务
    echo ""
    print_info "步骤 4/4: 启用开机自启并启动服务..."
    systemctl enable gost-ss.service 2>/dev/null
    print_success "已设置开机自启"

    systemctl start gost-ss.service
    sleep 1

    if systemctl is-active --quiet gost-ss.service; then
        print_success "GOST 转发服务已启动！"
        echo ""
        echo -e "${BOLD}${GREEN}========== 安装完成 ==========${NC}"
        echo -e "  SS 连接信息:"
        for ((i=0; i<${#ss_ports[@]}; i++)); do
            local idx=$((i + 1))
            echo -e "  [${idx}] 地址:     ${CYAN}服务器IP:${ss_ports[$i]}${NC}"
            echo -e "      密码:     ${CYAN}${ss_passwords[$i]}${NC}"
            echo -e "      加密方式: ${CYAN}${ss_methods[$i]}${NC}"
            echo -e "      协议:     ${CYAN}TCP + UDP${NC}"
        done
        echo -e "${BOLD}${GREEN}===============================${NC}"
    else
        print_error "服务启动失败，请查看日志:"
        echo -e "${YELLOW}  journalctl -u gost-ss.service -n 20${NC}"
    fi

    press_any_key
}

# ---------- 卸载完整流程 ----------
do_uninstall() {
    print_banner
    echo -e "${BOLD}${RED}[ 卸载 GOST ]${NC}"
    echo ""

    if ! check_gost_installed && [[ ! -f "$SERVICE_FILE" ]]; then
        print_warn "GOST 未安装，无需卸载"
        press_any_key
        return
    fi

    echo -e "${RED}${BOLD}警告: 此操作将完全卸载 GOST，包括:${NC}"
    echo -e "  - 停止并禁用 gost-ss 服务"
    echo -e "  - 删除服务文件: $SERVICE_FILE"
    echo -e "  - 删除二进制文件: $GOST_BIN"
    echo -e "  - 删除配置目录: $CONFIG_DIR"
    echo ""

    read -r -p "确认卸载？请输入 'yes' 确认: " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_info "已取消卸载"
        press_any_key
        return
    fi

    echo ""

    # 停止服务
    if systemctl is-active --quiet gost-ss.service 2>/dev/null; then
        print_info "正在停止服务..."
        systemctl stop gost-ss.service
        print_success "服务已停止"
    fi

    # 禁用开机自启
    if systemctl is-enabled --quiet gost-ss.service 2>/dev/null; then
        print_info "正在禁用开机自启..."
        systemctl disable gost-ss.service 2>/dev/null
        print_success "已禁用开机自启"
    fi

    # 删除服务文件
    if [[ -f "$SERVICE_FILE" ]]; then
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        print_success "服务文件已删除: $SERVICE_FILE"
    fi

    # 删除二进制文件
    if [[ -f "$GOST_BIN" ]]; then
        rm -f "$GOST_BIN"
        print_success "二进制文件已删除: $GOST_BIN"
    fi

    # 删除配置文件目录
    if [[ -d "$CONFIG_DIR" ]]; then
        rm -rf "$CONFIG_DIR"
        print_success "配置目录已删除: $CONFIG_DIR"
    fi

    echo ""
    print_success "GOST 已完全卸载！"

    press_any_key
}

# ---------- 查看服务状态 ----------
do_status() {
    print_banner
    echo -e "${BOLD}${BLUE}[ 服务状态 ]${NC}"
    echo ""

    # GOST 安装状态
    if check_gost_installed; then
        local version
        version=$(get_gost_version)
        echo -e "  GOST 安装状态: ${GREEN}已安装${NC} ($version)"
    else
        echo -e "  GOST 安装状态: ${RED}未安装${NC}"
        press_any_key
        return
    fi

    # 服务状态
    if [[ -f "$SERVICE_FILE" ]]; then
        echo -e "  服务文件:      ${GREEN}已配置${NC}"

        local status
        status=$(systemctl is-active gost-ss.service 2>/dev/null)
        if [[ "$status" == "active" ]]; then
            echo -e "  运行状态:      ${GREEN}运行中${NC}"
        else
            echo -e "  运行状态:      ${RED}已停止${NC}"
        fi

        local enabled
        enabled=$(systemctl is-enabled gost-ss.service 2>/dev/null)
        if [[ "$enabled" == "enabled" ]]; then
            echo -e "  开机自启:      ${GREEN}已启用${NC}"
        else
            echo -e "  开机自启:      ${YELLOW}未启用${NC}"
        fi
    else
        echo -e "  服务文件:      ${RED}未配置${NC}"
    fi

    # 显示当前配置
    if [[ -f "$CONFIG_FILE" ]]; then
        if load_config_entries; then
            echo ""
            echo -e "${BOLD}${BLUE}[ 当前转发配置 ]${NC}"
            if [[ ${#ss_ports[@]} -eq 0 ]]; then
                echo -e "  ${YELLOW}(未检测到转发条目)${NC}"
            else
                for ((i=0; i<${#ss_ports[@]}; i++)); do
                    local idx=$((i + 1))
                    echo -e "  [${idx}] SS 端口:      ${CYAN}${ss_ports[$i]}${NC}"
                    echo -e "      SS 密码:      ${CYAN}${ss_passwords[$i]}${NC}"
                    echo -e "      加密方式:     ${CYAN}${ss_methods[$i]}${NC}"
                    echo -e "      SOCKS5 上游:  ${CYAN}${socks5_addrs[$i]}${NC}"
                    echo ""
                done
            fi
        fi
    fi

    echo ""
    echo -e "${BOLD}${BLUE}[ 最近日志 ]${NC}"
    journalctl -u gost-ss.service -n 5 --no-pager 2>/dev/null || echo "  (无日志)"

    press_any_key
}

# ---------- 重启服务 ----------
do_restart() {
    print_banner
    echo -e "${BOLD}${BLUE}[ 重启服务 ]${NC}"
    echo ""

    if [[ ! -f "$SERVICE_FILE" ]]; then
        print_error "服务未配置，请先安装！"
        press_any_key
        return
    fi

    print_info "正在重启 gost-ss 服务..."
    systemctl restart gost-ss.service
    sleep 1

    if systemctl is-active --quiet gost-ss.service; then
        print_success "服务已成功重启！"
    else
        print_error "服务重启失败，请查看日志:"
        echo -e "${YELLOW}  journalctl -u gost-ss.service -n 20${NC}"
    fi

    press_any_key
}

# ---------- 停止服务 ----------
do_stop() {
    print_banner
    echo -e "${BOLD}${YELLOW}[ 停止服务 ]${NC}"
    echo ""

    if [[ ! -f "$SERVICE_FILE" ]]; then
        print_error "服务未配置，请先安装！"
        press_any_key
        return
    fi

    if ! systemctl is-active --quiet gost-ss.service; then
        print_warn "服务当前未运行"
        press_any_key
        return
    fi

    print_info "正在停止 gost-ss 服务..."
    systemctl stop gost-ss.service
    print_success "服务已停止"

    press_any_key
}

# ---------- 修改配置 ----------
do_modify() {
    print_banner
    echo -e "${BOLD}${BLUE}[ 修改配置 ]${NC}"
    echo ""

    if [[ ! -f "$SERVICE_FILE" ]]; then
        print_error "服务未配置，请先安装！"
        press_any_key
        return
    fi

    if ! load_config_entries; then
        print_warn "未检测到现有配置，进入新增配置流程"
        while true; do
            if input_config; then
                break
            fi
        done
    else
        while true; do
            print_banner
            echo -e "${BOLD}${BLUE}[ 修改配置 ]${NC}"
            echo ""
            echo -e "${BOLD}${BLUE}当前转发条目:${NC}"
            if [[ ${#ss_ports[@]} -eq 0 ]]; then
                echo -e "  ${YELLOW}(暂无转发条目)${NC}"
            else
                print_entries
            fi

            echo -e "${GREEN}1)${NC} 修改已有转发"
            echo -e "${CYAN}2)${NC} 增加转发"
            echo -e "${RED}3)${NC} 删除转发"
            echo -e "${NC}0)${NC} 保存并返回"
            echo ""

            read -r -p "请选择操作 [0-3]: " modify_choice
            case "$modify_choice" in
                1)
                    if [[ ${#ss_ports[@]} -eq 0 ]]; then
                        print_warn "当前没有可修改的转发"
                        press_any_key
                        continue
                    fi
                    read -r -p "请输入要修改的序号 [1-${#ss_ports[@]}]: " edit_index
                    if [[ ! "$edit_index" =~ ^[0-9]+$ ]] || [ "$edit_index" -lt 1 ] || [ "$edit_index" -gt ${#ss_ports[@]} ]; then
                        print_error "序号无效"
                        press_any_key
                        continue
                    fi
                    local idx=$((edit_index - 1))
                    echo ""
                    echo -e "${BOLD}${CYAN}--- 修改第 ${edit_index} 条转发 ---${NC}"
                    input_entry "${ss_passwords[$idx]}" "${ss_methods[$idx]}" "${ss_ports[$idx]}" "${socks5_addrs[$idx]}"
                    ss_passwords[$idx]="$ss_password"
                    ss_methods[$idx]="$ss_method"
                    ss_ports[$idx]="$ss_port"
                    socks5_addrs[$idx]="$socks5_addr"
                    print_success "已更新第 ${edit_index} 条转发"
                    press_any_key
                    ;;
                2)
                    echo ""
                    echo -e "${BOLD}${CYAN}--- 新增转发 ---${NC}"
                    input_entry "" "" "" ""
                    ss_passwords+=("$ss_password")
                    ss_methods+=("$ss_method")
                    ss_ports+=("$ss_port")
                    socks5_addrs+=("$socks5_addr")
                    print_success "已新增转发"
                    press_any_key
                    ;;
                3)
                    if [[ ${#ss_ports[@]} -eq 0 ]]; then
                        print_warn "当前没有可删除的转发"
                        press_any_key
                        continue
                    fi
                    read -r -p "请输入要删除的序号 [1-${#ss_ports[@]}]: " del_index
                    if [[ ! "$del_index" =~ ^[0-9]+$ ]] || [ "$del_index" -lt 1 ] || [ "$del_index" -gt ${#ss_ports[@]} ]; then
                        print_error "序号无效"
                        press_any_key
                        continue
                    fi
                    local del_pos=$((del_index - 1))
                    unset 'ss_passwords[del_pos]'
                    unset 'ss_methods[del_pos]'
                    unset 'ss_ports[del_pos]'
                    unset 'socks5_addrs[del_pos]'
                    ss_passwords=("${ss_passwords[@]}")
                    ss_methods=("${ss_methods[@]}")
                    ss_ports=("${ss_ports[@]}")
                    socks5_addrs=("${socks5_addrs[@]}")
                    print_success "已删除第 ${del_index} 条转发"
                    press_any_key
                    ;;
                0)
                    break
                    ;;
                *)
                    print_error "无效选择"
                    press_any_key
                    ;;
            esac
        done
    fi

    if [[ ${#ss_ports[@]} -eq 0 ]]; then
        print_warn "当前没有转发条目，未生成配置"
        press_any_key
        return
    fi

    echo ""
    echo -e "${BOLD}${BLUE}========== 修改后配置确认 ==========${NC}"
    print_entries
    echo -e "${BOLD}${BLUE}===============================${NC}"
    echo ""
    read -r -p "确认保存并重启服务？[Y/n]: " confirm
    if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
        print_info "已取消修改"
        press_any_key
        return
    fi

    # 更新配置文件和服务文件
    create_config
    create_service

    # 重启服务
    print_info "正在重启服务以应用新配置..."
    systemctl restart gost-ss.service
    sleep 1

    if systemctl is-active --quiet gost-ss.service; then
        print_success "配置已更新，服务已重启！"
    else
        print_error "服务重启失败，请查看日志"
    fi

    press_any_key
}

# ---------- 主菜单 ----------
show_menu() {
    print_banner

    # 显示简要状态
    if check_gost_installed; then
        local status_text
        if systemctl is-active --quiet gost-ss.service 2>/dev/null; then
            status_text="${GREEN}● 运行中${NC}"
        elif [[ -f "$SERVICE_FILE" ]]; then
            status_text="${RED}● 已停止${NC}"
        else
            status_text="${YELLOW}● 已安装但未配置${NC}"
        fi
        echo -e "  状态: $status_text"
    else
        echo -e "  状态: ${YELLOW}● 未安装${NC}"
    fi
    echo ""

    echo -e "  ${GREEN}1)${NC} 安装 GOST 并配置转发"
    echo -e "  ${RED}2)${NC} 卸载 GOST（移除所有配置）"
    echo -e "  ${BLUE}3)${NC} 查看服务状态"
    echo -e "  ${CYAN}4)${NC} 重启服务"
    echo -e "  ${YELLOW}5)${NC} 停止服务"
    echo -e "  ${BLUE}6)${NC} 修改配置"
    echo -e "  ${NC}0)${NC} 退出"
    echo ""

    read -r -p "请选择操作 [0-6]: " choice
}

# ---------- 主入口 ----------
main() {
    check_root

    while true; do
        show_menu
        case "$choice" in
            1) do_install ;;
            2) do_uninstall ;;
            3) do_status ;;
            4) do_restart ;;
            5) do_stop ;;
            6) do_modify ;;
            0)
                echo ""
                print_info "再见！"
                exit 0
                ;;
            *)
                print_error "无效选择，请输入 0-6"
                sleep 1
                ;;
        esac
    done
}

# 启动脚本
main
