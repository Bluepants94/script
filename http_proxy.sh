#!/bin/bash

# ==========================================
#  临时 HTTP 代理管理脚本 (tinyproxy)
#  支持公网访问，退出时自动清理
# ==========================================

CONF_FILE="/tmp/tinyproxy_temp.conf"
PID_FILE="/tmp/tinyproxy_temp.pid"
LOG_FILE="/tmp/tinyproxy_temp.log"
PROXY_PORT=""
PROXY_AUTH_USER=""
PROXY_AUTH_PASS=""
CONFIGURED=false
RUNNING=false

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 获取本机公网IP
get_public_ip() {
    curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || \
    curl -s --connect-timeout 5 icanhazip.com 2>/dev/null || \
    curl -s --connect-timeout 5 ipinfo.io/ip 2>/dev/null || \
    echo "无法获取"
}

# 清理函数 - 退出时自动清理
cleanup() {
    echo ""
    # 停止 tinyproxy 进程
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            sleep 1
            # 强制杀死
            kill -9 "$pid" 2>/dev/null
            echo -e "${YELLOW}[INFO]${NC} tinyproxy 进程已停止 (PID: $pid)"
        fi
    fi
    # 清理所有临时文件
    rm -f "$CONF_FILE" "$PID_FILE" "$LOG_FILE"
    echo -e "${YELLOW}[INFO]${NC} 临时文件已清理"
    echo -e "${GREEN}再见！${NC}"
}

# 捕获退出信号，确保清理
trap cleanup EXIT INT TERM

# 检查 tinyproxy 是否已安装
check_tinyproxy() {
    if ! command -v tinyproxy &> /dev/null; then
        echo ""
        echo -e "${RED}[错误]${NC} 未找到 tinyproxy，请先安装："
        echo ""
        echo -e "  Ubuntu/Debian: ${YELLOW}sudo apt update && sudo apt install -y tinyproxy${NC}"
        echo -e "  CentOS/RHEL:   ${YELLOW}sudo yum install -y epel-release && sudo yum install -y tinyproxy${NC}"
        echo -e "  Arch:          ${YELLOW}sudo pacman -S tinyproxy${NC}"
        echo ""
        return 1
    fi
    return 0
}

# 生成 tinyproxy 配置文件
generate_config() {
    local port="$1"
    local auth_user="$2"
    local auth_pass="$3"

    cat > "$CONF_FILE" << EOF
# Tinyproxy 临时配置文件
# 自动生成于: $(date)

User nobody
Group nogroup

Port $port
Listen 0.0.0.0
Timeout 600
MaxClients 100

# 允许所有IP连接（公网访问）
Allow 0.0.0.0/0

# 日志
LogFile "$LOG_FILE"
LogLevel Info

# 不限制连接
DisableViaHeader Yes

PidFile "$PID_FILE"
EOF

    # 如果设置了认证
    if [ -n "$auth_user" ] && [ -n "$auth_pass" ]; then
        echo "" >> "$CONF_FILE"
        echo "# 基本认证" >> "$CONF_FILE"
        echo "BasicAuth $auth_user $auth_pass" >> "$CONF_FILE"
    fi
}

# 显示菜单
show_menu() {
    echo ""
    echo -e "${CYAN}===========================================${NC}"
    echo -e "${CYAN}    临时 HTTP 代理服务器 (tinyproxy)${NC}"
    echo -e "${CYAN}===========================================${NC}"
    if $RUNNING; then
        echo -e "  状态: ${GREEN}● 运行中${NC}  端口: ${GREEN}${PROXY_PORT}${NC}"
        if [ -n "$PROXY_AUTH_USER" ]; then
            echo -e "  认证: ${GREEN}已启用${NC} (${PROXY_AUTH_USER}:${PROXY_AUTH_PASS})"
        else
            echo -e "  认证: ${YELLOW}无认证（任何人可访问）${NC}"
        fi
    else
        echo -e "  状态: ${RED}● 未运行${NC}"
    fi
    echo -e "${CYAN}-------------------------------------------${NC}"
    echo "  1) 启动代理服务器"
    echo "  2) 停止代理服务器"
    echo "  3) 查看代理状态 & 连接信息"
    echo "  4) 查看访问日志"
    echo "  5) 测试代理连接"
    echo "  6) 退出（自动清理）"
    echo -e "${CYAN}-------------------------------------------${NC}"
    echo -n "  请选择 [1-6]: "
}

