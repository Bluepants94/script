#!/bin/bash

# ============================================================
#  iptables 端口转发管理脚本
#  功能: 添加/删除/查看/重启 iptables 端口转发规则
#  支持: 单端口、端口段转发，TCP/UDP 协议
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

# ---------- 工具函数 ----------
print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║       iptables 端口转发管理工具              ║"
    echo "║       支持单端口 / 端口段转发                ║"
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
    # 创建配置目录
    mkdir -p "$CONFIG_DIR"

    # 创建配置文件（如果不存在）
    if [[ ! -f "$CONFIG_FILE" ]]; then
        touch "$CONFIG_FILE"
    fi

    # 开启 IP 转发
    if [[ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]]; then
        echo 1 > /proc/sys/net/ipv4/ip_forward
        print_info "已临时开启 IP 转发"
    fi

    # 持久化 IP 转发
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        # 如果存在被注释的行，则取消注释；否则追加
        if grep -q "^#.*net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
            sed -i 's/^#.*net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
        else
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        fi
        sysctl -p >/dev/null 2>&1
        print_info "已持久化开启 IP 转发 (sysctl)"
    fi

    # 确保 iptables 已安装
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

# ---------- 加载规则配置 ----------
# 配置文件格式: 源端口|目标IP|目标端口|协议(tcp/udp/both)
# 例如: 8080|127.0.0.1|1080|both
# 端口段: 8000-9000|192.168.1.1|8000-9000|tcp
load_rules() {
    rules_src_port=()
    rules_dst_ip=()
    rules_dst_port=()
    rules_proto=()

    if [[ ! -f "$CONFIG_FILE" ]]; then
        return
    fi

    while IFS='|' read -r src_port dst_ip dst_port proto; do
        # 跳过空行和注释
        [[ -z "$src_port" || "$src_port" == \#* ]] && continue
        rules_src_port+=("$src_port")
        rules_dst_ip+=("$dst_ip")
        rules_dst_port+=("$dst_port")
        rules_proto+=("$proto")
    done < "$CONFIG_FILE"
}

# ---------- 保存规则配置 ----------
save_rules() {
    cat > "$CONFIG_FILE" <<EOF
# iptables 端口转发规则配置
# 格式: 源端口|目标IP|目标端口|协议(tcp/udp/both)
# 自动生成，请勿手动修改（可通过脚本管理）
EOF

    for ((i=0; i<${#rules_src_port[@]}; i++)); do
        echo "${rules_src_port[$i]}|${rules_dst_ip[$i]}|${rules_dst_port[$i]}|${rules_proto[$i]}" >> "$CONFIG_FILE"
    done
}

# ---------- 应用 iptables 规则 ----------
apply_rules() {
    # 清除旧的转发规则（只清除 nat 表中带有自定义标记的规则）
    # 先清空 nat 表的 PREROUTING 和 POSTROUTING
    iptables -t nat -F PREROUTING 2>/dev/null
    iptables -t nat -F POSTROUTING 2>/dev/null

    # 重新添加 MASQUERADE（源地址伪装，用于转发回包）
    iptables -t nat -A POSTROUTING -j MASQUERADE

    # 遍历所有规则并添加 DNAT
    for ((i=0; i<${#rules_src_port[@]}; i++)); do
        local src="${rules_src_port[$i]}"
        local dst_ip="${rules_dst_ip[$i]}"
        local dst_port="${rules_dst_port[$i]}"
        local proto="${rules_proto[$i]}"

        # 判断是否为端口段
        local port_flag=""
        if [[ "$src" == *-* ]]; then
            # 端口段
            port_flag="--dport ${src}"
        else
            # 单端口
            port_flag="--dport ${src}"
        fi

        # 构建目标地址
        local dst_addr=""
        if [[ "$dst_port" == *-* ]]; then
            dst_addr="${dst_ip}:${dst_port}"
        else
            dst_addr="${dst_ip}:${dst_port}"
        fi

        if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
            iptables -t nat -A PREROUTING -p tcp ${port_flag} -j DNAT --to-destination "${dst_addr}"
        fi

        if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
            iptables -t nat -A PREROUTING -p udp ${port_flag} -j DNAT --to-destination "${dst_addr}"
        fi
    done

    print_success "iptables 规则已应用 (共 ${#rules_src_port[@]} 条转发)"
}

# ---------- 创建应用规则脚本（供 systemd 调用） ----------
create_apply_script() {
    cat > "$SCRIPT_INSTALL_PATH" <<'SCRIPT_EOF'
#!/bin/bash
# iptables-forward 规则应用脚本（由 systemd 服务调用）

CONFIG_FILE="/etc/iptables-forward/rules.conf"

# 开启 IP 转发
echo 1 > /proc/sys/net/ipv4/ip_forward

# 清除旧规则
iptables -t nat -F PREROUTING 2>/dev/null
iptables -t nat -F POSTROUTING 2>/dev/null

# 添加 MASQUERADE
iptables -t nat -A POSTROUTING -j MASQUERADE

# 读取并应用规则
if [[ -f "$CONFIG_FILE" ]]; then
    while IFS='|' read -r src_port dst_ip dst_port proto; do
        [[ -z "$src_port" || "$src_port" == \#* ]] && continue

        if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
            iptables -t nat -A PREROUTING -p tcp --dport "${src_port}" -j DNAT --to-destination "${dst_ip}:${dst_port}"
        fi

        if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
            iptables -t nat -A PREROUTING -p udp --dport "${src_port}" -j DNAT --to-destination "${dst_ip}:${dst_port}"
        fi
    done < "$CONFIG_FILE"
fi

echo "[iptables-forward] 规则已应用"
SCRIPT_EOF

    chmod +x "$SCRIPT_INSTALL_PATH"
}

# ---------- 创建 systemd 服务 ----------
create_service() {
    # 先创建应用脚本
    create_apply_script

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=iptables Port Forwarding Rules
Documentation=https://github.com
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_INSTALL_PATH}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable iptables-forward.service 2>/dev/null
    print_success "已创建 systemd 服务并设置开机自启"
}

# ---------- 自动保存并重启 ----------
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

    # 计算列宽
    local w_idx=4 w_src=6 w_dst=12 w_proto=6
    for ((i=0; i<${#rules_src_port[@]}; i++)); do
        local idx=$((i + 1))
        local idx_len=$(( ${#idx} + 2 ))
        local dst_str="${rules_dst_ip[$i]}:${rules_dst_port[$i]}"
        local proto_str=""
        case "${rules_proto[$i]}" in
            tcp)  proto_str="TCP" ;;
            udp)  proto_str="UDP" ;;
            both) proto_str="TCP+UDP" ;;
            *)    proto_str="${rules_proto[$i]}" ;;
        esac

        (( idx_len > w_idx )) && w_idx=$idx_len
        (( ${#rules_src_port[$i]} > w_src )) && w_src=${#rules_src_port[$i]}
        (( ${#dst_str} > w_dst )) && w_dst=${#dst_str}
        (( ${#proto_str} > w_proto )) && w_proto=${#proto_str}
    done

    # 表头
    local header
    header=$(printf "| %-${w_idx}s | %-${w_src}s | %-${w_dst}s | %-${w_proto}s |" \
        "序号" "源端口" "目标地址" "协议")
    echo -e "  ${BOLD}${header}${NC}"

    # 分隔线
    local sep="|$(repeat_char '-' $((w_idx+2)))|$(repeat_char '-' $((w_src+2)))|$(repeat_char '-' $((w_dst+2)))|$(repeat_char '-' $((w_proto+2)))|"
    echo "  ${sep}"

    # 数据行
    for ((i=0; i<${#rules_src_port[@]}; i++)); do
        local idx=$((i + 1))
        local dst_str="${rules_dst_ip[$i]}:${rules_dst_port[$i]}"
        local proto_str=""
        case "${rules_proto[$i]}" in
            tcp)  proto_str="TCP" ;;
            udp)  proto_str="UDP" ;;
            both) proto_str="TCP+UDP" ;;
            *)    proto_str="${rules_proto[$i]}" ;;
        esac

        local col_idx col_src col_dst col_proto
        col_idx=$(printf "%-${w_idx}s" "[$idx]")
        col_src=$(printf "%-${w_src}s" "${rules_src_port[$i]}")
        col_dst=$(printf "%-${w_dst}s" "$dst_str")
        col_proto=$(printf "%-${w_proto}s" "$proto_str")

        echo -e "  | ${GREEN}${col_idx}${NC} | ${CYAN}${col_src}${NC} | ${CYAN}${col_dst}${NC} | ${CYAN}${col_proto}${NC} |"
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

        # 输入源端口
        local src_port=""
        while true; do
            read -r -p "请输入源端口（单端口如 8080，端口段如 8000-9000）: " src_port
            if [[ "$src_port" =~ ^[0-9]+$ ]]; then
                if [[ "$src_port" -ge 1 && "$src_port" -le 65535 ]]; then
                    break
                fi
                print_error "端口范围: 1-65535"
            elif [[ "$src_port" =~ ^[0-9]+-[0-9]+$ ]]; then
                local p1 p2
                p1=$(echo "$src_port" | cut -d'-' -f1)
                p2=$(echo "$src_port" | cut -d'-' -f2)
                if [[ "$p1" -ge 1 && "$p2" -le 65535 && "$p1" -lt "$p2" ]]; then
                    break
                fi
                print_error "端口段格式错误（确保起始端口 < 结束端口，范围 1-65535）"
            else
                print_error "格式错误！请输入单端口或端口段（如 8080 或 8000-9000）"
            fi
        done

        # 输入目标地址
        local dst_input=""
        local dst_ip="" dst_port=""
        while true; do
            read -r -p "请输入转发目标地址（格式 IP:端口，如 127.0.0.1:1080）: " dst_input
            if [[ "$dst_input" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+(-[0-9]+)?)$ ]]; then
                dst_ip="${BASH_REMATCH[1]}"
                dst_port="${BASH_REMATCH[2]}"

                # 如果源端口是端口段，目标端口也应该是端口段或单端口
                if [[ "$src_port" == *-* && "$dst_port" != *-* ]]; then
                    # 端口段转发到单端口：目标自动使用相同端口段
                    local p1 p2
                    p1=$(echo "$src_port" | cut -d'-' -f1)
                    p2=$(echo "$src_port" | cut -d'-' -f2)
                    dst_port="${p1}-${p2}"
                    print_info "端口段转发：目标端口自动设为 ${dst_port}"
                fi
                break
            else
                print_error "地址格式错误！请使用 IP:端口 格式（如 127.0.0.1:1080）"
            fi
        done

        # 选择协议
        local proto=""
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

        # 显示确认信息
        local proto_display=""
        case "$proto" in
            tcp)  proto_display="TCP" ;;
            udp)  proto_display="UDP" ;;
            both) proto_display="TCP+UDP" ;;
        esac

        echo ""
        echo -e "${GREEN}即将添加转发:${NC}"
        echo -e "  源端口:   ${CYAN}${src_port}${NC}"
        echo -e "  目标地址: ${CYAN}${dst_ip}:${dst_port}${NC}"
        echo -e "  协议:     ${CYAN}${proto_display}${NC}"

        # 添加到规则数组
        rules_src_port+=("$src_port")
        rules_dst_ip+=("$dst_ip")
        rules_dst_port+=("$dst_port")
        rules_proto+=("$proto")

        # 自动保存并应用
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
        echo -e "输入要删除的序号（${CYAN}1-${#rules_src_port[@]}${NC}），输入 ${YELLOW}all${NC} 删除全部，输入 ${NC}0${NC} 返回"
        read -r -p "请选择: " del_input

        if [[ "$del_input" == "0" ]]; then
            break
        fi

        if [[ "$del_input" == "all" || "$del_input" == "ALL" ]]; then
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
        local del_info="${rules_src_port[$del_idx]} → ${rules_dst_ip[$del_idx]}:${rules_dst_port[$del_idx]}"

        # 删除指定条目
        unset 'rules_src_port[del_idx]'
        unset 'rules_dst_ip[del_idx]'
        unset 'rules_dst_port[del_idx]'
        unset 'rules_proto[del_idx]'

        # 重新索引数组
        rules_src_port=("${rules_src_port[@]}")
        rules_dst_ip=("${rules_dst_ip[@]}")
        rules_dst_port=("${rules_dst_port[@]}")
        rules_proto=("${rules_proto[@]}")

        # 自动保存并应用
        auto_save_and_apply
        print_success "已删除转发: ${del_info}"

        if [[ ${#rules_src_port[@]} -eq 0 ]]; then
            print_info "所有规则已清空"
            break
        fi

        # 刷新显示
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

    # 显示 iptables nat 表实际规则
    echo -e "${BOLD}${BLUE}[ iptables NAT 表规则 ]${NC}"
    echo ""
    iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | head -30
    echo ""

    # 显示 IP 转发状态
    local ip_forward
    ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)
    if [[ "$ip_forward" == "1" ]]; then
        echo -e "  IP 转发状态: ${GREEN}已开启${NC}"
    else
        echo -e "  IP 转发状态: ${RED}未开启${NC}"
    fi

    # 显示开机自启状态
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
        print_warn "当前没有转发规则，清除所有 NAT 规则"
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
            *)
                return
                ;;
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
            *)
                return
                ;;
        esac
    fi

    press_any_key
}

# ---------- 主菜单 ----------
show_menu() {
    print_banner

    # 加载规则以显示状态
    load_rules
    local rule_count=${#rules_src_port[@]}

    # 显示简要状态
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

    # 如果有规则，简要展示
    if [[ $rule_count -gt 0 ]]; then
        echo -e "${BOLD}${BLUE}当前转发:${NC}"
        for ((i=0; i<${#rules_src_port[@]}; i++)); do
            local proto_str=""
            case "${rules_proto[$i]}" in
                tcp)  proto_str="TCP" ;;
                udp)  proto_str="UDP" ;;
                both) proto_str="TCP+UDP" ;;
            esac
            echo -e "  ${GREEN}[$((i+1))]${NC} ${CYAN}${rules_src_port[$i]}${NC} → ${CYAN}${rules_dst_ip[$i]}:${rules_dst_port[$i]}${NC} (${proto_str})"
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

# 启动脚本
main
