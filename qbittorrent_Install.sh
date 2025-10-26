#!/bin/bash
set -o pipefail

# --- 全局变量 ---
BINARY_PATH="/usr/bin/qbittorrent-nox"
SERVICE_FILE="/etc/systemd/system/qbittorrent-nox.service"
# 使用您指定的 x86_64 静态编译版
DOWNLOAD_URL="https://github.com/userdocs/qbittorrent-nox-static/releases/latest/download/x86_64-qbittorrent-nox"

# --- 日志函数 (要求1：INFO级别) ---
log_info() {
    echo "[INFO] $1"
}

log_warn() {
    echo "[WARN] $1"
}

log_error() {
    echo "[ERROR] $1"
}

# --- 辅助函数 ---

# 检查是否为 root 用户
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "此脚本必须以 root 用户身份运行。"
        echo "请尝试使用: sudo $0"
        exit 1
    fi
}

# 1. 检测操作系统 (要求2)
detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_NAME=$PRETTY_NAME
        log_info "检测到当前系统: $OS_NAME"
    else
        log_warn "无法从 /etc/os-release 检测到操作系统。"
        OS_NAME="未知"
    fi
}

# 2. 检查安装状态和版本 (要求2)
check_install_status() {
    if [ -f "$BINARY_PATH" ]; then
        # 尝试获取版本号
        INSTALLED_VERSION=$($BINARY_PATH --version 2>/dev/null | head -n 1)
        if [ -z "$INSTALLED_VERSION" ]; then
            INSTALLED_VERSION="已安装 (版本未知)"
        fi
        return 0 # 0 表示已安装
    else
        INSTALLED_VERSION="未安装"
        return 1 # 1 表示未安装
    fi
}

# 3. 检查前置依赖 (要求3)
check_dependencies() {
    log_info "正在检查所需依赖..."
    # 根据您的需求，检查 wget。systemctl 和 cat 通常是内建的。
    local missing_deps=0
    local deps=("wget" "systemctl")

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            log_error "缺少关键依赖: $dep。请先安装它。"
            missing_deps=1
        fi
    done

    if [ $missing_deps -eq 1 ]; then
        log_error "依赖检查失败，脚本终止。"
        exit 1
    fi
    log_info "依赖检查通过。"
}

# 4. 获取最新版本号
get_latest_version() {
    local release_url="https://github.com/userdocs/qbittorrent-nox-static/releases/latest"
    local latest_tag=""

    if command -v curl &>/dev/null; then
        latest_tag=$(curl -sSL -o /dev/null -w %{url_effective} "$release_url" | grep -oP 'tag/\K[^/]+$')
    elif command -v wget &>/dev/null; then
        local redirect_url
        redirect_url=$(wget -nv --server-response --spider "$release_url" 2>&1 | grep -i Location: | tail -1 | awk '{print $2}')
        latest_tag=$(echo "$redirect_url" | grep -oP 'tag/\K[^/]+$')
    else
        log_error "无法获取最新版本号，缺少 'curl' 或 'wget'。"
        return 1
    fi

    if [ -n "$latest_tag" ]; then
        # 1. 移除可能的前缀 "release-" 或 "v"
        local clean_version=$(echo "$latest_tag" | sed 's/release-//g; s/v//g')
        
        # 2. 移除第一个下划线 "_" 及其之后的所有内容 (例如: "5.1.2_v2.0.11" -> "5.1.2")
        local final_version=$(echo "$clean_version" | cut -d '_' -f 1)

        # 3. 添加 "v" 前缀以匹配本地版本格式 (例如: "5.1.2" -> "v5.1.2")
        LATEST_VERSION="v$final_version"
        
        log_info "最新版本为: $LATEST_VERSION"
        return 0
    else
        log_warn "无法解析 GitHub 的最新版本标签。"
        LATEST_VERSION="未知"
        return 1
    fi
}

# --- 核心功能函数 ---

# 下载并安装二进制文件
install_binary() {
    log_info "正在从 GitHub 下载最新的 qbittorrent-nox..."
    # 使用您提供的 wget 参数
    if ! wget -c "$DOWNLOAD_URL" -O "$BINARY_PATH"; then
        log_error "下载失败。请检查网络连接或 URL 是否有效。"
        return 1
    fi

    log_info "正在设置文件权限..."
    # 使用您提供的 chmod 参数
    chmod 700 "$BINARY_PATH"
    log_info "二进制文件已更新/安装至 $BINARY_PATH"
    return 0
}

