#!/bin/bash

# ============================================
#  IP 监控脚本 一键管理工具
#  功能：安装/卸载 ip_monitor.sh 脚本
#        创建/移除 定时任务
# ============================================

# 脚本下载地址
DOWNLOAD_URL="https://raw.githubusercontent.com/Bluepants94/script/refs/heads/main/ip_monitor.sh"

# 安装路径
INSTALL_DIR="/opt/ip_monitor"
SCRIPT_PATH="${INSTALL_DIR}/ip_monitor.sh"

# Crontab 标记（用于识别定时任务）
CRON_TAG="# ip_monitor_task"
CRON_JOB="*/5 * * * * ${SCRIPT_PATH} >> ${INSTALL_DIR}/ip_monitor.log 2>&1 ${CRON_TAG}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # 无颜色

# 打印带颜色的信息
info()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; }
header()  { echo -e "${CYAN}$1${NC}"; }

# 检查 root 权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "请使用 root 用户运行此脚本"
        exit 1
    fi
}

# 1. 下载安装脚本
install_script() {
    header "========== 安装 IP 监控脚本 =========="

    if [ -f "$SCRIPT_PATH" ]; then
        warn "脚本已存在：${SCRIPT_PATH}"
        read -p "是否覆盖安装？(y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            warn "取消安装"
            return
        fi
    fi

    # 创建安装目录
    mkdir -p "$INSTALL_DIR"

    # 下载脚本
    echo "正在下载脚本..."
    if curl -sL --fail -o "$SCRIPT_PATH" "$DOWNLOAD_URL"; then
        chmod +x "$SCRIPT_PATH"
        info "脚本下载成功：${SCRIPT_PATH}"
        echo ""
        warn "请编辑脚本配置以下信息："
        echo "  - SERVER_NAME（服务器名称）"
        echo "  - TG_BOT_TOKEN（Telegram Bot Token）"
        echo "  - TG_CHAT_ID（Telegram Chat ID）"
        echo ""
        echo "  编辑命令：nano ${SCRIPT_PATH}"
    else
        error "脚本下载失败，请检查网络连接"
        rm -f "$SCRIPT_PATH"
    fi
}

# 2. 卸载脚本
uninstall_script() {
    header "========== 卸载 IP 监控脚本 =========="

    # 先移除定时任务
    remove_cron_quiet

    if [ -d "$INSTALL_DIR" ]; then
        read -p "确认删除 ${INSTALL_DIR} 及所有相关文件？(y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            rm -rf "$INSTALL_DIR"
            info "已删除脚本目录：${INSTALL_DIR}"
        else
            warn "取消卸载"
        fi
    else
        warn "脚本未安装，无需卸载"
    fi
}

# 3. 创建定时任务
create_cron() {
    header "========== 创建定时任务（每5分钟）=========="

    if [ ! -f "$SCRIPT_PATH" ]; then
        error "脚本未安装，请先安装脚本"
        return
    fi

    # 检查是否已存在
    if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
        warn "定时任务已存在，无需重复创建"
        return
    fi

    # 添加定时任务
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    info "定时任务创建成功（每5分钟检测一次）"
    echo "  任务内容：${CRON_JOB}"
}

# 4. 移除定时任务
remove_cron() {
    header "========== 移除定时任务 =========="
    remove_cron_quiet
}

# 静默移除定时任务（卸载时调用）
remove_cron_quiet() {
    if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
        crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
        info "定时任务已移除"
    else
        warn "未找到相关定时任务"
    fi
}

# 显示当前状态
show_status() {
    echo ""
    header "========== 当前状态 =========="
    if [ -f "$SCRIPT_PATH" ]; then
        info "脚本状态：已安装 (${SCRIPT_PATH})"
    else
        error "脚本状态：未安装"
    fi

    if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
        info "定时任务：已启用"
    else
        error "定时任务：未启用"
    fi
    echo ""
}

# 主菜单
show_menu() {
    clear
    header "╔══════════════════════════════════════╗"
    header "║     IP 监控脚本 一键管理工具         ║"
    header "╚══════════════════════════════════════╝"
    show_status
    echo "  1) 安装脚本"
    echo "  2) 卸载脚本"
    echo "  3) 创建定时任务（每5分钟）"
    echo "  4) 移除定时任务"
    echo "  5) 编辑脚本配置"
    echo "  0) 退出"
    echo ""
    read -p "请选择操作 [0-5]: " choice

    case "$choice" in
        1) install_script ;;
        2) uninstall_script ;;
        3) create_cron ;;
        4) remove_cron ;;
        5)
            if [ -f "$SCRIPT_PATH" ]; then
                nano "$SCRIPT_PATH"
            else
                error "脚本未安装，请先安装"
            fi
            ;;
        0)
            echo "再见！"
            exit 0
            ;;
        *)
            error "无效选择"
            ;;
    esac

    echo ""
    read -p "按 Enter 返回菜单..." _
    show_menu
}

# 入口
check_root
show_menu
