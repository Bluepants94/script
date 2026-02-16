#!/bin/bash

# ==========================================
#  临时 HTTP 代理管理脚本 (tinyproxy)
#  支持公网访问，退出时自动清理
# ==========================================

WORK_DIR="/tmp/tinyproxy_temp_$$"
CONF_FILE="${WORK_DIR}/tinyproxy.conf"
PID_FILE="${WORK_DIR}/tinyproxy.pid"
LOG_FILE="${WORK_DIR}/tinyproxy.log"
PROXY_PORT=""
PROXY_AUTH_USER=""
PROXY_AUTH_PASS=""
RUNNING=false

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 创建工作目录
mkdir -p "$WORK_DIR"

# 获取本机公网IP
get_public_ip() {
    curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || \
    curl -s --connect-timeout 5 icanhazip.com 2>/dev/null || \
    curl -s --connect-timeout 5 ipinfo.io/ip 2>/dev/null || \
    echo "无法获取"
}

# 自动检测系统的 group 名称 (nogroup 或 nobody)
detect_group() {
    if getent group nogroup &>/dev/null; then
        echo "nogroup"
    elif getent group nobody &>/dev/null; then
        echo "nobody"
    else
        echo ""
    fi
}

# 停止 tinyproxy 进程
kill_tinyproxy() {
    # 方法1: 通过 PID 文件
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            sleep 1
            kill -9 "$pid" 2>/dev/null
        fi
    fi
    # 方法2: 通过配置文件路径查找进程
    local pids
    pids=$(ps aux 2>/dev/null | grep "[t]inyproxy.*${CONF_FILE}" | awk '{print $2}')
    if [ -n "$pids" ]; then
        echo "$pids" | xargs kill 2>/dev/null
        sleep 1
        echo "$pids" | xargs kill -9 2>/dev/null
    fi
}

