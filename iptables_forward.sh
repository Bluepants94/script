#!/bin/bash

# ============================================================
#  iptables 端口转发管理脚本（增强版）
#  功能: 添加/删除/查看/重启 iptables 端口转发规则
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

# ---------- 全局数组 ----------
rules_listen_ip=()
rules_src_port=()
rules_dst_ip=()
rules_dst_port=()
rules_proto=()

# ---------- 工具函数 ----------
print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║      iptables 端口转发管理工具 (增强版)      ║"
    echo "║   支持监听IP区分 + 端口段一一对应转发        ║"
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
    get_local_ipv4_list

    echo ""
    echo -e "${CYAN}请选择监听IP（用于区分公网/内网入口）:${NC}"
    echo "  1) 0.0.0.0 (所有IP，公网+内网都匹配，默认)"

    local base=2
    for ((i=0; i<${#local_ips[@]}; i++)); do
        local tag="公网"
        if is_private_ip "${local_ips[$i]}"; then
            tag="内网"
        fi
        echo "  $((base+i))) ${local_ips[$i]} (${local_ifaces[$i]}, ${tag})"
    done
    local manual_idx=$((base + ${#local_ips[@]}))
    echo "  ${manual_idx}) 手动输入IP"

    local choice
    read -r -p "请选择 [1-${manual_idx}]（默认: 1）: " choice
    choice=${choice:-1}

    if [[ "$choice" == "1" ]]; then
        echo "0.0.0.0"
        return 0
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge "$base" ]] && [[ "$choice" -lt "$manual_idx" ]]; then
        local idx=$((choice - base))
        echo "${local_ips[$idx]}"
        return 0
    fi

    if [[ "$choice" == "$manual_idx" ]]; then
        while true; do
            local manual_ip
            read -r -p "请输入监听IP: " manual_ip
            if [[ "$manual_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                echo "$manual_ip"
                return 0
            fi
            print_error "IP格式错误"
        done
    fi

    echo "0.0.0.0"
}

# ---------- 加载规则配置 ----------
# 新格式: 监听IP|源端口|目标IP|目标端口|协议
# 旧格式: 源端口|目标IP|目标端口|协议  (自动兼容为监听IP=0.0.0.0)
load_rules() {
    rules_listen_ip=()
    rules_src_port=()
    rules_dst_ip=()
    rules_dst_port=()
    rules_proto=()

    [[ -f "$CONFIG_FILE" ]] || return

    while IFS='|' read -r c1 c2 c3 c4 c5; do
        [[ -z "$c1" || "$c1" == \#* ]] && continue

        if [[ -n "$c5" ]]; then
            # 新格式
            rules_listen_ip+=("$c1")
            rules_src_port+=("$c2")
            rules_dst_ip+=("$c3")
            rules_dst_port+=("$c4")
            rules_proto+=("$c5")
        else
            # 旧格式兼容
            rules_listen_ip+=("0.0.0.0")
            rules_src_port+=("$c1")
            rules_dst_ip+=("$c2")
            rules_dst_port+=("$c3")
            rules_proto+=("$c4")
        fi
    done < "$CONFIG_FILE"
}

# ---------- 保存规则配置 ----------
save_rules() {
    cat > "$CONFIG_FILE" <<EOF_CONF
# iptables 端口转发规则配置
# 格式: 监听IP|源端口|目标IP|目标端口|协议(tcp/udp/both)
# 示例: 0.0.0.0|8080|127.0.0.1|1080|both
# 端口段: 10.0.0.1|8000-9000|192.168.1.10|18000-19000|tcp
# 自动生成，请勿手动修改（可通过脚本管理）
EOF_CONF

    for ((i=0; i<${#rules_src_port[@]}; i++)); do
        echo "${rules_listen_ip[$i]}|${rules_src_port[$i]}|${rules_dst_ip[$i]}|${rules_dst_port[$i]}|${rules_proto[$i]}" >> "$CONFIG_FILE"
    done
}

# ---------- 应用 iptables 规则 ----------
apply_rules() {
    iptables -t nat -F PREROUTING 2>/dev/null
    iptables -t nat -F POSTROUTING 2>/dev/null
    iptables -t nat -A POSTROUTING -j MASQUERADE

    for ((i=0; i<${#rules_src_port[@]}; i++)); do
        local listen_ip="${rules_listen_ip[$i]}"
        local src="${rules_src_port[$i]}"
        local dst_ip="${rules_dst_ip[$i]}"
        local dst_port="${rules_dst_port[$i]}"
        local proto="${rules_proto[$i]}"

        local dport
        dport=$(to_iptables_dport "$src")

        local dst_addr="${dst_ip}:${dst_port}"
        local match_dst=""
        if [[ "$listen_ip" != "0.0.0.0" ]]; then
            match_dst="-d ${listen_ip}"
        fi

        if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
            iptables -t nat -A PREROUTING ${match_dst} -p tcp --dport "${dport}" -j DNAT --to-destination "${dst_addr}"
        fi
        if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
            iptables -t nat -A PREROUTING ${match_dst} -p udp --dport "${dport}" -j DNAT --to-destination "${dst_addr}"
        fi
    done

    print_success "iptables 规则已应用 (共 ${#rules_src_port[@]} 条转发)"
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
    while IFS='|' read -r c1 c2 c3 c4 c5; do
        [[ -z "$c1" || "$c1" == \#* ]] && continue

        listen_ip=""
        src_port=""
        dst_ip=""
        dst_port=""
        proto=""

        if [[ -n "$c5" ]]; then
            listen_ip="$c1"
            src_port="$c2"
            dst_ip="$c3"
            dst_port="$c4"
            proto="$c5"
        else
            listen_ip="0.0.0.0"
            src_port="$c1"
            dst_ip="$c2"
            dst_port="$c3"
            proto="$c4"
        fi

        dport=$(to_iptables_dport "$src_port")
        dst_addr="${dst_ip}:${dst_port}"

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
    systemctl enable iptables-forward.service 2>/dev/null
    print_success "已创建 systemd 服务并设置开机自启"
}

# ---------- 自动保存并应用 ----------
auto_save_and_apply() {
    save_rules
    apply_rules
    create_apply_script
    print_success "规则已自动保存并应用！"
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
        local proto_str=""
        case "${rules_proto[$i]}" in
            tcp) proto_str="TCP" ;;
            udp) proto_str="UDP" ;;
            both) proto_str="TCP+UDP" ;;
            *) proto_str="${rules_proto[$i]}" ;;
        esac

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
        local proto_str=""
        case "${rules_proto[$i]}" in
            tcp) proto_str="TCP" ;;
            udp) proto_str="UDP" ;;
            both) proto_str="TCP+UDP" ;;
            *) proto_str="${rules_proto[$i]}" ;;
        esac

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

# ---------- 添加转发规则 ----------
do_add() {
    print_banner
    echo -e "${BOLD}${GREEN}[ 添加转发规则 ]${NC}"
    echo ""

    load_rules
    if [[ ${#rules_src_port[@]} -gt 0 ]]; then
        echo -e "${BOLD}${BLUE}当前已有规则:${NC}"
        print_rules_table
    fi

    while true; do
        echo ""
        echo -e "${BOLD}${CYAN}--- 新增转发 ---${NC}"

        local listen_ip
        listen_ip=$(choose_listen_ip)

        local src_port src_meta src_type src_start src_end
        while true; do
            read -r -p "请输入源端口（单端口如 8080，端口段如 8000-9000）: " src_port
            src_meta=$(parse_port_expr "$src_port") || {
                print_error "端口格式错误，范围需在 1-65535"
                continue
            }
            IFS='|' read -r src_type src_start src_end <<< "$src_meta"
            break
        done

        local dst_ip
        while true; do
            read -r -p "请输入目标IP（可内网IP，如 192.168.1.100）: " dst_ip
            if [[ "$dst_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                break
            fi
            print_error "IP格式错误"
        done

        local dst_port_input dst_port dst_meta dst_type dst_start dst_end
        while true; do
            read -r -p "请输入目标端口（单端口/端口段，回车=与源端口相同）: " dst_port_input
            dst_port_input=${dst_port_input:-$src_port}

            dst_meta=$(parse_port_expr "$dst_port_input") || {
                print_error "目标端口格式错误"
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
                    print_error "端口段长度不一致，无法一一对应转发（源:${src_len} 目标:${dst_len}）"
                    continue
                fi
                dst_port="$dst_port_input"
                break
            fi

            print_error "单端口必须对应单端口；端口段必须对应端口段"
        done

        local proto proto_choice
        echo ""
        echo -e "${CYAN}选择转发协议:${NC}"
        echo "  1) TCP+UDP（默认）"
        echo "  2) 仅 TCP"
        echo "  3) 仅 UDP"
        read -r -p "请选择 [1-3]（默认: 1）: " proto_choice
        case "$proto_choice" in
            2) proto="tcp" ;;
            3) proto="udp" ;;
            *) proto="both" ;;
        esac

        local proto_display
        case "$proto" in
            tcp) proto_display="TCP" ;;
            udp) proto_display="UDP" ;;
            both) proto_display="TCP+UDP" ;;
        esac

        echo ""
        echo -e "${GREEN}即将添加转发:${NC}"
        echo -e "  监听IP:   ${CYAN}${listen_ip}${NC}"
        echo -e "  源端口:   ${CYAN}${src_port}${NC}"
        echo -e "  目标地址: ${CYAN}${dst_ip}:${dst_port}${NC}"
        echo -e "  协议:     ${CYAN}${proto_display}${NC}"

        rules_listen_ip+=("$listen_ip")
        rules_src_port+=("$src_port")
        rules_dst_ip+=("$dst_ip")
        rules_dst_port+=("$dst_port")
        rules_proto+=("$proto")

        auto_save_and_apply

        echo ""
        read -r -p "是否继续添加？[y/N]: " continue_add
        if [[ "$continue_add" != "y" && "$continue_add" != "Y" ]]; then
            break
        fi
    done

    press_any_key
}

# ---------- 删除转发规则 ----------
do_delete() {
    print_banner
    echo -e "${BOLD}${RED}[ 删除转发规则 ]${NC}"
    echo ""

    load_rules
    if [[ ${#rules_src_port[@]} -eq 0 ]]; then
        print_warn "当前没有转发规则"
        press_any_key
        return
    fi

    echo -e "${BOLD}${BLUE}当前转发规则:${NC}"
    print_rules_table

    while true; do
        echo ""
        echo -e "输入序号（${CYAN}1-${#rules_src_port[@]}${NC}），输入 ${YELLOW}all${NC} 删除全部，输入 ${NC}0${NC} 返回"
        read -r -p "请选择: " del_input

        if [[ "$del_input" == "0" ]]; then
            break
        fi

        if [[ "$del_input" == "all" || "$del_input" == "ALL" ]]; then
            rules_listen_ip=()
            rules_src_port=()
            rules_dst_ip=()
            rules_dst_port=()
            rules_proto=()
            auto_save_and_apply
            print_success "已删除全部转发规则！"
            break
        fi

        if [[ ! "$del_input" =~ ^[0-9]+$ ]] || [[ "$del_input" -lt 1 ]] || [[ "$del_input" -gt ${#rules_src_port[@]} ]]; then
            print_error "序号无效！"
            continue
        fi

        local del_idx=$((del_input - 1))
        local del_info="${rules_listen_ip[$del_idx]} ${rules_src_port[$del_idx]} → ${rules_dst_ip[$del_idx]}:${rules_dst_port[$del_idx]}"

        unset 'rules_listen_ip[del_idx]'
        unset 'rules_src_port[del_idx]'
        unset 'rules_dst_ip[del_idx]'
        unset 'rules_dst_port[del_idx]'
        unset 'rules_proto[del_idx]'

        rules_listen_ip=("${rules_listen_ip[@]}")
        rules_src_port=("${rules_src_port[@]}")
        rules_dst_ip=("${rules_dst_ip[@]}")
        rules_dst_port=("${rules_dst_port[@]}")
        rules_proto=("${rules_proto[@]}")

        auto_save_and_apply
        print_success "已删除转发: ${del_info}"

        [[ ${#rules_src_port[@]} -eq 0 ]] && break

        echo ""
        echo -e "${BOLD}${BLUE}剩余规则:${NC}"
        print_rules_table

        read -r -p "是否继续删除？[y/N]: " continue_del
        if [[ "$continue_del" != "y" && "$continue_del" != "Y" ]]; then
            break
        fi
    done

    press_any_key
}

# ---------- 查看当前规则 ----------
do_list() {
    print_banner
    echo -e "${BOLD}${BLUE}[ 当前转发规则 ]${NC}"
    echo ""

    load_rules
    print_rules_table

    echo -e "${BOLD}${BLUE}[ 本机IP（公网/内网） ]${NC}"
    get_local_ipv4_list
    if [[ ${#local_ips[@]} -eq 0 ]]; then
        echo "  (未检测到全局IPv4地址)"
    else
        for ((i=0; i<${#local_ips[@]}; i++)); do
            local tag="公网"
            if is_private_ip "${local_ips[$i]}"; then
                tag="内网"
            fi
            echo "  - ${local_ips[$i]} (${local_ifaces[$i]}, ${tag})"
        done
    fi

    echo ""
    echo -e "${BOLD}${BLUE}[ iptables NAT 表规则 ]${NC}"
    iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | head -50
    echo ""

    local ip_forward
    ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)
    if [[ "$ip_forward" == "1" ]]; then
        echo -e "  IP 转发状态: ${GREEN}已开启${NC}"
    else
        echo -e "  IP 转发状态: ${RED}未开启${NC}"
    fi

    if systemctl is-enabled --quiet iptables-forward.service 2>/dev/null; then
        echo -e "  开机自启:     ${GREEN}已启用${NC}"
    else
        echo -e "  开机自启:     ${YELLOW}未启用${NC}"
    fi

    echo ""
    press_any_key
}

# ---------- 重启 iptables 转发 ----------
do_restart() {
    print_banner
    echo -e "${BOLD}${BLUE}[ 重启 iptables 转发 ]${NC}"
    echo ""

    load_rules
    if [[ ${#rules_src_port[@]} -eq 0 ]]; then
        print_warn "当前没有转发规则，清除 NAT 规则"
        iptables -t nat -F PREROUTING 2>/dev/null
        iptables -t nat -F POSTROUTING 2>/dev/null
        iptables -t nat -A POSTROUTING -j MASQUERADE
        print_success "NAT 规则已清空"
    else
        apply_rules
    fi

    press_any_key
}

# ---------- 管理开机自启 ----------
do_autostart() {
    print_banner
    echo -e "${BOLD}${BLUE}[ 开机自启管理 ]${NC}"
    echo ""

    local is_enabled=false
    if systemctl is-enabled --quiet iptables-forward.service 2>/dev/null; then
        is_enabled=true
        echo -e "  当前状态: ${GREEN}已启用开机自启${NC}"
    else
        echo -e "  当前状态: ${YELLOW}未启用开机自启${NC}"
    fi
    echo ""

    if $is_enabled; then
        echo -e "  ${RED}1)${NC} 关闭开机自启"
        echo -e "  ${NC}0)${NC} 返回"
        echo ""
        read -r -p "请选择 [0-1]: " choice
        case "$choice" in
            1)
                systemctl disable iptables-forward.service 2>/dev/null
                print_success "已关闭开机自启"
                ;;
            *) return ;;
        esac
    else
        echo -e "  ${GREEN}1)${NC} 开启开机自启"
        echo -e "  ${NC}0)${NC} 返回"
        echo ""
        read -r -p "请选择 [0-1]: " choice
        case "$choice" in
            1)
                create_service
                print_success "已开启开机自启"
                ;;
            *) return ;;
        esac
    fi

    press_any_key
}

# ---------- 主菜单 ----------
show_menu() {
    print_banner

    load_rules
    local rule_count=${#rules_src_port[@]}

    local ip_forward
    ip_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
    if [[ "$ip_forward" == "1" ]]; then
        echo -e "  IP 转发: ${GREEN}● 已开启${NC}    转发规则: ${CYAN}${rule_count} 条${NC}"
    else
        echo -e "  IP 转发: ${RED}● 未开启${NC}    转发规则: ${CYAN}${rule_count} 条${NC}"
    fi

    if systemctl is-enabled --quiet iptables-forward.service 2>/dev/null; then
        echo -e "  开机自启: ${GREEN}● 已启用${NC}"
    else
        echo -e "  开机自启: ${YELLOW}● 未启用${NC}"
    fi
    echo ""

    if [[ $rule_count -gt 0 ]]; then
        echo -e "${BOLD}${BLUE}当前转发:${NC}"
        for ((i=0; i<${#rules_src_port[@]}; i++)); do
            local proto_str=""
            case "${rules_proto[$i]}" in
                tcp) proto_str="TCP" ;;
                udp) proto_str="UDP" ;;
                both) proto_str="TCP+UDP" ;;
            esac
            echo -e "  ${GREEN}[$((i+1))]${NC} ${CYAN}${rules_listen_ip[$i]}${NC} ${CYAN}${rules_src_port[$i]}${NC} → ${CYAN}${rules_dst_ip[$i]}:${rules_dst_port[$i]}${NC} (${proto_str})"
        done
        echo ""
    fi

    echo -e "  ${GREEN}1)${NC} 添加转发规则"
    echo -e "  ${RED}2)${NC} 删除转发规则"
    echo -e "  ${BLUE}3)${NC} 查看当前规则"
    echo -e "  ${CYAN}4)${NC} 重启 iptables 转发"
    echo -e "  ${YELLOW}5)${NC} 开机自启管理"
    echo -e "  ${NC}0)${NC} 退出"
    echo ""

    read -r -p "请选择操作 [0-5]: " choice
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
            3) do_list ;;
            4) do_restart ;;
            5) do_autostart ;;
            0)
                echo ""
                print_info "再见！"
                exit 0
                ;;
            *)
                print_error "无效选择，请输入 0-5"
                sleep 1
                ;;
        esac
    done
}

main