# 启动代理
start_proxy() {
    if ! check_tinyproxy; then
        return
    fi

    if $RUNNING; then
        echo ""
        echo -e "${YELLOW}[INFO]${NC} 代理服务器已在运行中 (端口: $PROXY_PORT)"
        echo -e "  如需更改配置，请先停止代理（选项 2）"
        return
    fi

    echo ""
    echo -e "${CYAN}--- 配置代理服务器 ---${NC}"
    echo ""

    # 输入端口
    echo -n "  请输入监听端口 (默认: 8888): "
    read -r port_input
    PROXY_PORT="${port_input:-8888}"

    # 检查端口是否被占用
    if ss -tlnp 2>/dev/null | grep -q ":${PROXY_PORT} " || netstat -tlnp 2>/dev/null | grep -q ":${PROXY_PORT} "; then
        echo -e "${RED}[错误]${NC} 端口 $PROXY_PORT 已被占用，请换一个端口"
        return
    fi

    # 是否设置认证
    echo -n "  是否设置用户名密码认证？(y/N): "
    read -r auth_choice
    if [[ "$auth_choice" =~ ^[Yy]$ ]]; then
        echo -n "  请输入用户名: "
        read -r PROXY_AUTH_USER
        echo -n "  请输入密码: "
        read -r PROXY_AUTH_PASS
        if [ -z "$PROXY_AUTH_USER" ] || [ -z "$PROXY_AUTH_PASS" ]; then
            echo -e "${RED}[错误]${NC} 用户名和密码不能为空"
            PROXY_AUTH_USER=""
            PROXY_AUTH_PASS=""
            return
        fi
    else
        PROXY_AUTH_USER=""
        PROXY_AUTH_PASS=""
    fi

    # 生成配置文件
    generate_config "$PROXY_PORT" "$PROXY_AUTH_USER" "$PROXY_AUTH_PASS"

    # 创建日志文件
    touch "$LOG_FILE"

    # 启动 tinyproxy
    echo ""
    echo -e "${YELLOW}[启动]${NC} 正在启动 tinyproxy..."
    tinyproxy -c "$CONF_FILE" 2>&1

    # 等待启动
    sleep 1

    # 检查是否启动成功
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            RUNNING=true
            local public_ip
            public_ip=$(get_public_ip)

            echo -e "${GREEN}[OK]${NC} 代理服务器启动成功！"
            echo ""
            echo -e "${BOLD}  ╔══════════════════════════════════════════╗${NC}"
            echo -e "${BOLD}  ║         代理连接信息                    ║${NC}"
            echo -e "${BOLD}  ╠══════════════════════════════════════════╣${NC}"
            echo -e "${BOLD}  ║${NC}  公网IP:  ${GREEN}${public_ip}${NC}"
            echo -e "${BOLD}  ║${NC}  端口:    ${GREEN}${PROXY_PORT}${NC}"
            if [ -n "$PROXY_AUTH_USER" ]; then
                echo -e "${BOLD}  ║${NC}  用户名:  ${GREEN}${PROXY_AUTH_USER}${NC}"
                echo -e "${BOLD}  ║${NC}  密码:    ${GREEN}${PROXY_AUTH_PASS}${NC}"
                echo -e "${BOLD}  ╠══════════════════════════════════════════╣${NC}"
                echo -e "${BOLD}  ║${NC}  代理地址: ${YELLOW}http://${PROXY_AUTH_USER}:${PROXY_AUTH_PASS}@${public_ip}:${PROXY_PORT}${NC}"
            else
                echo -e "${BOLD}  ╠══════════════════════════════════════════╣${NC}"
                echo -e "${BOLD}  ║${NC}  代理地址: ${YELLOW}http://${public_ip}:${PROXY_PORT}${NC}"
            fi
            echo -e "${BOLD}  ╠══════════════════════════════════════════╣${NC}"
            echo -e "${BOLD}  ║${NC}  PID:     ${CYAN}${pid}${NC}"
            echo -e "${BOLD}  ║${NC}  配置文件: ${CYAN}${CONF_FILE}${NC}"
            echo -e "${BOLD}  ╚══════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "  ${CYAN}其他机器使用方法:${NC}"
            if [ -n "$PROXY_AUTH_USER" ]; then
                echo -e "    curl:    ${YELLOW}curl -x http://${PROXY_AUTH_USER}:${PROXY_AUTH_PASS}@${public_ip}:${PROXY_PORT} https://www.google.com${NC}"
                echo -e "    环境变量: ${YELLOW}export http_proxy=http://${PROXY_AUTH_USER}:${PROXY_AUTH_PASS}@${public_ip}:${PROXY_PORT}${NC}"
                echo -e "             ${YELLOW}export https_proxy=http://${PROXY_AUTH_USER}:${PROXY_AUTH_PASS}@${public_ip}:${PROXY_PORT}${NC}"
            else
                echo -e "    curl:    ${YELLOW}curl -x http://${public_ip}:${PROXY_PORT} https://www.google.com${NC}"
                echo -e "    环境变量: ${YELLOW}export http_proxy=http://${public_ip}:${PROXY_PORT}${NC}"
                echo -e "             ${YELLOW}export https_proxy=http://${public_ip}:${PROXY_PORT}${NC}"
            fi
        else
            echo -e "${RED}[错误]${NC} tinyproxy 启动失败"
            echo -e "  查看日志: cat $LOG_FILE"
            if [ -f "$LOG_FILE" ]; then
                echo ""
                echo -e "${CYAN}  日志内容:${NC}"
                tail -5 "$LOG_FILE"
            fi
        fi
    else
        echo -e "${RED}[错误]${NC} tinyproxy 启动失败，PID 文件未生成"
        echo -e "  可能原因: 端口被占用、权限不足"
        if [ -f "$LOG_FILE" ]; then
            echo ""
            echo -e "${CYAN}  日志内容:${NC}"
            tail -5 "$LOG_FILE"
        fi
    fi
}

