#!/bin/bash

# ==============================
#  Proxychains4 临时代理管理脚本
# ==============================

CONF_FILE="/tmp/proxychains_temp.conf"
PROXY_TYPE=""
PROXY_HOST=""
PROXY_PORT=""
CONFIGURED=false

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 清理函数 - 退出时自动清理配置文件
cleanup() {
    if [ -f "$CONF_FILE" ]; then
        rm -f "$CONF_FILE"
        echo ""
        echo -e "${YELLOW}[INFO]${NC} 临时配置文件已清理: $CONF_FILE"
    fi
    echo -e "${GREEN}再见！${NC}"
    exit 0
}

# 捕获退出信号，确保清理
trap cleanup EXIT INT TERM

# 生成 proxychains4 配置文件
generate_config() {
    cat > "$CONF_FILE" << EOF
# Proxychains4 临时配置文件
# 自动生成于: $(date)

strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000

[ProxyList]
$PROXY_TYPE $PROXY_HOST $PROXY_PORT
EOF
}

# 显示菜单
show_menu() {
    echo ""
    echo -e "${CYAN}==============================${NC}"
    echo -e "${CYAN}  Proxychains4 临时代理管理${NC}"
    echo -e "${CYAN}==============================${NC}"
    if $CONFIGURED; then
        echo -e "  当前代理: ${GREEN}${PROXY_TYPE}://${PROXY_HOST}:${PROXY_PORT}${NC}"
    else
        echo -e "  当前代理: ${RED}未配置${NC}"
    fi
    echo -e "${CYAN}------------------------------${NC}"
    echo "  1) 配置并启动代理"
    echo "  2) 使用代理运行命令"
    echo "  3) 查看当前代理状态"
    echo "  4) 关闭代理并清理配置"
    echo "  5) 退出"
    echo -e "${CYAN}------------------------------${NC}"
    echo -n "  请选择 [1-5]: "
}

# 配置代理
configure_proxy() {
    echo ""
    echo -e "${CYAN}--- 配置代理 ---${NC}"
    echo ""
    echo "  请选择代理类型:"
    echo "    1) http"
    echo "    2) socks4"
    echo "    3) socks5"
    echo -n "  请选择 [1-3] (默认: 1): "
    read -r type_choice

    case "$type_choice" in
        2) PROXY_TYPE="socks4" ;;
        3) PROXY_TYPE="socks5" ;;
        *) PROXY_TYPE="http" ;;
    esac

    echo -n "  请输入代理服务器地址 (默认: 127.0.0.1): "
    read -r host_input
    PROXY_HOST="${host_input:-127.0.0.1}"

    echo -n "  请输入代理端口 (默认: 7890): "
    read -r port_input
    PROXY_PORT="${port_input:-7890}"

    # 生成配置文件
    generate_config
    CONFIGURED=true

    echo ""
    echo -e "${GREEN}[OK]${NC} 代理配置成功！"
    echo -e "  类型: ${YELLOW}${PROXY_TYPE}${NC}"
    echo -e "  地址: ${YELLOW}${PROXY_HOST}${NC}"
    echo -e "  端口: ${YELLOW}${PROXY_PORT}${NC}"
    echo -e "  配置文件: ${YELLOW}${CONF_FILE}${NC}"
    echo ""
    echo -e "${GREEN}[提示]${NC} 现在可以选择 '2) 使用代理运行命令' 来测试代理"
}

# 使用代理运行命令
run_with_proxy() {
    if ! $CONFIGURED; then
        echo ""
        echo -e "${RED}[错误]${NC} 请先配置代理（选择选项 1）"
        return
    fi

    # 检查 proxychains4 是否安装
    if ! command -v proxychains4 &> /dev/null; then
        echo ""
        echo -e "${RED}[错误]${NC} 未找到 proxychains4，请先安装："
        echo -e "  Ubuntu/Debian: ${YELLOW}sudo apt install proxychains4${NC}"
        echo -e "  CentOS/RHEL:   ${YELLOW}sudo yum install proxychains-ng${NC}"
        echo -e "  Arch:          ${YELLOW}sudo pacman -S proxychains-ng${NC}"
        return
    fi

    echo ""
    echo -e "${CYAN}--- 使用代理运行命令 ---${NC}"
    echo -e "  当前代理: ${GREEN}${PROXY_TYPE}://${PROXY_HOST}:${PROXY_PORT}${NC}"
    echo ""
    echo -e "  示例命令:"
    echo -e "    ${YELLOW}curl -I https://www.google.com${NC}"
    echo -e "    ${YELLOW}wget https://example.com${NC}"
    echo -e "    ${YELLOW}bash${NC}  (启动一个代理化的 shell)"
    echo ""
    echo -n "  请输入要运行的命令 (输入 q 返回): "
    read -r cmd_input

    if [ "$cmd_input" = "q" ] || [ -z "$cmd_input" ]; then
        return
    fi

    echo ""
    echo -e "${YELLOW}[执行]${NC} proxychains4 -f $CONF_FILE $cmd_input"
    echo -e "${CYAN}------------------------------${NC}"
    proxychains4 -f "$CONF_FILE" $cmd_input
    echo -e "${CYAN}------------------------------${NC}"
    echo -e "${GREEN}[完成]${NC} 命令执行完毕"
}

# 查看代理状态
show_status() {
    echo ""
    echo -e "${CYAN}--- 代理状态 ---${NC}"
    if $CONFIGURED; then
        echo -e "  状态:   ${GREEN}已配置${NC}"
        echo -e "  类型:   ${YELLOW}${PROXY_TYPE}${NC}"
        echo -e "  地址:   ${YELLOW}${PROXY_HOST}${NC}"
        echo -e "  端口:   ${YELLOW}${PROXY_PORT}${NC}"
        echo -e "  配置文件: ${YELLOW}${CONF_FILE}${NC}"
        if [ -f "$CONF_FILE" ]; then
            echo -e "  文件状态: ${GREEN}存在${NC}"
            echo ""
            echo -e "  ${CYAN}配置文件内容:${NC}"
            echo -e "${CYAN}  ---${NC}"
            sed 's/^/  /' "$CONF_FILE"
            echo -e "${CYAN}  ---${NC}"
        else
            echo -e "  文件状态: ${RED}不存在（可能被意外删除）${NC}"
        fi
    else
        echo -e "  状态: ${RED}未配置${NC}"
        echo -e "  请先选择选项 1 配置代理"
    fi
}

# 关闭代理并清理
stop_proxy() {
    echo ""
    if $CONFIGURED; then
        if [ -f "$CONF_FILE" ]; then
            rm -f "$CONF_FILE"
            echo -e "${GREEN}[OK]${NC} 临时配置文件已删除: $CONF_FILE"
        fi
        CONFIGURED=false
        PROXY_TYPE=""
        PROXY_HOST=""
        PROXY_PORT=""
        echo -e "${GREEN}[OK]${NC} 代理配置已清除"
    else
        echo -e "${YELLOW}[INFO]${NC} 当前没有活跃的代理配置"
    fi
}

# 主循环
main() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Proxychains4 临时代理管理工具 v1.0${NC}"
    echo -e "${GREEN}  退出时将自动清理临时配置文件${NC}"
    echo -e "${GREEN}========================================${NC}"

    while true; do
        show_menu
        read -r choice

        case "$choice" in
            1) configure_proxy ;;
            2) run_with_proxy ;;
            3) show_status ;;
            4) stop_proxy ;;
            5) exit 0 ;;
            *) echo -e "\n${RED}[错误]${NC} 无效选项，请输入 1-5" ;;
        esac
    done
}

# 启动主程序
main