# 清理函数 - 退出时自动清理
cleanup() {
    echo ""
    kill_tinyproxy
    if [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
        echo -e "${YELLOW}[INFO]${NC} tinyproxy 进程已停止，临时文件已清理"
    fi
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
        echo -n "  是否现在自动安装？(y/N): "
        read -r install_choice
        if [[ "$install_choice" =~ ^[Yy]$ ]]; then
            if command -v apt &>/dev/null; then
                sudo apt update && sudo apt install -y tinyproxy
            elif command -v yum &>/dev/null; then
                sudo yum install -y epel-release && sudo yum install -y tinyproxy
            elif command -v pacman &>/dev/null; then
                sudo pacman -S --noconfirm tinyproxy
            else
                echo -e "${RED}[错误]${NC} 无法识别包管理器，请手动安装"
                return 1
            fi
            # 安装后停止系统自带的 tinyproxy 服务
            sudo systemctl stop tinyproxy 2>/dev/null
            sudo systemctl disable tinyproxy 2>/dev/null
            if command -v tinyproxy &>/dev/null; then
                echo -e "${GREEN}[OK]${NC} tinyproxy 安装成功"
                return 0
            else
                echo -e "${RED}[错误]${NC} 安装失败"
                return 1
            fi
        fi
        return 1
    fi
    # 确保系统自带的 tinyproxy 服务未运行（避免冲突）
    sudo systemctl stop tinyproxy 2>/dev/null
    return 0
}

# 生成 tinyproxy 配置文件
generate_config() {
    local port="$1"
    local auth_user="$2"
    local auth_pass="$3"
    local group_name
    group_name=$(detect_group)

    # 确保工作目录存在且权限正确
    mkdir -p "$WORK_DIR"
    chmod 777 "$WORK_DIR"
    touch "$LOG_FILE"
    chmod 666 "$LOG_FILE"
    touch "$PID_FILE"
    chmod 666 "$PID_FILE"

    cat > "$CONF_FILE" << EOF
# Tinyproxy 临时配置文件
# 自动生成于: $(date)

Port $port
Listen 0.0.0.0
Timeout 600
MaxClients 100

LogFile "$LOG_FILE"
LogLevel Info
PidFile "$PID_FILE"

DisableViaHeader Yes
EOF

    # 仅在非 root 用户或存在 nobody 用户时添加 User/Group
    if [ "$(id -u)" = "0" ]; then
        if id nobody &>/dev/null && [ -n "$group_name" ]; then
            echo "User nobody" >> "$CONF_FILE"
            echo "Group $group_name" >> "$CONF_FILE"
        fi
    fi

    # 如果设置了认证，添加 BasicAuth
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
    if ss -tlnp 2>/dev/null | grep -q ":${PROXY_PORT} "; then
        echo -e "  ${RED}[错误]${NC} 端口 $PROXY_PORT 已被占用，请换一个端口"
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
            echo -e "  ${RED}[错误]${NC} 用户名和密码不能为空"
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

    # 启动 tinyproxy
    echo ""
    echo -e "${YELLOW}[启动]${NC} 正在启动 tinyproxy..."

    # 尝试启动，捕获错误输出
    local start_output
    start_output=$(tinyproxy -c "$CONF_FILE" 2>&1)
    local start_ret=$?

    # 等待启动
    sleep 2

    # 检查是否启动成功 - 多种方式检测
    local pid=""
    if [ -f "$PID_FILE" ] && [ -s "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null)
    fi

    # 如果 PID 文件没有，尝试从进程列表获取
    if [ -z "$pid" ]; then
        pid=$(pgrep -f "tinyproxy.*${CONF_FILE}" 2>/dev/null | head -1)
    fi

    # 验证进程是否存活
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        RUNNING=true
        local public_ip
        public_ip=$(get_public_ip)

        echo -e "${GREEN}[OK]${NC} 代理服务器启动成功！"
        echo ""
        echo -e "${BOLD}  ╔══════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}  ║           代理连接信息                      ║${NC}"
        echo -e "${BOLD}  ╠══════════════════════════════════════════════╣${NC}"
        echo -e "${BOLD}  ║${NC}  公网IP:    ${GREEN}${public_ip}${NC}"
        echo -e "${BOLD}  ║${NC}  端口:      ${GREEN}${PROXY_PORT}${NC}"
        if [ -n "$PROXY_AUTH_USER" ]; then
            echo -e "${BOLD}  ║${NC}  用户名:    ${GREEN}${PROXY_AUTH_USER}${NC}"
            echo -e "${BOLD}  ║${NC}  密码:      ${GREEN}${PROXY_AUTH_PASS}${NC}"
            echo -e "${BOLD}  ╠══════════════════════════════════════════════╣${NC}"
            echo -e "${BOLD}  ║${NC}  代理地址:  ${YELLOW}http://${PROXY_AUTH_USER}:${PROXY_AUTH_PASS}@${public_ip}:${PROXY_PORT}${NC}"
        else
            echo -e "${BOLD}  ╠══════════════════════════════════════════════╣${NC}"
            echo -e "${BOLD}  ║${NC}  代理地址:  ${YELLOW}http://${public_ip}:${PROXY_PORT}${NC}"
        fi
        echo -e "${BOLD}  ╠══════════════════════════════════════════════╣${NC}"
        echo -e "${BOLD}  ║${NC}  PID:       ${CYAN}${pid}${NC}"
        echo -e "${BOLD}  ║${NC}  配置文件:  ${CYAN}${CONF_FILE}${NC}"
        echo -e "${BOLD}  ╚══════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${CYAN}其他机器使用方法:${NC}"
        if [ -n "$PROXY_AUTH_USER" ]; then
            echo -e "    curl:     ${YELLOW}curl -x http://${PROXY_AUTH_USER}:${PROXY_AUTH_PASS}@${public_ip}:${PROXY_PORT} https://www.google.com${NC}"
            echo -e "    环境变量: ${YELLOW}export http_proxy=http://${PROXY_AUTH_USER}:${PROXY_AUTH_PASS}@${public_ip}:${PROXY_PORT}${NC}"
            echo -e "              ${YELLOW}export https_proxy=http://${PROXY_AUTH_USER}:${PROXY_AUTH_PASS}@${public_ip}:${PROXY_PORT}${NC}"
        else
            echo -e "    curl:     ${YELLOW}curl -x http://${public_ip}:${PROXY_PORT} https://www.google.com${NC}"
            echo -e "    环境变量: ${YELLOW}export http_proxy=http://${public_ip}:${PROXY_PORT}${NC}"
            echo -e "              ${YELLOW}export https_proxy=http://${public_ip}:${PROXY_PORT}${NC}"
        fi
    else
        echo -e "${RED}[错误]${NC} tinyproxy 启动失败"
        if [ -n "$start_output" ]; then
            echo -e "  启动输出: ${start_output}"
        fi
        if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
            echo ""
            echo -e "  ${CYAN}日志内容:${NC}"
            cat "$LOG_FILE" | head -10
        fi
        echo ""
        echo -e "  ${YELLOW}可能原因:${NC}"
        echo -e "    1. 端口 ${PROXY_PORT} 被占用"
        echo -e "    2. 需要 root 权限 (试试 sudo)"
        echo -e "    3. tinyproxy 版本不兼容"
        echo ""
        echo -e "  ${YELLOW}调试方法:${NC}"
        echo -e "    ${CYAN}tinyproxy -d -c ${CONF_FILE}${NC}  (前台模式查看错误)"
    fi
}

# 停止代理
stop_proxy() {
    echo ""
    if ! $RUNNING; then
        echo -e "${YELLOW}[INFO]${NC} 代理服务器当前未运行"
        return
    fi

    kill_tinyproxy

    # 清理文件但保留工作目录
    rm -f "$CONF_FILE" "$PID_FILE" "$LOG_FILE"
    RUNNING=false
    PROXY_PORT=""
    PROXY_AUTH_USER=""
    PROXY_AUTH_PASS=""
    echo -e "${GREEN}[OK]${NC} tinyproxy 已停止，临时文件已清理"
}

# 查看状态
show_status() {
    echo ""
    echo -e "${CYAN}--- 代理服务器状态 ---${NC}"
    echo ""

    if $RUNNING; then
        local pid=""
        if [ -f "$PID_FILE" ] && [ -s "$PID_FILE" ]; then
            pid=$(cat "$PID_FILE" 2>/dev/null)
        fi
        if [ -z "$pid" ]; then
            pid=$(pgrep -f "tinyproxy.*${CONF_FILE}" 2>/dev/null | head -1)
        fi

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
            conn_count=$(ss -tnp 2>/dev/null | grep -c ":${PROXY_PORT}" || echo "0")
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
    if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
        tail -20 "$LOG_FILE"
    else
        echo -e "  ${YELLOW}日志为空，暂无访问记录${NC}"
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
    local ret
    if [ -n "$PROXY_AUTH_USER" ]; then
        result=$(curl -s --connect-timeout 10 -x "http://${PROXY_AUTH_USER}:${PROXY_AUTH_PASS}@127.0.0.1:${PROXY_PORT}" http://ifconfig.me 2>&1)
    else
        result=$(curl -s --connect-timeout 10 -x "http://127.0.0.1:${PROXY_PORT}" http://ifconfig.me 2>&1)
    fi
    ret=$?

    if [ $ret -eq 0 ] && [ -n "$result" ]; then
        echo -e "  ${GREEN}[成功]${NC} 代理工作正常！"
        echo -e "  通过代理显示的IP: ${GREEN}${result}${NC}"
    else
        echo -e "  ${RED}[失败]${NC} 代理连接测试失败 (返回码: $ret)"
        if [ -n "$result" ]; then
            echo -e "  错误信息: $result"
        fi
        echo ""
        echo -e "  ${YELLOW}请检查:${NC}"
        echo -e "    1. 防火墙是否放行端口 ${PROXY_PORT}"
        echo -e "    2. tinyproxy 进程是否还在运行 (选项 3 查看)"
    fi
}

# 主循环
main() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     临时 HTTP 代理服务器管理工具 v2.1        ║${NC}"
    echo -e "${GREEN}║     基于 tinyproxy | 支持公网访问            ║${NC}"
    echo -e "${GREEN}║     退出时自动停止代理并清理所有临时文件     ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════╝${NC}"

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
