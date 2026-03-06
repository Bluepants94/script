#!/bin/bash

# ============================================================
#  端口转发管理脚本（增强版）
#  功能: 添加/删除/重启 端口转发规则
#  后端: nftables（主） / iptables（备用）
#  支持: 单端口、端口段（源=目标）、监听IP区分
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
SCRIPT_INSTALL_PATH="/usr/local/bin/iptables-forward"
RAW_BASE_URL="https://raw.githubusercontent.com/Bluepants94/script/refs/heads/main/iptables_forward"
RAW_SCRIPT_URL="${RAW_BASE_URL}/iptables-forward"
RAW_SCRIPT_COMPAT_URL="${RAW_BASE_URL}/iptables-forward-apply"
RAW_SERVICE_URL="${RAW_BASE_URL}/iptables-forward.service"
WATCH_CRON_TAG="# iptables-forward-domain"
RESTART_CRON_TAG="# iptables-forward-restart"
LEGACY_WATCH_CRON_TAG="# iptables-forward-watch"
LOCK_FILE="${CONFIG_DIR}/rules.conf.lock"
CHAIN_PRE="IPTFWD-PRE"
CHAIN_POST="IPTFWD-POST"
NFT_TABLE="portfwd"

# ---------- 全局变量 ----------
FW_BACKEND=""
# ---------- 全局数组 ----------
rules_listen_ip=()
rules_src_port=()
rules_dst_ip=()
rules_dst_port=()
rules_proto=()
rules_resolved_ip=()
rules_check_interval=()
rules_last_check_ts=()
rules_is_domain=()
GLOBAL_WATCH_ENABLED=1
GLOBAL_WATCH_INTERVAL_MINUTES=1
GLOBAL_RESTART_INTERVAL_MINUTES=0
LAST_RESULT_TYPE=""
LAST_RESULT_MSG=""

# ---------- 工具函数 ----------
print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║       端口转发管理工具 (nftables 增强版)     ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_info()    { echo -e "${GREEN}[信息]${NC} $1"; }
print_warn()    { echo -e "${YELLOW}[警告]${NC} $1"; }
print_error()   { echo -e "${RED}[错误]${NC} $1" >&2; }
print_success() { echo -e "${GREEN}[成功]${NC} $1"; }

set_last_result() { LAST_RESULT_TYPE="$1"; LAST_RESULT_MSG="$2"; }

show_last_result() {
    [[ -z "$LAST_RESULT_MSG" ]] && return
    case "$LAST_RESULT_TYPE" in
        success) print_success "$LAST_RESULT_MSG" ;;
        warn)    print_warn "$LAST_RESULT_MSG" ;;
        error)   print_error "$LAST_RESULT_MSG" ;;
        *)       print_info "$LAST_RESULT_MSG" ;;
    esac
    echo ""
    LAST_RESULT_TYPE=""
    LAST_RESULT_MSG=""
}

read_menu_choice() {
    local prompt="$1" regex="$2" default_value="${3:-}" value
    while true; do
        read -r -p "$prompt" value
        [[ -z "$value" && -n "$default_value" ]] && value="$default_value"
        [[ "$value" =~ $regex ]] && { echo "$value"; return 0; }
        print_error "输入无效，请重新输入！"
    done
}

read_confirm_yn_default() {
    local prompt="$1" default_value="$2" value
    while true; do
        read -r -p "$prompt" value
        value=${value:-$default_value}
        case "$value" in
            Y|y) echo "Y"; return 0 ;;
            N|n) echo "N"; return 0 ;;
            *)   print_error "输入无效，请重新输入！" ;;
        esac
    done
}

proto_to_label() {
    case "$1" in
        tcp) echo "TCP" ;; udp) echo "UDP" ;; both) echo "TCP+UDP" ;; *) echo "$1" ;;
    esac
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

is_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [[ "$o" -ge 0 && "$o" -le 255 ]] || return 1
    done
    return 0
}