# 创建 systemd 服务文件 (要求4)
create_service_file() {
    # 检查文件是否存在
    if [ -f "$SERVICE_FILE" ]; then
        read -p "[WARN] systemd 服务文件 ($SERVICE_FILE) 已存在。是否覆盖? (y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            log_info "已跳过创建服务文件。"
            return
        fi
    fi

    log_info "正在创建 systemd 服务文件..."
    # 使用您提供的 cat 配置
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=qBittorrent-nox
After=network.target
[Service]
User=root
Type=forking
RemainAfterExit=yes
ExecStart=/usr/bin/qbittorrent-nox -d
[Install]
WantedBy=multi-user.target
EOF

    log_info "服务文件创建成功。"
    log_info "正在重载 systemd..."
    systemctl daemon-reload
}

# --- 菜单功能 ---

# 4. 安装
do_install() {
    log_info "--- 开始安装 qbittorrent-nox ---"
    if check_install_status; then
        log_warn "qbittorrent-nox ($INSTALLED_VERSION) 已经安装。"
        log_info "请使用 [更新] 功能（如果需要）。"
        return
    fi

    if install_binary; then
        create_service_file
        log_info "安装完成。"
        log_info "请注意：首次运行需自行获取密码 /usr/bin/qbittorrent-nox。"
        log_info "使用 '管理开机自启' 和 'systemd 服务控制' 启动服务。"
    else
        log_error "安装过程中发生错误。"
    fi
}

# 4. 更新
do_update() {
    log_info "--- 开始更新 qbittorrent-nox ---"
    if ! check_install_status; then
        log_warn "qbittorrent-nox 未安装。请先使用 [安装] 功能。"
        return
    fi
    
    log_info "已安装版本: $INSTALLED_VERSION"
    
    # 尝试获取最新版本
    if ! get_latest_version; then
        log_warn "版本检测失败。出于安全考虑，建议手动检查或稍后重试。"
        # 即使无法获取版本，也询问用户是否强制更新
        read -p "无法获取最新版本，是否强制更新程序文件? (y/n): " force_update
        if [[ "$force_update" != "y" && "$force_update" != "Y" ]]; then
            log_info "更新已取消。"
            return
        fi
    fi

    # 检查版本差异
    # 简单字符串对比，如果版本号格式一致，通常有效
    if [ "$INSTALLED_VERSION" = "v$LATEST_VERSION" ] || [ "$INSTALLED_VERSION" = "$LATEST_VERSION" ]; then
        log_info "本地版本与最新版本 ($LATEST_VERSION) 一致。"
        read -p "是否仍然强制下载和覆盖? (y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            log_info "更新已取消。"
            return
        fi
    fi

    log_info "正在停止当前服务（如果正在运行）..."
    systemctl stop qbittorrent-nox

    if install_binary; then
        log_info "更新完成。建议您使用 'systemd 服务控制' 菜单重新启动服务。"
    else
        log_error "更新过程中发生错误。"
    fi
}

# 4. 卸载
do_uninstall() {
    log_info "--- 开始卸载 qbittorrent-nox ---"
    if ! check_install_status; then
        log_warn "qbittorrent-nox 未安装，无需卸载。"
        return
    fi

    read -p "[WARN] 这将彻底删除 qb-nox 程序和服务文件。确认卸载? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "卸载已取消。"
        return
    fi

    log_info "正在停止服务..."
    systemctl stop qbittorrent-nox

    log_info "正在移除开机自启..."
    systemctl disable qbittorrent-nox 2>/dev/null

    log_info "正在删除 systemd 服务文件..."
    rm -f "$SERVICE_FILE"

    log_info "正在删除程序文件..."
    # 使用您提供的 rm 命令 (rm -r 改为 rm -f，因为目标是文件)
    rm -f "$BINARY_PATH"

    log_info "正在重载 systemd..."
    systemctl daemon-reload

    log_info "卸载完成。"
}