# 停止代理
stop_proxy() {
    echo ""
    if ! $RUNNING; then
        echo -e "${YELLOW}[INFO]${NC} 代理服务器当前未运行"
        return
    fi

    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            sleep 1
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null
            fi
            echo -e "${GREEN}[OK]${NC} tinyproxy 已停止 (PID: $pid)"
        fi
    fi

    # 清理文件
    rm -f "$CONF_FILE" "$PID_FILE" "$LOG_FILE"
    RUNNING=false
    PROXY_PORT=""
    PROXY_AUTH_USER=""
    PROXY_AUTH_PASS=""
    echo -e "${GREEN}[OK]${NC} 临时配置文件已清理"
}

# 查看状态
show_status() {
    echo ""
    echo -e "${CYAN}--- 代理服务器状态 ---${NC}"
    echo ""

    if $RUNNING && [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            local public_ip
            public_ip=$(get_public_ip)

            echo -e "  状态:     ${GREEN}● 运行中${NC}"
            echo -e "  PID:      ${CYAN}${pid}${NC}"
            echo -e "  端口:     ${GREEN}${PROXY_PORT}${NC}"
            echo -e "  公网IP:   ${GREEN}${public_ip}${NC}"
            if [ -n "$PROXY_AUTH_USER" ]; then
                echo -e "  认证:     ${GREEN}已启用${NC} (${PROXY_AUTH_USER}:${PROXY_AUTH_PASS})"
                echo -e "  代理地址: ${YELLOW}http://${PROXY_AUTH_USER}:${PROXY_AUTH_PASS}@${public_ip}:${PROXY_PORT}${NC}"
            else
                echo -e "  认证:     ${YELLOW}无${NC}"
                echo -e "  代理地址: ${YELLOW}http://${public_ip}:${PROXY_PORT}${NC}"
            fi
            echo -e "  配置文件: ${CYAN}${CONF_FILE}${NC}"
            echo -e "  日志文件: ${CYAN}${LOG_FILE}${NC}"

            # 显示连接数
            local conn_count
            conn_count=$(ss -tnp 2>/dev/null | grep ":${PROXY_PORT}" | wc -l)
            echo -e "  当前连接: ${CYAN}${conn_count}${NC}"
        else
            echo -e "  状态: ${RED}● 进程已消失${NC}"
            RUNNING=false
        fi
    else
        echo -e "  状态: ${RED}● 未运行${NC}"
        echo -e "  请选择选项 1 启动代理服务器"
    fi
}

# 查看日志
show_log() {
    echo ""
    echo -e "${CYAN}--- 访问日志 (最近 20 条) ---${NC}"
    echo ""
    if [ -f "$LOG_FILE" ]; then
        tail -20 "$LOG_FILE"
        if [ ! -s "$LOG_FILE" ]; then
            echo -e "  ${YELLOW}日志为空，暂无访问记录${NC}"
        fi
    else
        echo -e "  ${RED}日志文件不存在${NC}"
    fi
}

# 测试代理
test_proxy() {
    echo ""
    if ! $RUNNING; then
        echo -e "${RED}[错误]${NC} 代理服务器未运行，请先启动"
        return
    fi

    echo -e "${CYAN}--- 测试代理连接 ---${NC}"
    echo ""
    echo -e "${YELLOW}[测试]${NC} 通过代理访问 http://ifconfig.me ..."
    echo ""

    local result
    if [ -n "$PROXY_AUTH_USER" ]; then
        result=$(curl -s --connect-timeout 10 -x "http://${PROXY_AUTH_USER}:${PROXY_AUTH_PASS}@127.0.0.1:${PROXY_PORT}" http://ifconfig.me 2>&1)
    else
        result=$(curl -s --connect-timeout 10 -x "http://127.0.0.1:${PROXY_PORT}" http://ifconfig.me 2>&1)
    fi

    if [ $? -eq 0 ] && [ -n "$result" ]; then
        echo -e "  ${GREEN}[成功]${NC} 代理工作正常！"
        echo -e "  通过代理显示的IP: ${GREEN}${result}${NC}"
    else
        echo -e "  ${RED}[失败]${NC} 代理连接测试失败"
        echo -e "  错误信息: $result"
    fi
}

# 主循环
main() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   临时 HTTP 代理服务器管理工具 v2.0      ║${NC}"
    echo -e "${GREEN}║   基于 tinyproxy | 支持公网访问          ║${NC}"
    echo -e "${GREEN}║   退出时自动停止代理并清理所有临时文件   ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"

    while true; do
        show_menu
        read -r choice

        case "$choice" in
            1) start_proxy ;;
            2) stop_proxy ;;
            3) show_status ;;
            4) show_log ;;
            5) test_proxy ;;
            6) exit 0 ;;
            *) echo -e "\n${RED}[错误]${NC} 无效选项，请输入 1-6" ;;
        esac
    done
}

# 启动主程序
main
