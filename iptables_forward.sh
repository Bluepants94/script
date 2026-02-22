#!/bin/bash

# ============================================================
#  iptables 端口转发管理脚本（增强版）
#  功能: 添加/删除/重启 iptables 端口转发规则
#  支持: 单端口、端口段、一一对应端口段、监听IP区分
#  持久化: systemd 开机自启 + 规则配置文件
# ============================================================

# ---------- 颜色定义 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------- 路径定义 ----------
CONFIG_DIR="/etc/iptables-forward"
CONFIG_FILE="${CONFIG_DIR}/rules.conf"
SERVICE_FILE="/etc/systemd/system/iptables-forward.service"
SCRIPT_INSTALL_PATH="/usr/local/bin/iptables-forward-apply"
WATCH_SCRIPT_INSTALL_PATH="/usr/local/bin/iptables-forward-watch"
WATCH_SERVICE_FILE="/etc/systemd/system/iptables-forward-watch.service"
WATCH_TIMER_FILE="/etc/systemd/system/iptables-forward-watch.timer"

# ---------- 全局数组 ----------
rules_listen_ip=()
rules_src_port=()
rules_dst_host=()
rules_dst_ip=()
rules_dst_port=()
rules_proto=()
rules_resolved_ip=()
rules_check_interval=()
rules_last_check_ts=()
rules_is_domain=()
LAST_RESULT_TYPE=""
LAST_RESULT_MSG=""
AUTOSTART_SERVICE_ENABLED=false
AUTOSTART_TIMER_ENABLED=false
AUTOSTART_FULL_ENABLED=false

# ---------- 工具函数 ----------
print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║      iptables 端口转发管理工具 (增强版)      ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_info()    { echo -e "${GREEN}[信息]${NC} $1"; }
print_warn()    { echo -e "${YELLOW}[警告]${NC} $1"; }
print_error()   { echo -e "${RED}[错误]${NC} $1"; }
print_success() { echo -e "${GREEN}[成功]${NC} $1"; }

is_yes() {
    [[ "$1" == "y" || "$1" == "Y" ]]
}

print_invalid_input() {
    print_error "输入无效，请重新输入！"
}

read_yes_no_strict() {
    # read_yes_no_strict "提示" "默认值(Y/N，可空)" result_var
    local prompt="$1"
    local default_value="$2"
    local __result_var="$3"
    local input=""

    while true; do
        read -r -p "$prompt" input
        if [[ -z "$input" && -n "$default_value" ]]; then
            input="$default_value"
        fi

        case "$input" in
            Y|y|N|n)
                printf -v "$__result_var" '%s' "$input"
                return 0
                ;;
            *)
                print_invalid_input
                ;;
        esac
    done
}

clear_rules_arrays() {
    rules_listen_ip=()
    rules_src_port=()
    rules_dst_host=()
    rules_dst_ip=()
    rules_dst_port=()
    rules_proto=()
    rules_resolved_ip=()
    rules_check_interval=()
    rules_last_check_ts=()
    rules_is_domain=()
}

refresh_autostart_state() {
    AUTOSTART_SERVICE_ENABLED=false
    AUTOSTART_TIMER_ENABLED=false
    AUTOSTART_FULL_ENABLED=false

    if systemctl is-enabled --quiet iptables-forward.service 2>/dev/null; then
        AUTOSTART_SERVICE_ENABLED=true
    fi
    if systemctl is-enabled --quiet iptables-forward-watch.timer 2>/dev/null; then
        AUTOSTART_TIMER_ENABLED=true
    fi

    if $AUTOSTART_SERVICE_ENABLED && $AUTOSTART_TIMER_ENABLED; then
        AUTOSTART_FULL_ENABLED=true
    fi
}

enable_autostart_units() {
    create_service
}

disable_autostart_units() {
    systemctl disable iptables-forward.service 2>/dev/null
    systemctl disable iptables-forward-watch.timer 2>/dev/null
    systemctl stop iptables-forward-watch.timer 2>/dev/null
}

set_last_result() {
    LAST_RESULT_TYPE="$1"
    LAST_RESULT_MSG="$2"
}

show_last_result() {
    [[ -z "$LAST_RESULT_MSG" ]] && return
    case "$LAST_RESULT_TYPE" in
        success) print_success "$LAST_RESULT_MSG" ;;
        warn) print_warn "$LAST_RESULT_MSG" ;;
        error) print_error "$LAST_RESULT_MSG" ;;
        *) print_info "$LAST_RESULT_MSG" ;;
    esac
    echo ""
    LAST_RESULT_TYPE=""
    LAST_RESULT_MSG=""
}

proto_to_label() {
    case "$1" in
        tcp) echo "TCP" ;;
        udp) echo "UDP" ;;
        both) echo "TCP+UDP" ;;
        *) echo "$1" ;;
    esac
}

repeat_char() {
    local char="$1" count="$2" result=""
    for ((j=0; j<count; j++)); do result="${result}${char}"; done
    echo "$result"
}

is_private_ip() {
    local ip="$1"
    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    if [[ "$ip" =~ ^172\.([0-9]{1,2})\. ]]; then
        local second="${BASH_REMATCH[1]}"
        [[ "$second" -ge 16 && "$second" -le 31 ]] && return 0
    fi
    [[ "$ip" =~ ^127\. ]] && return 0
    return 1
}