# 4. 管理开机自启
manage_autostart() {
    if ! [ -f "$SERVICE_FILE" ]; then
        log_warn "systemd 服务文件 ($SERVICE_FILE) 不存在。"
        log_warn "请先 [安装] 服务。"
        return
    fi

    clear
    echo "--- 管理开机自启 ---"
    echo " 1. 添加开机自启 (Enable)"
    echo " 2. 移除开机自启 (Disable)"
    echo "---------------------"
    echo " 0. 返回"
    echo "---------------------"
    read -p "请输入选项 [0-2]: " choice

    case $choice in
        1)
            log_info "正在添加开机自启..."
            systemctl enable qbittorrent-nox
            log_info "操作完成。"
            ;;
        2)
            log_info "正在移除开机自启..."
            systemctl disable qbittorrent-nox
            log_info "操作完成。"
            ;;
        0)
            return
            ;;
        *)
            log_warn "无效选项。"
            ;;
    esac
}

# 5. systemd 服务控制 (子列表)
manage_service() {
    if ! [ -f "$SERVICE_FILE" ]; then
        log_warn "systemd 服务文件 ($SERVICE_FILE) 不存在。"
        log_warn "请先 [安装] 服务。"
        return
    fi

    # 循环显示子菜单，直到用户选择返回
    while true; do
        clear
        echo "--- systemd 服务控制 (子菜单) ---"
        echo " 1. 启动 (Start)"
        echo " 2. 停止 (Stop)"
        echo " 3. 重启 (Restart)"
        echo " 4. 查看状态 (Status)"
        echo "--------------------------------"
        echo " 0. 返回"
        echo "--------------------------------"
        read -p "请输入选项 [0-4]: " sub_choice

        case $sub_choice in
            1)
                log_info "正在启动服务..."
                systemctl start qbittorrent-nox
                ;;
            2)
                log_info "正在停止服务..."
                systemctl stop qbittorrent-nox
                ;;
            3)
                log_info "正在重启服务..."
                systemctl restart qbittorrent-nox
                ;;
            4)
                log_info "正在显示服务状态 (按 'q' 退出状态视图)..."
                systemctl status qbittorrent-nox
                read -p "按任意键继续..." -n 1 -r
                ;;
            0)
                break
                ;;
            *)
                log_warn "无效选项。"
                sleep 1
                ;;
        esac
        # 如果不是查看状态或返回，暂停一下显示操作结果
        if [[ "$sub_choice" -ge 1 && "$sub_choice" -le 3 ]]; then
            sleep 1
        fi
    done
}

# --- 主菜单 ---
main_menu() {
    while true; do
        # 实时更新安装状态 (要求2)
        check_install_status
        
        clear
        echo "================================================="
        echo "     qbittorrent-nox (Static) 一键管理脚本"
        echo "================================================="
        echo " [系统信息]"
        echo "   操作系统: $OS_NAME"
        echo "   qbit状态: $INSTALLED_VERSION"
        echo "-------------------------------------------------"
        echo " [主菜单]"
        echo "   1. 安装 qbittorrent-nox"
        echo "   2. 更新 qbittorrent-nox"
        echo "   3. 卸载 qbittorrent-nox"
        echo "   4. 管理开机自启"
        echo "   5. systemd 服务控制"
        echo "-------------------------------------------------"
        echo "   0. 退出脚本"
        echo "-------------------------------------------------"
        read -p "请输入选项 [0-5]: " main_choice

        case $main_choice in
            1)
                do_install
                ;;
            2)
                do_update
                ;;
            3)
                do_uninstall
                ;;
            4)
                manage_autostart
                ;;
            5)
                manage_service
                ;;
            [0])
                log_info "退出脚本。"
                exit 0
                ;;
            *)
                log_warn "无效选项，请重新输入。"
                ;;
        esac
        
        # 每次操作后暂停，以便用户查看日志
        if [[ "$main_choice" -ge 1 && "$main_choice" -le 4 ]]; then
             read -p "按任意键返回主菜单..." -n 1 -r
        fi
    done
}

# --- 脚本入口 ---
# 1. 检查Root权限
check_root

# 2. 执行预检查
detect_os
check_dependencies

# 3. 显示主菜单
main_menu