is_valid_domain() {
    local domain="$1"
    [[ ${#domain} -le 253 ]] || return 1
    [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

resolve_domain_ipv4_once() {
    local domain="$1" ip=""
    if command -v dig >/dev/null 2>&1; then
        ip=$(dig @1.1.1.1 +short A "$domain" 2>/dev/null | grep -oE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n 1)
        is_valid_ipv4 "$ip" && { echo "$ip"; return 0; }
        ip=$(dig @8.8.8.8 +short A "$domain" 2>/dev/null | grep -oE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n 1)
        is_valid_ipv4 "$ip" && { echo "$ip"; return 0; }
    fi
    ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1{print $1}')
    is_valid_ipv4 "$ip" && { echo "$ip"; return 0; }
    return 1
}

# ---------- 全局设置归一化 ----------
normalize_interval_var() {
    local var_name="$1"
    local val="${!var_name}"
    if [[ ! "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 0 ]]; then
        eval "$var_name=0"
    fi
}

normalize_global_settings() {
    normalize_interval_var GLOBAL_WATCH_INTERVAL_MINUTES
    normalize_interval_var GLOBAL_RESTART_INTERVAL_MINUTES
    [[ "$GLOBAL_WATCH_INTERVAL_MINUTES" -eq 0 ]] && GLOBAL_WATCH_ENABLED=0 || GLOBAL_WATCH_ENABLED=1
}

format_interval_label() {
    local minutes="$1"
    [[ "$minutes" =~ ^[0-9]+$ ]] || minutes=0
    if [[ "$minutes" -eq 0 ]]; then echo "0分钟"
    elif (( minutes % 1440 == 0 )); then echo "$((minutes / 1440))天"
    elif (( minutes % 60 == 0 )); then echo "$((minutes / 60))小时"
    else echo "${minutes}分钟"
    fi
}

# ---------- Cron 任务管理 ----------
set_cron_task_minutes() {
    local tag="$1" script_path="$2" minutes="$3"
    command -v crontab >/dev/null 2>&1 || return 1

    local current filtered cron_line new_content
    current=$(crontab -l 2>/dev/null || true)
    filtered=$(printf "%s\n" "$current" | grep -vF "$tag" || true)

    if [[ "$minutes" -eq 0 ]]; then
        if [[ -n "$filtered" ]]; then
            printf "%s\n" "$filtered" | crontab -
        else
            crontab -r 2>/dev/null || true
        fi
        return 0
    fi

    if [[ "$minutes" -lt 60 ]]; then
        cron_line="*/${minutes} * * * * ${script_path} >/dev/null 2>&1 ${tag} interval=${minutes}"
    elif (( minutes % 1440 == 0 )); then
        local days=$((minutes / 1440))
        cron_line="0 0 */${days} * * ${script_path} >/dev/null 2>&1 ${tag} interval=${minutes}"
    elif (( minutes % 60 == 0 )); then
        local hours=$((minutes / 60))
        cron_line="0 */${hours} * * * ${script_path} >/dev/null 2>&1 ${tag} interval=${minutes}"
    else
        cron_line="* * * * * __IPTFWD_INTERVAL=${minutes}; [ \$(( (\$(date +\\%s)/60) % __IPTFWD_INTERVAL )) -eq 0 ] && ${script_path} >/dev/null 2>&1 ${tag} interval=${minutes}"
    fi

    if [[ -n "$filtered" ]]; then
        new_content="${filtered}"$'\n'"${cron_line}"
    else
        new_content="$cron_line"
    fi
    printf "%s\n" "$new_content" | crontab -
}

sync_cron_tasks_from_config() {
    normalize_global_settings
    set_cron_task_minutes "$WATCH_CRON_TAG" "$SCRIPT_INSTALL_PATH --watch" "$GLOBAL_WATCH_INTERVAL_MINUTES" >/dev/null 2>&1 || true
    set_cron_task_minutes "$RESTART_CRON_TAG" "$SCRIPT_INSTALL_PATH" "$GLOBAL_RESTART_INTERVAL_MINUTES" >/dev/null 2>&1 || true
}

# ---------- 自定义链清理 ----------
remove_custom_chain() {
    local cmd="$1" chain="$2"
    command -v "$cmd" >/dev/null 2>&1 || return 0
    while "$cmd" -t nat -D PREROUTING -j "$chain" >/dev/null 2>&1; do :; done
    while "$cmd" -t nat -D POSTROUTING -j "$chain" >/dev/null 2>&1; do :; done
    "$cmd" -t nat -F "$chain" >/dev/null 2>&1 || true
    "$cmd" -t nat -X "$chain" >/dev/null 2>&1 || true
}

remove_nft_tables() {
    command -v nft >/dev/null 2>&1 || return 0
    nft delete table ip "$NFT_TABLE" 2>/dev/null || true
    nft delete table ip6 "$NFT_TABLE" 2>/dev/null || true
}

remove_all_custom_chains() {
    # 清理 nftables 表
    remove_nft_tables
    # 清理 iptables 自定义链
    local cmd chain
    for cmd in iptables ip6tables; do
        for chain in "$CHAIN_PRE" "$CHAIN_POST"; do
            remove_custom_chain "$cmd" "$chain"
        done
    done
}

# ---------- 卸载 ----------
do_uninstall() {
    local confirm
    confirm=$(read_confirm_yn_default "是否确认移除脚本？[Y/N]（默认: N）: " "N")
    [[ "$confirm" == "N" ]] && { set_last_result "warn" "已取消移除"; return; }

    systemctl disable --now iptables-forward.service >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true

    set_cron_task_minutes "$WATCH_CRON_TAG" "$SCRIPT_INSTALL_PATH --watch" 0 >/dev/null 2>&1 || true
    set_cron_task_minutes "$LEGACY_WATCH_CRON_TAG" "$SCRIPT_INSTALL_PATH --watch" 0 >/dev/null 2>&1 || true
    set_cron_task_minutes "$RESTART_CRON_TAG" "$SCRIPT_INSTALL_PATH" 0 >/dev/null 2>&1 || true

    remove_all_custom_chains

    rm -f "$SCRIPT_INSTALL_PATH" "/usr/local/bin/iptables-forward-apply" >/dev/null 2>&1 || true
    rm -f "$CONFIG_FILE" "$LOCK_FILE" >/dev/null 2>&1 || true
    rm -rf "$CONFIG_DIR" >/dev/null 2>&1 || true

    set_last_result "success" "移除完成：已清理脚本相关文件、cron 任务与自定义链"
}

# ---------- 间隔设置（通用：域名解析 / 自动重启） ----------
update_interval_setting() {
    local mode="$1" minutes="$2"
    local var_name cron_tag cron_cmd label_on label_off

    if [[ "$mode" == "watch" ]]; then
        var_name="GLOBAL_WATCH_INTERVAL_MINUTES"
        cron_tag="$WATCH_CRON_TAG"
        cron_cmd="$SCRIPT_INSTALL_PATH --watch"
        label_on="域名解析"; label_off="域名解析定时任务"
        GLOBAL_WATCH_INTERVAL_MINUTES="$minutes"
        [[ "$minutes" -eq 0 ]] && GLOBAL_WATCH_ENABLED=0 || GLOBAL_WATCH_ENABLED=1
    else
        var_name="GLOBAL_RESTART_INTERVAL_MINUTES"
        cron_tag="$RESTART_CRON_TAG"
        cron_cmd="$SCRIPT_INSTALL_PATH"
        label_on="自动重启"; label_off="自动重启定时任务"
        GLOBAL_RESTART_INTERVAL_MINUTES="$minutes"
    fi

    save_rules

    if set_cron_task_minutes "$cron_tag" "$cron_cmd" "$minutes" >/dev/null 2>&1; then
        if [[ "$minutes" -eq 0 ]]; then
            set_last_result "success" "已关闭${label_off}"
        else
            set_last_result "success" "已设置${label_on}为每 $(format_interval_label "$minutes") 执行"
        fi
    else
        set_last_result "error" "Cron 任务更新失败"
    fi
}

# ---------- 全局设置读取 ----------
read_global_settings_from_config() {
    GLOBAL_WATCH_ENABLED=1
    GLOBAL_WATCH_INTERVAL_MINUTES=1
    GLOBAL_RESTART_INTERVAL_MINUTES=0

    [[ -f "$CONFIG_FILE" ]] || return 0

    local val
    for key in GLOBAL_WATCH_ENABLED GLOBAL_WATCH_INTERVAL_MINUTES GLOBAL_RESTART_INTERVAL_MINUTES; do
        val=$(grep -m1 "^${key}=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2)
        [[ -n "$val" ]] && eval "$key='$val'"
    done
    normalize_global_settings
}

# ---------- 端口表达式解析 ----------
parse_port_expr() {
    local expr="$1"
    if [[ "$expr" =~ ^[0-9]+$ ]]; then
        [[ "$expr" -ge 1 && "$expr" -le 65535 ]] && { echo "single|$expr|$expr"; return 0; }
        return 1
    fi
    if [[ "$expr" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
        [[ "$a" -ge 1 && "$b" -le 65535 && "$a" -lt "$b" ]] && { echo "range|$a|$b"; return 0; }
        return 1
    fi
    return 1
}

# ---------- 文件下载 ----------
download_file_silent() {
    local url="$1" target="$2" mode="$3"
    local tmp_file="${target}.tmp.$$"

    if ! curl -fsSL "$url" -o "$tmp_file" >/dev/null 2>&1; then
        rm -f "$tmp_file" >/dev/null 2>&1; return 1
    fi

    # 校验下载文件：非空且以 shebang 或 [Unit] 开头
    if [[ ! -s "$tmp_file" ]]; then
        rm -f "$tmp_file" >/dev/null 2>&1; return 1
    fi
    local head_line
    head_line=$(head -c 20 "$tmp_file" 2>/dev/null)
    if [[ "$head_line" != "#!/bin/bash"* && "$head_line" != "[Unit]"* ]]; then
        rm -f "$tmp_file" >/dev/null 2>&1; return 1
    fi

    mv -f "$tmp_file" "$target" >/dev/null 2>&1 || { rm -f "$tmp_file" >/dev/null 2>&1; return 1; }
    [[ -n "$mode" ]] && chmod "$mode" "$target" >/dev/null 2>&1
    return 0
}

sync_support_files() {
    local force_update="${1:-false}"

    if [[ "$force_update" == "true" || ! -s "$SCRIPT_INSTALL_PATH" ]]; then
        download_file_silent "$RAW_SCRIPT_URL" "$SCRIPT_INSTALL_PATH" "755" || \
        download_file_silent "$RAW_SCRIPT_COMPAT_URL" "$SCRIPT_INSTALL_PATH" "755" || return 1
    else
        chmod 755 "$SCRIPT_INSTALL_PATH" >/dev/null 2>&1
    fi

    if [[ "$force_update" == "true" || ! -s "$SERVICE_FILE" ]]; then
        download_file_silent "$RAW_SERVICE_URL" "$SERVICE_FILE" "644" || return 1
    fi

    [[ -f "$SERVICE_FILE" ]] && sed -i "s|^ExecStart=.*|ExecStart=${SCRIPT_INSTALL_PATH}|" "$SERVICE_FILE" >/dev/null 2>&1 || true
    return 0
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

    # 开启 IP 转发
    if [[ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]]; then
        echo 1 > /proc/sys/net/ipv4/ip_forward
        print_info "已临时开启 IP 转发"
    fi
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        if grep -q "^#\s*net\.ipv4\.ip_forward\s*=" /etc/sysctl.conf 2>/dev/null; then
            sed -i 's/^#\s*net\.ipv4\.ip_forward\s*=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
        else
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        fi
        sysctl -p >/dev/null 2>&1
        print_info "已持久化开启 IP 转发 (sysctl)"
    fi

    # 检测防火墙后端: nftables 优先，iptables 备用
    if command -v nft &>/dev/null; then
        FW_BACKEND="nft"
        print_info "防火墙后端: nftables"
    elif command -v iptables &>/dev/null; then
        FW_BACKEND="iptables"
        print_info "防火墙后端: iptables（备用）"
    else
        print_warn "未检测到 nftables 或 iptables，尝试安装..."
        if command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y nftables && FW_BACKEND="nft"
        elif command -v yum &>/dev/null; then
            yum install -y nftables && FW_BACKEND="nft"
        elif command -v dnf &>/dev/null; then
            dnf install -y nftables && FW_BACKEND="nft"
        fi
        if [[ -z "$FW_BACKEND" ]]; then
            # nftables 安装失败，回退尝试 iptables
            if command -v apt-get &>/dev/null; then
                apt-get install -y iptables && FW_BACKEND="iptables"
            elif command -v yum &>/dev/null; then
                yum install -y iptables && FW_BACKEND="iptables"
            elif command -v dnf &>/dev/null; then
                dnf install -y iptables && FW_BACKEND="iptables"
            fi
        fi
        if [[ -z "$FW_BACKEND" ]]; then
            print_error "无法安装 nftables 或 iptables，请手动安装后重试"; exit 1
        fi
        print_info "防火墙后端: ${FW_BACKEND}"
    fi

    sync_support_files false || {
        print_error "必需文件同步失败，请检查网络连接或 GitHub 地址"; exit 1
    }

    read_global_settings_from_config

    if ! grep -q '^GLOBAL_WATCH_ENABLED=' "$CONFIG_FILE" 2>/dev/null || \
       ! grep -q '^GLOBAL_WATCH_INTERVAL_MINUTES=' "$CONFIG_FILE" 2>/dev/null || \
       ! grep -q '^GLOBAL_RESTART_INTERVAL_MINUTES=' "$CONFIG_FILE" 2>/dev/null; then
        load_rules
        save_rules
    fi

    sync_cron_tasks_from_config
}

# ---------- 本机IP探测 ----------
get_local_ipv4_list() {
    local_ips=()
    local_ifaces=()
    while IFS='|' read -r iface cidr; do
        [[ -z "$iface" || -z "$cidr" ]] && continue
        local_ips+=("${cidr%%/*}")
        local_ifaces+=("$iface")
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2"|"$4}')
}

choose_listen_ip() {
    SELECTED_LISTEN_IP="0.0.0.0"
    get_local_ipv4_list

    echo ""
    echo -e "${CYAN}请选择监听IP:${NC}"
    echo "  1) 0.0.0.0"

    local next_idx=2
    for ((i=0; i<${#local_ips[@]}; i++)); do
        local tag="公网"
        is_private_ip "${local_ips[$i]}" && tag="内网"
        echo "  ${next_idx}) ${local_ips[$i]} (${local_ifaces[$i]}, ${tag})"
        next_idx=$((next_idx + 1))
    done

    local manual_idx=$next_idx
    echo "  ${manual_idx}) 手动输入IP"
    echo -e "  ${NC}0) 返回主菜单${NC}"

    local choice
    while true; do
        read -r -p "请选择 [0-${manual_idx}]（默认: 1）: " choice
        choice=${choice:-1}

        [[ "$choice" == "0" ]] && return 1
        [[ "$choice" == "1" ]] && { SELECTED_LISTEN_IP="0.0.0.0"; return 0; }

        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 2 ]] && [[ "$choice" -lt "$manual_idx" ]]; then
            SELECTED_LISTEN_IP="${local_ips[$((choice - 2))]}"
            return 0
        fi

        if [[ "$choice" == "$manual_idx" ]]; then
            while true; do
                local manual_ip
                read -r -p "请输入监听IP: " manual_ip
                if is_valid_ipv4 "$manual_ip"; then
                    SELECTED_LISTEN_IP="$manual_ip"
                    return 0
                fi
                print_error "IP 格式无效或八位组超出范围，请重新输入！"
            done
        fi

        print_error "输入无效，请重新输入！"
    done
}

# ---------- 加载规则配置 ----------
load_rules() {
    read_global_settings_from_config

    rules_listen_ip=(); rules_src_port=(); rules_dst_ip=(); rules_dst_port=()
    rules_proto=(); rules_resolved_ip=(); rules_check_interval=()
    rules_last_check_ts=(); rules_is_domain=()

    [[ -f "$CONFIG_FILE" ]] || return

    while IFS='|' read -r c1 c2 c3 c4 c5 c6 c7 c8 c9; do
        [[ -z "$c1" || "$c1" == \#* ]] && continue
        [[ "$c1" =~ ^GLOBAL_ ]] && continue

        if [[ -n "$c9" ]]; then
            # 9列格式
            rules_listen_ip+=("$c1"); rules_src_port+=("$c2"); rules_dst_ip+=("$c3")
            rules_dst_port+=("$c4"); rules_proto+=("$c5"); rules_resolved_ip+=("$c6")
            rules_check_interval+=("$c7"); rules_last_check_ts+=("$c8"); rules_is_domain+=("$c9")
        elif [[ -n "$c5" ]]; then
            # 5列格式
            rules_listen_ip+=("$c1"); rules_src_port+=("$c2"); rules_dst_ip+=("$c3")
            rules_dst_port+=("$c4"); rules_proto+=("$c5"); rules_resolved_ip+=("$c3")
            rules_check_interval+=("0"); rules_last_check_ts+=("0"); rules_is_domain+=("0")
        elif [[ -n "$c4" ]]; then
            # 4列旧格式
            rules_listen_ip+=("0.0.0.0"); rules_src_port+=("$c1"); rules_dst_ip+=("$c2")
            rules_dst_port+=("$c3"); rules_proto+=("$c4"); rules_resolved_ip+=("$c2")
            rules_check_interval+=("0"); rules_last_check_ts+=("0"); rules_is_domain+=("0")
        fi
    done < "$CONFIG_FILE"
}

# ---------- 保存规则配置 ----------
save_rules() {
    normalize_global_settings

    cat > "$CONFIG_FILE" <<EOF_CONF
# 端口转发规则配置（后端: nftables/iptables）
# 全局域名解析开关(1=启动,0=暂停)
GLOBAL_WATCH_ENABLED=${GLOBAL_WATCH_ENABLED}
# 全局域名解析间隔(分钟, >=0；0=关闭)
GLOBAL_WATCH_INTERVAL_MINUTES=${GLOBAL_WATCH_INTERVAL_MINUTES}
# 全局自动重启间隔(分钟, >=0；0=关闭)
GLOBAL_RESTART_INTERVAL_MINUTES=${GLOBAL_RESTART_INTERVAL_MINUTES}
# -------------------------------------------------
# 格式: 监听IP|源端口|目标主机|目标端口|协议|解析IP|检查间隔秒|上次检查时间戳|是否域名(1/0)
# 自动生成，请勿手动修改（可通过脚本管理）
EOF_CONF

    for ((i=0; i<${#rules_src_port[@]}; i++)); do
        local d_resolved="${rules_resolved_ip[$i]:-${rules_dst_ip[$i]}}"
        local d_interval="${rules_check_interval[$i]}"
        local d_last="${rules_last_check_ts[$i]}"
        local d_is_domain="${rules_is_domain[$i]}"

        [[ "$d_is_domain" == "1" ]] && d_interval=$((GLOBAL_WATCH_INTERVAL_MINUTES * 60))
        [[ "$d_interval" =~ ^[0-9]+$ ]] || d_interval=0
        [[ "$d_last" =~ ^[0-9]+$ ]] || d_last=0
        [[ "$d_is_domain" == "1" ]] || d_is_domain=0

        echo "${rules_listen_ip[$i]}|${rules_src_port[$i]}|${rules_dst_ip[$i]}|${rules_dst_port[$i]}|${rules_proto[$i]}|${d_resolved}|${d_interval}|${d_last}|${d_is_domain}" >> "$CONFIG_FILE"
    done
}

# ---------- 应用转发规则 ----------
apply_rules_core() {
    [[ -x "$SCRIPT_INSTALL_PATH" ]] || sync_support_files false
    "$SCRIPT_INSTALL_PATH" >/dev/null 2>&1
}

# ---------- 创建 systemd 服务 ----------
create_service() {
    sync_support_files false || return 1
    systemctl daemon-reload >/dev/null 2>&1
    systemctl is-enabled --quiet iptables-forward.service 2>/dev/null || \
        systemctl enable iptables-forward.service 2>/dev/null
    return 0
}

# ---------- 更新脚本文件 ----------
do_update() {
    print_banner
    echo -e "${CYAN}请稍后...${NC}"
    if sync_support_files true && systemctl daemon-reload >/dev/null 2>&1; then
        set_last_result "success" "更新完成！"
    else
        set_last_result "error" "更新失败，请检查网络连接或 GitHub 地址"
    fi
}

# ---------- 通用间隔管理菜单（域名解析 / 自动重启） ----------
do_interval_manage() {
    local mode="$1" title="$2" current_var="$3" unit_label="$4"

    print_banner
    echo -e "${BOLD}${BLUE}[ ${title} ]${NC}"
    echo ""

    load_rules
    local current_minutes="${!current_var:-0}"

    if [[ "$current_minutes" -gt 0 ]]; then
        echo -e "  当前状态: ${GREEN}已启动${NC} (${CYAN}$(format_interval_label "$current_minutes")${NC})"
    else
        echo -e "  当前状态: ${YELLOW}已暂停${NC}"
    fi
    echo ""

    echo -e "  ${CYAN}1)${NC} 定时${unit_label}"
    echo -e "  ${CYAN}2)${NC} 立即${unit_label}"
    echo -e "  ${NC}0)${NC} 返回"
    echo ""

    local sub_choice
    sub_choice=$(read_menu_choice "请选择 [0-2]: " '^[0-2]$')
    case "$sub_choice" in
        1)
            local new_minutes
            while true; do
                read -r -p "请输入${unit_label}间隔（单位：分钟，默认: 0；0=关闭）: " new_minutes
                new_minutes=${new_minutes:-0}
                if [[ "$new_minutes" =~ ^[0-9]+$ ]] && [[ "$new_minutes" -ge 0 ]]; then
                    update_interval_setting "$mode" "$new_minutes"
                    return
                fi
                print_error "输入无效，请重新输入！"
            done
            ;;
        2)
            if [[ "$mode" == "watch" ]]; then
                [[ -x "$SCRIPT_INSTALL_PATH" ]] || sync_support_files false || {
                    set_last_result "error" "立即解析失败：脚本不存在且下载失败"; return
                }
                if "$SCRIPT_INSTALL_PATH" --watch >/dev/null 2>&1; then
                    set_last_result "success" "已立即执行一次域名解析"
                else
                    set_last_result "error" "立即解析失败：执行异常"
                fi
            else
                do_restart
            fi
            ;;
        0) ;;
    esac
}

# ---------- 规则数组操作 ----------
clear_all_rules() {
    rules_listen_ip=(); rules_src_port=(); rules_dst_ip=(); rules_dst_port=()
    rules_proto=(); rules_resolved_ip=(); rules_check_interval=()
    rules_last_check_ts=(); rules_is_domain=()
}

remove_rule_at_index() {
    local idx="$1"
    local arr
    for arr in rules_listen_ip rules_src_port rules_dst_ip rules_dst_port rules_proto \
               rules_resolved_ip rules_check_interval rules_last_check_ts rules_is_domain; do
        unset "${arr}[idx]"
        eval "$arr=(\"\${${arr}[@]}\")"
    done
}

# ---------- 自动保存并应用 ----------
auto_save_and_apply() {
    local success_msg="${1:-操作成功！}" fail_msg="${2:-操作失败，请检查防火墙后端环境}"
    save_rules
    if ! sync_support_files false; then
        set_last_result "error" "操作失败：应用脚本下载失败，请检查网络连接或 GitHub 地址"
        return 1
    fi
    if apply_rules_core; then
        set_last_result "success" "$success_msg"
    else
        set_last_result "error" "$fail_msg"
        return 1
    fi
}

# ---------- 打印规则列表 ----------
print_rules_home_style() {
    if [[ ${#rules_src_port[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}(暂无转发规则)${NC}"; return
    fi
    for ((i=0; i<${#rules_src_port[@]}; i++)); do
        local proto_str mark=""
        proto_str=$(proto_to_label "${rules_proto[$i]}")
        [[ "${rules_is_domain[$i]}" == "1" ]] && mark=" [域名→${rules_resolved_ip[$i]}]"
        echo -e "  ${GREEN}[$((i+1))]${NC} ${CYAN}${rules_listen_ip[$i]}${NC} ${CYAN}${rules_src_port[$i]}${NC} → ${CYAN}${rules_dst_ip[$i]}:${rules_dst_port[$i]}${NC} (${proto_str})${mark}"
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

    echo -e "${BOLD}${CYAN}--- 新增转发 ---${NC}"

    # 选择监听IP
    choose_listen_ip || return
    local listen_ip="$SELECTED_LISTEN_IP"

    # 输入源端口
    local src_port src_meta src_type src_start src_end
    while true; do
        read -r -p "请输入源端口（单端口如 8080，端口段如 8000-9000）: " src_port
        src_meta=$(parse_port_expr "$src_port") || { print_error "输入无效，请重新输入！"; continue; }
        IFS='|' read -r src_type src_start src_end <<< "$src_meta"
        break
    done

    # 输入目标地址
    local dst_host resolved_ip is_domain check_interval_seconds
    while true; do
        read -r -p "请输入目标地址（IPv4或域名）: " dst_host
        if is_valid_ipv4 "$dst_host"; then
            is_domain="0"; resolved_ip="$dst_host"; check_interval_seconds=0; break
        fi
        if is_valid_domain "$dst_host"; then
            is_domain="1"; check_interval_seconds=$((GLOBAL_WATCH_INTERVAL_MINUTES * 60))
            resolved_ip=$(resolve_domain_ipv4_once "$dst_host" || true)
            if ! is_valid_ipv4 "$resolved_ip"; then
                print_error "域名解析失败，请检查域名是否正确或网络是否可用！"; continue
            fi
            break
        fi
        print_error "输入无效，请重新输入！"
    done

    # 输入目标端口
    local dst_port_input dst_port dst_meta dst_type dst_start dst_end
    while true; do
        read -r -p "请输入目标端口（单端口/端口段，回车=与源端口相同）: " dst_port_input
        dst_port_input=${dst_port_input:-$src_port}
        dst_meta=$(parse_port_expr "$dst_port_input") || { print_error "输入无效，请重新输入！"; continue; }
        IFS='|' read -r dst_type dst_start dst_end <<< "$dst_meta"

        if [[ "$src_type" == "single" && "$dst_type" == "single" ]]; then
            dst_port="$dst_port_input"; break
        elif [[ "$src_type" == "range" && "$dst_type" == "range" ]]; then
            local src_len=$(( src_end - src_start + 1 ))
            local dst_len=$(( dst_end - dst_start + 1 ))
            if [[ "$src_len" -eq "$dst_len" ]]; then
                dst_port="$dst_port_input"; break
            fi
        fi
        print_error "输入无效，请重新输入！"
    done

    # 选择协议
    local proto
    echo ""
    echo -e "${CYAN}选择转发协议:${NC}"
    echo "  1) TCP+UDP（默认）"
    echo "  2) 仅 TCP"
    echo "  3) 仅 UDP"
    while true; do
        read -r -p "请选择 [1-3]（默认: 1）: " proto_choice
        proto_choice=${proto_choice:-1}
        case "$proto_choice" in
            1) proto="both"; break ;; 2) proto="tcp"; break ;; 3) proto="udp"; break ;;
            *) print_error "输入无效，请重新输入！" ;;
        esac
    done

    echo ""
    echo -e "${GREEN}即将添加转发:${NC}"
    echo -e "  监听IP:   ${CYAN}${listen_ip}${NC}"
    echo -e "  源端口:   ${CYAN}${src_port}${NC}"
    echo -e "  目标地址: ${CYAN}${dst_host}:${dst_port}${NC}"
    if [[ "$is_domain" == "1" ]]; then
        echo -e "  域名解析: ${CYAN}${resolved_ip}${NC}"
        echo -e "  检测间隔: ${CYAN}${GLOBAL_WATCH_INTERVAL_MINUTES} 分钟（全局）${NC}"
    fi
    echo -e "  协议:     ${CYAN}$(proto_to_label "$proto")${NC}"

    # 检查重复规则
    for ((i=0; i<${#rules_src_port[@]}; i++)); do
        if [[ "${rules_listen_ip[$i]}" == "$listen_ip" && "${rules_src_port[$i]}" == "$src_port" ]]; then
            local existing_proto="${rules_proto[$i]}"
            if [[ "$existing_proto" == "both" || "$proto" == "both" || "$existing_proto" == "$proto" ]]; then
                print_warn "检测到冲突：已存在规则 [$((i+1))] ${listen_ip} ${src_port} → ${rules_dst_ip[$i]}:${rules_dst_port[$i]} ($(proto_to_label "$existing_proto"))"
                local confirm_dup
                confirm_dup=$(read_confirm_yn_default "源端口冲突，是否仍要添加？[Y/N]（默认: N）: " "N")
                [[ "$confirm_dup" == "N" ]] && { set_last_result "warn" "已取消添加（源端口冲突）"; return; }
                break
            fi
        fi
    done

    local confirm_add
    confirm_add=$(read_confirm_yn_default "是否确认添加？[Y/N]（默认: Y）: " "Y")
    [[ "$confirm_add" == "N" ]] && { set_last_result "warn" "已取消添加"; return; }

    rules_listen_ip+=("$listen_ip"); rules_src_port+=("$src_port")
    rules_dst_ip+=("$dst_host"); rules_dst_port+=("$dst_port")
    rules_proto+=("$proto"); rules_resolved_ip+=("$resolved_ip")
    rules_check_interval+=("$check_interval_seconds"); rules_last_check_ts+=("0")
    rules_is_domain+=("$is_domain")

    auto_save_and_apply "添加成功！" "添加失败：规则已保存，但应用失败，请检查防火墙后端环境"
}

# ---------- 删除转发规则 ----------
do_delete() {
    print_banner
    echo -e "${BOLD}${RED}[ 删除转发规则 ]${NC}"
    echo ""

    load_rules
    if [[ ${#rules_src_port[@]} -eq 0 ]]; then
        set_last_result "warn" "当前没有转发规则"; return
    fi

    echo -e "${BOLD}${BLUE}当前转发规则:${NC}"
    print_rules_home_style

    while true; do
        echo ""
        echo -e "输入序号（${CYAN}1-${#rules_src_port[@]}${NC}），输入 ${YELLOW}all${NC} 删除全部，输入 ${NC}0${NC} 返回"
        read -r -p "请选择: " del_input

        [[ "$del_input" == "0" ]] && return

        if [[ "$del_input" == "all" || "$del_input" == "ALL" ]]; then
            local confirm
            confirm=$(read_confirm_yn_default "确认删除全部规则？[Y/N]（默认: N）: " "N")
            [[ "$confirm" == "N" ]] && { set_last_result "warn" "已取消删除"; return; }
            clear_all_rules
            auto_save_and_apply "已删除全部转发规则！" "删除失败：规则已保存，但应用失败，请检查防火墙后端环境"
            return
        fi

        if [[ ! "$del_input" =~ ^[0-9]+$ ]] || [[ "$del_input" -lt 1 ]] || [[ "$del_input" -gt ${#rules_src_port[@]} ]]; then
            print_error "输入无效，请重新输入！"; continue
        fi

        local confirm
        confirm=$(read_confirm_yn_default "确认删除该规则？[Y/N]（默认: N）: " "N")
        [[ "$confirm" == "N" ]] && { set_last_result "warn" "已取消删除"; return; }

        remove_rule_at_index $((del_input - 1))
        auto_save_and_apply "删除成功！" "删除失败：规则已保存，但应用失败，请检查防火墙后端环境"
        return
    done
}

# ---------- 重启端口转发 ----------
do_restart() {
    load_rules
    if apply_rules_core; then
        if [[ ${#rules_src_port[@]} -eq 0 ]]; then
            set_last_result "success" "重启完成：当前无转发规则，已清空规则表"
        else
            set_last_result "success" "重启完成：已重新加载 ${#rules_src_port[@]} 条转发规则 (${FW_BACKEND:-auto})"
        fi
    else
        set_last_result "error" "重启失败：规则应用异常，请检查防火墙后端和配置"
    fi
}

# ---------- 管理开机自启 ----------
do_autostart() {
    print_banner
    echo -e "${BOLD}${BLUE}[ 开机自启管理 ]${NC}"
    echo ""

    local is_enabled=false
    systemctl is-enabled --quiet iptables-forward.service 2>/dev/null && is_enabled=true

    if $is_enabled; then
        echo -e "  当前状态: ${GREEN}已启用开机自启${NC}"
        echo ""
        echo -e "  ${RED}1)${NC} 关闭开机自启"
    else
        echo -e "  当前状态: ${YELLOW}未启用开机自启${NC}"
        echo ""
        echo -e "  ${GREEN}1)${NC} 开启开机自启"
    fi
    echo -e "  ${NC}0)${NC} 返回"
    echo ""

    local choice
    choice=$(read_menu_choice "请选择 [0-1]: " '^[0-1]$')
    [[ "$choice" == "0" ]] && return

    if $is_enabled; then
        if systemctl disable iptables-forward.service 2>/dev/null; then
            set_last_result "success" "已关闭开机自启"
        else
            set_last_result "error" "关闭开机自启失败"
        fi
    else
        if create_service; then
            set_last_result "success" "已开启开机自启"
        else
            set_last_result "error" "开启开机自启失败，请检查网络或 systemd 状态"
        fi
    fi
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
        echo -e "  IP 转 发: ${GREEN}● 已开启${NC}    转发规则: ${CYAN}${rule_count} 条${NC}"
    else
        echo -e "  IP 转 发: ${RED}● 已关闭${NC}    转发规则: ${CYAN}${rule_count} 条${NC}"
    fi

    if systemctl is-enabled --quiet iptables-forward.service 2>/dev/null; then
        echo -e "  开机自启: ${GREEN}● 已开启${NC}"
    else
        echo -e "  开机自启: ${YELLOW}● 已关闭${NC}"
    fi

    local watch_minutes="${GLOBAL_WATCH_INTERVAL_MINUTES:-0}"
    local restart_minutes="${GLOBAL_RESTART_INTERVAL_MINUTES:-0}"
    local watch_status="${YELLOW}● 已关闭${NC}" restart_status="${YELLOW}● 已关闭${NC}"
    [[ "$watch_minutes" -gt 0 ]] && watch_status="${GREEN}● 已开启${NC}"
    [[ "$restart_minutes" -gt 0 ]] && restart_status="${GREEN}● 已开启${NC}"

    echo -e "  域名解析: ${watch_status} (${CYAN}$(format_interval_label "$watch_minutes")${NC})"
    echo -e "  自动重启: ${restart_status} (${CYAN}$(format_interval_label "$restart_minutes")${NC})"
    echo ""

    [[ $rule_count -gt 0 ]] && { echo -e "${BOLD}${BLUE}当前转发:${NC}"; print_rules_home_style; }

    echo -e "  ${GREEN}1)${NC} 添加转发规则"
    echo -e "  ${RED}2)${NC} 删除转发规则"
    echo -e "  ${CYAN}3)${NC} 重启端口转发"
    echo -e "  ${CYAN}4)${NC} 域名解析间隔"
    echo -e "  ${YELLOW}5)${NC} 开机自启管理"
    echo -e "  ${BLUE}6)${NC} 更新脚本文件"
    echo -e "  ${RED}7)${NC} 移除脚本"
    echo -e "  ${NC}0)${NC} 退出"
    echo ""

    choice=$(read_menu_choice "请选择操作 [0-7]: " '^[0-7]$')
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
            3) do_interval_manage "restart" "重启端口转发" "GLOBAL_RESTART_INTERVAL_MINUTES" "重启" ;;
            4) do_interval_manage "watch" "域名解析间隔" "GLOBAL_WATCH_INTERVAL_MINUTES" "解析" ;;
            5) do_autostart ;;
            6) do_update ;;
            7) do_uninstall ;;
            0) echo ""; print_info "再见！"; exit 0 ;;
        esac
    done
}

main