parse_port_expr() {
    # 输出: type|start|end
    # type: single / range
    local expr="$1"
    if [[ "$expr" =~ ^[0-9]+$ ]]; then
        local p="$expr"
        if [[ "$p" -ge 1 && "$p" -le 65535 ]]; then
            echo "single|$p|$p"
            return 0
        fi
        return 1
    fi

    if [[ "$expr" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local a="${BASH_REMATCH[1]}"
        local b="${BASH_REMATCH[2]}"
        if [[ "$a" -ge 1 && "$b" -le 65535 && "$a" -lt "$b" ]]; then
            echo "range|$a|$b"
            return 0
        fi
        return 1
    fi
    return 1
}

to_iptables_dport() {
    # 用户输入 8000-9000，iptables --dport 需要 8000:9000
    local expr="$1"
    echo "$expr" | sed 's/-/:/'
}

get_range_len() {
    local start="$1"
    local end="$2"
    echo $(( end - start + 1 ))
}

is_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [[ "$o" -ge 0 && "$o" -le 255 ]] || return 1
    done
    return 0
}

resolve_domain_ipv4() {
    local domain="$1"
    local ip=""

    if command -v dig >/dev/null 2>&1; then
        ip=$(dig @1.1.1.1 +short A "$domain" 2>/dev/null | head -n 1 | tr -d '[:space:]')
        if is_ipv4 "$ip"; then
            echo "$ip"
            return 0
        fi

        ip=$(dig @1.0.0.1 +short A "$domain" 2>/dev/null | head -n 1 | tr -d '[:space:]')
        if is_ipv4 "$ip"; then
            echo "$ip"
            return 0
        fi

        ip=$(dig @8.8.8.8 +short A "$domain" 2>/dev/null | head -n 1 | tr -d '[:space:]')
        if is_ipv4 "$ip"; then
            echo "$ip"
            return 0
        fi

        ip=$(dig @8.8.4.4 +short A "$domain" 2>/dev/null | head -n 1 | tr -d '[:space:]')
        if is_ipv4 "$ip"; then
            echo "$ip"
            return 0
        fi
    fi

    ip=$(curl -s --max-time 5 "https://cloudflare-dns.com/dns-query?name=${domain}&type=A" \
        -H 'accept: application/dns-json' 2>/dev/null \
        | grep -oE '"data":"([0-9]{1,3}\.){3}[0-9]{1,3}"' \
        | head -n 1 \
        | sed -E 's/"data":"([0-9.]+)"/\1/')
    if is_ipv4 "$ip"; then
        echo "$ip"
        return 0
    fi

    ip=$(curl -s --max-time 5 "https://dns.google/resolve?name=${domain}&type=A" 2>/dev/null \
        | grep -oE '"data":"([0-9]{1,3}\.){3}[0-9]{1,3}"' \
        | head -n 1 \
        | sed -E 's/"data":"([0-9.]+)"/\1/')
    if is_ipv4 "$ip"; then
        echo "$ip"
        return 0
    fi

    return 1
}

# ---------- 检查 root 权限 ----------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "请使用 root 权限运行此脚本！"
        print_info "使用方法: sudo bash $0"
        exit 1
    fi
}

# ---------- 初始化环境 ----------
init_env() {
    mkdir -p "$CONFIG_DIR"
    [[ -f "$CONFIG_FILE" ]] || touch "$CONFIG_FILE"

    if [[ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]]; then
        echo 1 > /proc/sys/net/ipv4/ip_forward
        print_info "已临时开启 IP 转发"
    fi

    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        if grep -q "^#.*net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
            sed -i 's/^#.*net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
        else
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        fi
        sysctl -p >/dev/null 2>&1
        print_info "已持久化开启 IP 转发 (sysctl)"
    fi

    if ! command -v iptables &>/dev/null; then
        print_error "iptables 未安装！正在尝试安装..."
        if command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y iptables
        elif command -v yum &>/dev/null; then
            yum install -y iptables
        elif command -v dnf &>/dev/null; then
            dnf install -y iptables
        else
            print_error "无法自动安装 iptables，请手动安装后重试"
            exit 1
        fi
    fi
}

# ---------- 公网IP检测 ----------
PUBLIC_IP_CACHE=""
detect_public_ip() {
    # 如果已缓存则直接返回
    if [[ -n "$PUBLIC_IP_CACHE" ]]; then
        return 0
    fi

    local ip=""
    # 尝试多个公网IP检测服务，超时3秒
    for url in "https://ip.sb" "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        ip=$(curl -4 -s --max-time 3 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            PUBLIC_IP_CACHE="$ip"
            return 0
        fi
    done

    PUBLIC_IP_CACHE="(检测失败)"
    return 1
}

# ---------- 本机IP探测 ----------
get_local_ipv4_list() {
    local_ips=()
    local_ifaces=()
    while IFS='|' read -r iface cidr; do
        [[ -z "$iface" || -z "$cidr" ]] && continue
        local ip="${cidr%%/*}"
        local_ips+=("$ip")
        local_ifaces+=("$iface")
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2"|"$4}')
}

