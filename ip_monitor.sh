#!/bin/bash

# ============================================
#  动态IP变更通知 Telegram Bot 脚本
#  用法：将此脚本放到 Linux 服务器上，
#       配置下方变量后，添加 crontab 即可
# ============================================

# ========== 用户配置区域 ==========

# 服务器名称（自定义，用于通知显示）
SERVER_NAME="My-Server"

# Telegram Bot Token（从 @BotFather 获取）
TG_BOT_TOKEN="YOUR_BOT_TOKEN_HERE"

# Telegram Chat ID（从 @userinfobot 或 @getmyid_bot 获取）
TG_CHAT_ID="YOUR_CHAT_ID_HERE"

# IP 记录文件路径（存储在脚本所在目录）
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
IP_FILE="${SCRIPT_DIR}/ip_monitor_last_ip.txt"

# 获取公网 IP 的接口（备用多个，按顺序尝试）
GET_IP_URLS=(
    "https://ip.sb"
    "https://ifconfig.me"
    "https://api.ipify.org"
    "https://icanhazip.com"
)

# ========== 脚本逻辑 ==========

# 获取当前公网 IP
get_current_ip() {
    for url in "${GET_IP_URLS[@]}"; do
        ip=$(curl -s --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]')
        # 验证是否为合法 IPv4 地址
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# 发送 Telegram 消息
send_tg_message() {
    local message="$1"
    curl -s --max-time 10 -X POST \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=Markdown" \
        > /dev/null 2>&1
}

# 主逻辑
main() {
    # 获取当前 IP
    current_ip=$(get_current_ip)
    if [ -z "$current_ip" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 错误：无法获取当前公网 IP"
        exit 1
    fi

    # 读取上次记录的 IP
    if [ -f "$IP_FILE" ]; then
        last_ip=$(cat "$IP_FILE" 2>/dev/null | tr -d '[:space:]')
    else
        last_ip=""
    fi

    # 对比 IP 是否变更
    if [ "$current_ip" != "$last_ip" ]; then
        # 保存新 IP
        echo "$current_ip" > "$IP_FILE"

        # 首次运行（无旧 IP 记录）
        if [ -z "$last_ip" ]; then
            message="🟢 *IP 监控已启动*
服务器：\`${SERVER_NAME}\`
当前IP：\`${current_ip}\`
时间：$(date '+%Y-%m-%d %H:%M:%S')"
        else
            # IP 发生变更
            message="🔔 *IP 变更通知*
服务器：\`${SERVER_NAME}\`
IP变更：\`${last_ip}\` -> \`${current_ip}\`
时间：$(date '+%Y-%m-%d %H:%M:%S')"
        fi

        send_tg_message "$message"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] IP 变更通知已发送: ${last_ip:-无} -> ${current_ip}"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] IP 未变更: ${current_ip}"
    fi
}

main