choose_listen_ip() {
    SELECTED_LISTEN_IP="0.0.0.0"
    get_local_ipv4_list
    detect_public_ip

    echo ""
    echo -e "${CYAN}请选择监听IP（公网/内网）:${NC}"
    echo "  1) 0.0.0.0 (默认)"
    echo "  2) 127.0.0.1 (本机)"

    local next_idx=3

    # 如果检测到公网IP，显示为选项
    local has_public_ip=false
    local public_ip_idx=0
    if [[ "$PUBLIC_IP_CACHE" != "(检测失败)" && -n "$PUBLIC_IP_CACHE" ]]; then
        has_public_ip=true
        public_ip_idx=$next_idx
        echo -e "  ${next_idx}) ${GREEN}${PUBLIC_IP_CACHE}${NC} (公网IP)"
        next_idx=$((next_idx + 1))
    fi

    # 本机网卡IP
    local iface_base=$next_idx
    for ((i=0; i<${#local_ips[@]}; i++)); do
        local tag="公网"
        if is_private_ip "${local_ips[$i]}"; then
            tag="内网"
        fi
        echo "  $((iface_base+i))) ${local_ips[$i]} (${local_ifaces[$i]}, ${tag})"
    done
    next_idx=$((iface_base + ${#local_ips[@]}))

    local manual_idx=$next_idx
    echo "  ${manual_idx}) 手动输入IP"
    echo -e "  ${NC}0) 返回主菜单${NC}"

    local choice
    while true; do
        read -r -p "请选择 [0-${manual_idx}]（默认: 1）: " choice
        choice=${choice:-1}
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 0 ]] && [[ "$choice" -le "$manual_idx" ]]; then
            break
        fi
        print_invalid_input
    done

    if [[ "$choice" == "0" ]]; then
        return 1
    fi

    if [[ "$choice" == "1" ]]; then
        SELECTED_LISTEN_IP="0.0.0.0"
        return 0
    fi

    if [[ "$choice" == "2" ]]; then
        SELECTED_LISTEN_IP="127.0.0.1"
        return 0
    fi

    # 公网IP选项
    if $has_public_ip && [[ "$choice" == "$public_ip_idx" ]]; then
        SELECTED_LISTEN_IP="$PUBLIC_IP_CACHE"
        return 0
    fi

    # 网卡IP选项
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge "$iface_base" ]] && [[ "$choice" -lt "$manual_idx" ]]; then
        local idx=$((choice - iface_base))
        SELECTED_LISTEN_IP="${local_ips[$idx]}"
        return 0
    fi

    if [[ "$choice" == "$manual_idx" ]]; then
        while true; do
            local manual_ip
            read -r -p "请输入监听IP: " manual_ip
            if is_ipv4 "$manual_ip"; then
                SELECTED_LISTEN_IP="$manual_ip"
                return 0
            fi
            print_invalid_input
        done
    fi
}

# ---------- 加载规则配置 ----------
# 新格式:
# 监听IP|源端口|目标主机(IP/域名)|目标端口|协议|解析IP|检测间隔秒|上次检测时间戳|是否域名(0/1)
# 兼容旧格式:
# 1) 监听IP|源端口|目标IP|目标端口|协议
# 2) 源端口|目标IP|目标端口|协议
load_rules() {
    clear_rules_arrays

    [[ -f "$CONFIG_FILE" ]] || return

    while IFS='|' read -r c1 c2 c3 c4 c5 c6 c7 c8 c9; do
        [[ -z "$c1" || "$c1" == \#* ]] && continue

        local listen_ip src_port dst_host dst_port proto resolved_ip check_interval last_check_ts is_domain

        if [[ -n "$c9" ]]; then
            listen_ip="$c1"
            src_port="$c2"
            dst_host="$c3"
            dst_port="$c4"
            proto="$c5"
            resolved_ip="$c6"
            check_interval="$c7"
            last_check_ts="$c8"
            is_domain="$c9"
        elif [[ -n "$c5" ]]; then
            listen_ip="$c1"
            src_port="$c2"
            dst_host="$c3"
            dst_port="$c4"
            proto="$c5"
            resolved_ip="$c3"
            check_interval="0"
            last_check_ts="0"
            is_domain="0"
        else
            listen_ip="0.0.0.0"
            src_port="$c1"
            dst_host="$c2"
            dst_port="$c3"
            proto="$c4"
            resolved_ip="$c2"
            check_interval="0"
            last_check_ts="0"
            is_domain="0"
        fi

        [[ -z "$dst_host" ]] && dst_host="$resolved_ip"
        if [[ "$is_domain" != "1" ]]; then
            if is_ipv4 "$dst_host"; then
                is_domain="0"
            else
                is_domain="1"
            fi
        fi

        if [[ "$is_domain" == "1" ]] && ! is_ipv4 "$resolved_ip"; then
            resolved_ip=$(resolve_domain_ipv4 "$dst_host" 2>/dev/null || true)
        fi
        [[ -z "$resolved_ip" ]] && resolved_ip="$dst_host"
        [[ "$check_interval" =~ ^[0-9]+$ ]] || check_interval="0"
        [[ "$last_check_ts" =~ ^[0-9]+$ ]] || last_check_ts="0"

        rules_listen_ip+=("$listen_ip")
        rules_src_port+=("$src_port")
        rules_dst_host+=("$dst_host")
        rules_dst_ip+=("$resolved_ip")
        rules_dst_port+=("$dst_port")
        rules_proto+=("$proto")
        rules_resolved_ip+=("$resolved_ip")
        rules_check_interval+=("$check_interval")
        rules_last_check_ts+=("$last_check_ts")
        rules_is_domain+=("$is_domain")
    done < "$CONFIG_FILE"
}

# ---------- 保存规则配置 ----------
save_rules() {
    cat > "$CONFIG_FILE" <<EOF_CONF
# iptables 端口转发规则配置
# 格式: 监听IP|源端口|目标主机(IP/域名)|目标端口|协议|解析IP|检测间隔秒|上次检测时间戳|是否域名
# 示例(IP): 0.0.0.0|8080|127.0.0.1|1080|both|127.0.0.1|0|0|0
# 示例(域名): 0.0.0.0|443|example.com|8443|tcp|93.184.216.34|300|1700000000|1
# 自动生成，请勿手动修改（可通过脚本管理）
EOF_CONF

    for ((i=0; i<${#rules_src_port[@]}; i++)); do
        echo "${rules_listen_ip[$i]}|${rules_src_port[$i]}|${rules_dst_host[$i]}|${rules_dst_port[$i]}|${rules_proto[$i]}|${rules_resolved_ip[$i]}|${rules_check_interval[$i]}|${rules_last_check_ts[$i]}|${rules_is_domain[$i]}" >> "$CONFIG_FILE"
    done
}

# ---------- 应用 iptables 规则 ----------
apply_rules_core() {
    [[ -x "$SCRIPT_INSTALL_PATH" ]] || create_apply_script
    "$SCRIPT_INSTALL_PATH" >/dev/null 2>&1
}

apply_rules() {
    if apply_rules_core; then
        print_success "iptables 规则已应用 (共 ${#rules_src_port[@]} 条转发)"
        return 0
    fi
    print_error "iptables 规则应用失败，请检查系统环境或规则配置"
    return 1
}

# ---------- 创建应用规则脚本（供 systemd 调用） ----------
create_apply_script() {
    cat > "$SCRIPT_INSTALL_PATH" <<'SCRIPT_EOF'
#!/bin/bash
CONFIG_FILE="/etc/iptables-forward/rules.conf"

echo 1 > /proc/sys/net/ipv4/ip_forward

iptables -t nat -F PREROUTING 2>/dev/null
iptables -t nat -F POSTROUTING 2>/dev/null
iptables -t nat -A POSTROUTING -j MASQUERADE

to_iptables_dport() {
    echo "$1" | sed 's/-/:/'
}

if [[ -f "$CONFIG_FILE" ]]; then
    while IFS='|' read -r c1 c2 c3 c4 c5 c6 c7 c8 c9; do
        [[ -z "$c1" || "$c1" == \#* ]] && continue

        listen_ip=""
        src_port=""
        dst_host=""
        resolved_ip=""
        dst_port=""
        proto=""

        if [[ -n "$c9" ]]; then
            listen_ip="$c1"
            src_port="$c2"
            dst_host="$c3"
            dst_port="$c4"
            proto="$c5"
            resolved_ip="$c6"
        elif [[ -n "$c5" ]]; then
            listen_ip="$c1"
            src_port="$c2"
            dst_host="$c3"
            dst_port="$c4"
            proto="$c5"
            resolved_ip="$c3"
        else
            listen_ip="0.0.0.0"
            src_port="$c1"
            dst_host="$c2"
            dst_port="$c3"
            proto="$c4"
            resolved_ip="$c2"
        fi

        [[ -z "$resolved_ip" ]] && resolved_ip="$dst_host"

        dport=$(to_iptables_dport "$src_port")
        dst_addr="${resolved_ip}:${dst_port}"

        match_dst=""
        if [[ "$listen_ip" != "0.0.0.0" ]]; then
            match_dst="-d ${listen_ip}"
        fi

        if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
            iptables -t nat -A PREROUTING ${match_dst} -p tcp --dport "${dport}" -j DNAT --to-destination "${dst_addr}"
        fi
        if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
            iptables -t nat -A PREROUTING ${match_dst} -p udp --dport "${dport}" -j DNAT --to-destination "${dst_addr}"
        fi
    done < "$CONFIG_FILE"
fi

echo "[iptables-forward] 规则已应用"
SCRIPT_EOF

    chmod +x "$SCRIPT_INSTALL_PATH"
}

# ---------- 创建 systemd 服务 ----------
create_service() {
    create_apply_script
    create_watch_script

    cat > "$SERVICE_FILE" <<EOF_SVC
[Unit]
Description=iptables Port Forwarding Rules
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_INSTALL_PATH}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SVC

    systemctl daemon-reload
    systemctl enable iptables-forward.service >/dev/null 2>&1

    create_watch_service
    print_success "已创建 systemd 服务并设置开机自启"
}

create_watch_script() {
    cat > "$WATCH_SCRIPT_INSTALL_PATH" <<'SCRIPT_EOF'
#!/bin/bash
CONFIG_FILE="/etc/iptables-forward/rules.conf"
APPLY_SCRIPT="/usr/local/bin/iptables-forward-apply"

is_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [[ "$o" -ge 0 && "$o" -le 255 ]] || return 1
    done
    return 0
}

resolve_domain_ipv4() {
    local domain="$1"
    local ip=""

    if command -v dig >/dev/null 2>&1; then
        ip=$(dig @1.1.1.1 +short A "$domain" 2>/dev/null | head -n 1 | tr -d '[:space:]')
        if is_ipv4 "$ip"; then
            echo "$ip"
            return 0
        fi

        ip=$(dig @1.0.0.1 +short A "$domain" 2>/dev/null | head -n 1 | tr -d '[:space:]')
        if is_ipv4 "$ip"; then
            echo "$ip"
            return 0
        fi

        ip=$(dig @8.8.8.8 +short A "$domain" 2>/dev/null | head -n 1 | tr -d '[:space:]')
        if is_ipv4 "$ip"; then
            echo "$ip"
            return 0
        fi

        ip=$(dig @8.8.4.4 +short A "$domain" 2>/dev/null | head -n 1 | tr -d '[:space:]')
        if is_ipv4 "$ip"; then
            echo "$ip"
            return 0
        fi
    fi

    ip=$(curl -s --max-time 5 "https://cloudflare-dns.com/dns-query?name=${domain}&type=A" \
        -H 'accept: application/dns-json' 2>/dev/null \
        | grep -oE '"data":"([0-9]{1,3}\.){3}[0-9]{1,3}"' \
        | head -n 1 \
        | sed -E 's/"data":"([0-9.]+)"/\1/')
    if is_ipv4 "$ip"; then
        echo "$ip"
        return 0
    fi

    ip=$(curl -s --max-time 5 "https://dns.google/resolve?name=${domain}&type=A" 2>/dev/null \
        | grep -oE '"data":"([0-9]{1,3}\.){3}[0-9]{1,3}"' \
        | head -n 1 \
        | sed -E 's/"data":"([0-9.]+)"/\1/')
    if is_ipv4 "$ip"; then
        echo "$ip"
        return 0
    fi

    return 1
}

[[ -f "$CONFIG_FILE" ]] || exit 0
tmp_file=$(mktemp)
now=$(date +%s)
changed=0

while IFS='|' read -r c1 c2 c3 c4 c5 c6 c7 c8 c9; do
    if [[ -z "$c1" || "$c1" == \#* ]]; then
        echo "$c1${c2:+|$c2}${c3:+|$c3}${c4:+|$c4}${c5:+|$c5}${c6:+|$c6}${c7:+|$c7}${c8:+|$c8}${c9:+|$c9}" >> "$tmp_file"
        continue
    fi

    listen_ip="$c1"
    src_port="$c2"
    dst_host="$c3"
    dst_port="$c4"
    proto="$c5"
    resolved_ip="$c6"
    check_interval="$c7"
    last_check_ts="$c8"
    is_domain="$c9"

    [[ "$check_interval" =~ ^[0-9]+$ ]] || check_interval=0
    [[ "$last_check_ts" =~ ^[0-9]+$ ]] || last_check_ts=0

    if [[ "$is_domain" == "1" ]]; then
        [[ "$check_interval" -le 0 ]] && check_interval=300
        if (( now - last_check_ts >= check_interval )); then
            new_ip=$(resolve_domain_ipv4 "$dst_host" 2>/dev/null || true)
            if is_ipv4 "$new_ip"; then
                if [[ "$new_ip" != "$resolved_ip" ]]; then
                    resolved_ip="$new_ip"
                    changed=1
                fi
                last_check_ts="$now"
            fi
        fi
    fi

    echo "${listen_ip}|${src_port}|${dst_host}|${dst_port}|${proto}|${resolved_ip}|${check_interval}|${last_check_ts}|${is_domain}" >> "$tmp_file"
done < "$CONFIG_FILE"

if ! cmp -s "$tmp_file" "$CONFIG_FILE"; then
    cp "$tmp_file" "$CONFIG_FILE"
fi

rm -f "$tmp_file"

if [[ "$changed" -eq 1 ]]; then
    "$APPLY_SCRIPT" >/dev/null 2>&1
fi
SCRIPT_EOF

    chmod +x "$WATCH_SCRIPT_INSTALL_PATH"
}

create_watch_service() {
    cat > "$WATCH_SERVICE_FILE" <<EOF_SVC
[Unit]
Description=iptables Forward Domain Watcher
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WATCH_SCRIPT_INSTALL_PATH}
EOF_SVC

    cat > "$WATCH_TIMER_FILE" <<EOF_TIMER
[Unit]
Description=Run iptables forward domain watcher every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Unit=iptables-forward-watch.service
Persistent=true

[Install]
WantedBy=timers.target
EOF_TIMER

    systemctl daemon-reload
    systemctl enable iptables-forward-watch.timer >/dev/null 2>&1
    systemctl restart iptables-forward-watch.timer >/dev/null 2>&1
}

# ---------- 自动保存并应用 ----------
auto_save_and_apply() {
    save_rules
    create_apply_script
    if apply_rules; then
        print_success "规则已自动保存并应用！"
        return 0
    fi
    print_error "规则已保存，但应用失败，请检查 iptables 环境"
    return 1
}

# ---------- 打印规则表格 ----------
print_rules_table() {
    if [[ ${#rules_src_port[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}(暂无转发规则)${NC}"
        return
    fi

    local w_idx=4 w_lip=12 w_src=8 w_dst=16 w_proto=6
    for ((i=0; i<${#rules_src_port[@]}; i++)); do
        local idx=$((i + 1))
        local idx_len=$(( ${#idx} + 2 ))
        local dst_str="${rules_dst_ip[$i]}:${rules_dst_port[$i]}"
        local proto_str
        proto_str=$(proto_to_label "${rules_proto[$i]}")

        (( idx_len > w_idx )) && w_idx=$idx_len
        (( ${#rules_listen_ip[$i]} > w_lip )) && w_lip=${#rules_listen_ip[$i]}
        (( ${#rules_src_port[$i]} > w_src )) && w_src=${#rules_src_port[$i]}
        (( ${#dst_str} > w_dst )) && w_dst=${#dst_str}
        (( ${#proto_str} > w_proto )) && w_proto=${#proto_str}
    done

    local header
    header=$(printf "| %-${w_idx}s | %-${w_lip}s | %-${w_src}s | %-${w_dst}s | %-${w_proto}s |" \
        "序号" "监听IP" "源端口" "目标地址" "协议")
    echo -e "  ${BOLD}${header}${NC}"

    local sep="|$(repeat_char '-' $((w_idx+2)))|$(repeat_char '-' $((w_lip+2)))|$(repeat_char '-' $((w_src+2)))|$(repeat_char '-' $((w_dst+2)))|$(repeat_char '-' $((w_proto+2)))|"
    echo "  ${sep}"

    for ((i=0; i<${#rules_src_port[@]}; i++)); do
        local idx=$((i + 1))
        local dst_str="${rules_dst_ip[$i]}:${rules_dst_port[$i]}"
        local proto_str
        proto_str=$(proto_to_label "${rules_proto[$i]}")

        local col_idx col_lip col_src col_dst col_proto
        col_idx=$(printf "%-${w_idx}s" "[$idx]")
        col_lip=$(printf "%-${w_lip}s" "${rules_listen_ip[$i]}")
        col_src=$(printf "%-${w_src}s" "${rules_src_port[$i]}")
        col_dst=$(printf "%-${w_dst}s" "$dst_str")
        col_proto=$(printf "%-${w_proto}s" "$proto_str")

        echo -e "  | ${GREEN}${col_idx}${NC} | ${CYAN}${col_lip}${NC} | ${CYAN}${col_src}${NC} | ${CYAN}${col_dst}${NC} | ${CYAN}${col_proto}${NC} |"
    done
    echo ""
}

# ---------- 按首页样式打印规则 ----------
print_rules_home_style() {
    if [[ ${#rules_src_port[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}(暂无转发规则)${NC}"
        return
    fi

    for ((i=0; i<${#rules_src_port[@]}; i++)); do
        local proto_str
        proto_str=$(proto_to_label "${rules_proto[$i]}")
        local host_show="${rules_dst_host[$i]}"
        local resolved="${rules_resolved_ip[$i]}"
        local extra=""
        if [[ "${rules_is_domain[$i]}" == "1" ]]; then
            extra=" [域名→${resolved}, 间隔:${rules_check_interval[$i]}s]"
        fi
        echo -e "  ${GREEN}[$((i+1))]${NC} ${CYAN}${rules_listen_ip[$i]}${NC} ${CYAN}${rules_src_port[$i]}${NC} → ${CYAN}${host_show}:${rules_dst_port[$i]}${NC} (${proto_str})${YELLOW}${extra}${NC}"
    done
    echo ""
}

# ---------- 添加转发规则 ----------
do_add() {
    print_banner
    echo -e "${BOLD}${GREEN}[ 添加转发规则 ]${NC}"
    echo ""

    load_rules
    if [[ ${#rules_src_port[@]} -gt 0 ]]; then
        echo -e "${BOLD}${BLUE}当前已有规则:${NC}"
        print_rules_home_style
    fi

    echo ""
    echo -e "${BOLD}${CYAN}--- 新增转发 ---${NC}"

    # 选择监听IP
    local listen_ip
    if ! choose_listen_ip; then
        return
    fi
    listen_ip="$SELECTED_LISTEN_IP"

    # 输入源端口
    local src_port src_meta src_type src_start src_end
    while true; do
        read -r -p "请输入源端口（单端口如 8080，端口段如 8000-9000）: " src_port
        src_meta=$(parse_port_expr "$src_port") || {
            print_invalid_input
            continue
        }
        IFS='|' read -r src_type src_start src_end <<< "$src_meta"
        break
    done

    # 输入目标IP/域名
    local dst_host resolved_ip is_domain check_interval
    while true; do
        read -r -p "请输入目标IP/域名（如 192.168.1.100 或 example.com）: " dst_host
        if is_ipv4 "$dst_host"; then
            resolved_ip="$dst_host"
            is_domain="0"
            check_interval="0"
            break
        fi
        if [[ "$dst_host" =~ ^[A-Za-z0-9.-]+$ ]]; then
            resolved_ip=$(resolve_domain_ipv4 "$dst_host" 2>/dev/null || true)
            if is_ipv4 "$resolved_ip"; then
                is_domain="1"
                while true; do
                    read -r -p "请输入检测间隔秒（默认300，仅域名生效）: " check_interval
                    check_interval=${check_interval:-300}
                    if [[ "$check_interval" =~ ^[0-9]+$ ]] && [[ "$check_interval" -ge 60 ]]; then
                        break
                    fi
                    print_invalid_input
                done
                break
            fi
        fi
        print_invalid_input
    done

    # 输入目标端口
    local dst_port_input dst_port dst_meta dst_type dst_start dst_end
    while true; do
        read -r -p "请输入目标端口（单端口/端口段，回车=与源端口相同）: " dst_port_input
        dst_port_input=${dst_port_input:-$src_port}

        dst_meta=$(parse_port_expr "$dst_port_input") || {
            print_invalid_input
            continue
        }
        IFS='|' read -r dst_type dst_start dst_end <<< "$dst_meta"

        if [[ "$src_type" == "single" && "$dst_type" == "single" ]]; then
            dst_port="$dst_port_input"
            break
        fi

        if [[ "$src_type" == "range" && "$dst_type" == "range" ]]; then
            local src_len dst_len
            src_len=$(get_range_len "$src_start" "$src_end")
            dst_len=$(get_range_len "$dst_start" "$dst_end")
            if [[ "$src_len" -ne "$dst_len" ]]; then
                print_invalid_input
                continue
            fi
            dst_port="$dst_port_input"
            break
        fi

        print_invalid_input
    done

    # 选择协议
    local proto proto_choice
    echo ""
    echo -e "${CYAN}选择转发协议:${NC}"
    echo "  1) TCP+UDP（默认）"
    echo "  2) 仅 TCP"
    echo "  3) 仅 UDP"
    while true; do
        read -r -p "请选择 [1-3]（默认: 1）: " proto_choice
        proto_choice=${proto_choice:-1}
        case "$proto_choice" in
            1) proto="both"; break ;;
            2) proto="tcp"; break ;;
            3) proto="udp"; break ;;
            *) print_invalid_input ;;
        esac
    done

    local proto_display
    proto_display=$(proto_to_label "$proto")

    echo ""
    echo -e "${GREEN}即将添加转发:${NC}"
    echo -e "  监听IP:   ${CYAN}${listen_ip}${NC}"
    echo -e "  源端口:   ${CYAN}${src_port}${NC}"
    if [[ "$is_domain" == "1" ]]; then
        echo -e "  目标地址: ${CYAN}${dst_host}:${dst_port}${NC} (解析IP: ${CYAN}${resolved_ip}${NC}, 间隔: ${CYAN}${check_interval}s${NC})"
    else
        echo -e "  目标地址: ${CYAN}${dst_host}:${dst_port}${NC}"
    fi
    echo -e "  协议:     ${CYAN}${proto_display}${NC}"
    echo ""

    read_yes_no_strict "确认添加？[Y/N]（默认Y）: " "Y" confirm
    if ! is_yes "$confirm"; then
        set_last_result "warn" "已取消添加"
        return
    fi

    local now_ts
    now_ts=$(date +%s)
    rules_listen_ip+=("$listen_ip")
    rules_src_port+=("$src_port")
    rules_dst_host+=("$dst_host")
    rules_dst_ip+=("$resolved_ip")
    rules_dst_port+=("$dst_port")
    rules_proto+=("$proto")
    rules_resolved_ip+=("$resolved_ip")
    rules_check_interval+=("$check_interval")
    rules_last_check_ts+=("$now_ts")
    rules_is_domain+=("$is_domain")

    if auto_save_and_apply >/dev/null 2>&1; then
        set_last_result "success" "转发规则添加成功并已自动重载 iptables"
    else
        set_last_result "error" "规则已保存，但自动重载失败，请检查 iptables 环境"
    fi
}

# ---------- 删除转发规则 ----------
do_delete() {
    print_banner
    echo -e "${BOLD}${RED}[ 删除转发规则 ]${NC}"
    echo ""

    load_rules
    if [[ ${#rules_src_port[@]} -eq 0 ]]; then
        print_warn "当前没有转发规则"
        return
    fi

    echo -e "${BOLD}${BLUE}当前转发规则:${NC}"
    print_rules_home_style

    while true; do
        echo ""
        echo -e "输入序号（${CYAN}1-${#rules_src_port[@]}${NC}），输入 ${YELLOW}all${NC} 删除全部，输入 ${NC}0${NC} 返回"
        read -r -p "请选择: " del_input

        if [[ "$del_input" != "0" && "$del_input" != "all" && "$del_input" != "ALL" ]] \
            && ([[ ! "$del_input" =~ ^[0-9]+$ ]] || [[ "$del_input" -lt 1 ]] || [[ "$del_input" -gt ${#rules_src_port[@]} ]]); then
            print_invalid_input
            continue
        fi

        if [[ "$del_input" == "0" ]]; then
            return
        fi

        if [[ "$del_input" == "all" || "$del_input" == "ALL" ]]; then
            read_yes_no_strict "确认删除全部规则？[Y/N]（默认N）: " "N" confirm
            if ! is_yes "$confirm"; then
                set_last_result "warn" "已取消删除"
                return
            fi
            clear_rules_arrays
            if auto_save_and_apply >/dev/null 2>&1; then
                set_last_result "success" "已删除全部转发规则并自动重载"
            else
                set_last_result "error" "规则已清空，但自动重载失败"
            fi
            return
        fi

        local del_idx=$((del_input - 1))
        local del_info="${rules_listen_ip[$del_idx]} ${rules_src_port[$del_idx]} → ${rules_dst_host[$del_idx]}:${rules_dst_port[$del_idx]}"

        echo ""
        echo -e "${YELLOW}即将删除:${NC} ${del_info}"
        read_yes_no_strict "确认删除？[Y/N]（默认N）: " "N" confirm
        if ! is_yes "$confirm"; then
            set_last_result "warn" "已取消删除"
            return
        fi

        unset 'rules_listen_ip[del_idx]'
        unset 'rules_src_port[del_idx]'
        unset 'rules_dst_host[del_idx]'
        unset 'rules_dst_ip[del_idx]'
        unset 'rules_dst_port[del_idx]'
        unset 'rules_proto[del_idx]'
        unset 'rules_resolved_ip[del_idx]'
        unset 'rules_check_interval[del_idx]'
        unset 'rules_last_check_ts[del_idx]'
        unset 'rules_is_domain[del_idx]'

        rules_listen_ip=("${rules_listen_ip[@]}")
        rules_src_port=("${rules_src_port[@]}")
        rules_dst_host=("${rules_dst_host[@]}")
        rules_dst_ip=("${rules_dst_ip[@]}")
        rules_dst_port=("${rules_dst_port[@]}")
        rules_proto=("${rules_proto[@]}")
        rules_resolved_ip=("${rules_resolved_ip[@]}")
        rules_check_interval=("${rules_check_interval[@]}")
        rules_last_check_ts=("${rules_last_check_ts[@]}")
        rules_is_domain=("${rules_is_domain[@]}")

        if auto_save_and_apply >/dev/null 2>&1; then
            set_last_result "success" "已删除转发: ${del_info}（并自动重载）"
        else
            set_last_result "error" "已删除转发，但自动重载失败: ${del_info}"
        fi

        [[ ${#rules_src_port[@]} -eq 0 ]] && break

        echo ""
        echo -e "${BOLD}${BLUE}剩余规则:${NC}"
        print_rules_home_style

        return
    done
}

# ---------- 重启 iptables 转发 ----------
do_restart() {
    load_rules
    if [[ ${#rules_src_port[@]} -eq 0 ]]; then
        if iptables -t nat -F PREROUTING 2>/dev/null \
            && iptables -t nat -F POSTROUTING 2>/dev/null \
            && iptables -t nat -A POSTROUTING -j MASQUERADE; then
            set_last_result "success" "重启完成：当前无转发规则，NAT 已清空"
        else
            set_last_result "error" "重启失败：清理 NAT 规则时发生错误"
        fi
    else
        if apply_rules_core; then
            set_last_result "success" "重启完成：已重新加载 ${#rules_src_port[@]} 条转发规则"
        else
            set_last_result "error" "重启失败：规则应用异常，请检查 iptables 和配置"
        fi
    fi

    return
}

# ---------- 管理开机自启 ----------
do_autostart() {
    print_banner
    echo -e "${BOLD}${BLUE}[ 开机自启管理 ]${NC}"
    echo ""

    refresh_autostart_state

    if $AUTOSTART_FULL_ENABLED; then
        echo -e "  当前状态: ${GREEN}已启用开机自启${NC}"
    else
        if $AUTOSTART_SERVICE_ENABLED || $AUTOSTART_TIMER_ENABLED; then
            echo -e "  当前状态: ${YELLOW}部分启用（将自动修复）${NC}"
        else
        echo -e "  当前状态: ${YELLOW}未启用开机自启${NC}"
        fi
    fi
    echo ""

    echo -e "  ${GREEN}1)${NC} 开启自启"
    echo -e "  ${RED}2)${NC} 关闭自启"
    echo -e "  ${NC}0)${NC} 返回"
    echo ""
    while true; do
        read -r -p "请选择 [0-2]: " choice
        if [[ "$choice" == "0" || "$choice" == "1" || "$choice" == "2" ]]; then
            break
        fi
        print_invalid_input
    done

    case "$choice" in
        1)
            if enable_autostart_units; then
                set_last_result "success" "已开启开机自启"
            else
                set_last_result "error" "开启失败，请检查 systemd 环境"
            fi
            ;;
        2)
            if disable_autostart_units; then
                set_last_result "success" "已关闭开机自启"
            else
                set_last_result "error" "关闭失败，请检查 systemd 环境"
            fi
            ;;
        *)
            return
            ;;
    esac

    return
}

# ---------- 主菜单 ----------
show_menu() {
    print_banner
    show_last_result

    load_rules
    local rule_count=${#rules_src_port[@]}

    local ip_forward
    ip_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
    if [[ "$ip_forward" == "1" ]]; then
        echo -e "  IP 转发: ${GREEN}● 已开启${NC}    转发规则: ${CYAN}${rule_count} 条${NC}"
    else
        echo -e "  IP 转发: ${RED}● 未开启${NC}    转发规则: ${CYAN}${rule_count} 条${NC}"
    fi

    refresh_autostart_state
    if $AUTOSTART_FULL_ENABLED; then
        echo -e "  开机自启: ${GREEN}● 已启用${NC}"
    else
        if $AUTOSTART_SERVICE_ENABLED || $AUTOSTART_TIMER_ENABLED; then
            echo -e "  开机自启: ${YELLOW}● 部分启用（进入菜单可修复）${NC}"
        else
            echo -e "  开机自启: ${YELLOW}● 未启用${NC}"
        fi
    fi

    detect_public_ip
    if [[ "$PUBLIC_IP_CACHE" != "(检测失败)" ]]; then
        echo -e "  公网IP:   ${GREEN}${PUBLIC_IP_CACHE}${NC}"
    else
        echo -e "  公网IP:   ${RED}${PUBLIC_IP_CACHE}${NC}"
    fi
    echo ""

    if [[ $rule_count -gt 0 ]]; then
        echo -e "${BOLD}${BLUE}当前转发:${NC}"
        print_rules_home_style
    fi

    echo -e "  ${GREEN}1)${NC} 添加转发规则"
    echo -e "  ${RED}2)${NC} 删除转发规则"
    echo -e "  ${CYAN}3)${NC} 重启 iptables 转发"
    echo -e "  ${YELLOW}4)${NC} 开机自启管理"
    echo -e "  ${NC}0)${NC} 退出"
    echo ""

    while true; do
        read -r -p "请选择操作 [0-4]: " choice
        if [[ "$choice" =~ ^[0-4]$ ]]; then
            break
        fi
        print_invalid_input
    done
}

# ---------- 主入口 ----------
main() {
    check_root
    init_env
    create_service

    while true; do
        show_menu
        case "$choice" in
            1) do_add ;;
            2) do_delete ;;
            3) do_restart ;;
            4) do_autostart ;;
            0)
                echo ""
                print_info "再见！"
                exit 0
                ;;
            *)
                set_last_result "error" "无效选择，请输入 0-4"
                ;;
        esac
    done
}

main
