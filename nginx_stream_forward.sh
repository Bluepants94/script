#!/bin/bash

# ============================================================
#  Nginx Stream 转发配置管理脚本
#  功能: 添加/删除/查看 Nginx Stream 转发规则
#  配置文件: /etc/nginx/stream/proxy.conf
#  支持: 白名单、TCP+UDP 监听、自动重载
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
NGINX_STREAM_DIR="/etc/nginx/stream"
CONFIG_FILE="${NGINX_STREAM_DIR}/proxy.conf"
BACKUP_FILE="${CONFIG_FILE}.backup"
DEFAULT_PROXY_CONF_URL="https://raw.githubusercontent.com/Bluepants94/script/refs/heads/main/proxy.conf"

# ---------- 全局变量 ----------
LAST_RESULT_TYPE=""
LAST_RESULT_MSG=""

# 规则存储数组
declare -a rule_nodes
declare -a rule_targets
declare -a rule_ports
declare -a rule_whitelists

# ---------- 工具函数 ----------
print_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║      Nginx Stream 转发配置管理工具           ║"
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
    # 确保目录存在
    if [[ ! -d "$NGINX_STREAM_DIR" ]]; then
        mkdir -p "$NGINX_STREAM_DIR"
        print_info "已创建目录: $NGINX_STREAM_DIR"
    fi

    # 检查 nginx 是否安装
    if ! command -v nginx &>/dev/null; then
        print_error "nginx 未安装！请先安装 nginx"
        exit 1
    fi

    # 首次运行自动准备 proxy.conf（静默）
    if ! create_config_if_not_exists; then
        print_error "初始化 proxy.conf 失败，请检查网络和目录权限"
        exit 1
    fi
}

# ---------- 验证端口格式 ----------
validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]; then
        return 0
    fi
    return 1
}

# ---------- 验证 IP/域名:端口 格式 ----------
validate_target() {
    local target="$1"
    # 格式: IP:port 或 domain:port
    if [[ "$target" =~ ^([a-zA-Z0-9.-]+):([0-9]+)$ ]]; then
        local host="${BASH_REMATCH[1]}"
        local port="${BASH_REMATCH[2]}"
        if validate_port "$port"; then
            return 0
        fi
    fi
    return 1
}

# ---------- 验证 IP/CIDR 格式 ----------
validate_ip_cidr() {
    local input="$1"
    # 单个 IP: x.x.x.x
    if [[ "$input" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 0
    fi
    # CIDR: x.x.x.x/xx
    if [[ "$input" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        return 0
    fi
    return 1
}

# ---------- 生成安全的 zone 名称 ----------
build_zone_name() {
    local node="$1"
    local safe
    safe=$(echo "$node" | sed 's/[^a-zA-Z0-9_]/_/g')
    echo "backend_zone_${safe}"
}

# ---------- 转义正则特殊字符 ----------
escape_regex() {
    echo "$1" | sed -e 's/[.[\*^$()+?{|]/\\&/g'
}

# ---------- 解析现有配置文件 ----------
parse_config() {
    rule_nodes=()
    rule_targets=()
    rule_ports=()
    rule_whitelists=()

    [[ ! -f "$CONFIG_FILE" ]] && return

    local in_upstream=false
    local in_server=false
    local current_node=""
    local current_target=""
    local current_port=""
    local current_whitelist=""

    while IFS= read -r line; do
        # 清除首尾空格
        line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        # 跳过注释行（示例注释不参与规则识别）
        [[ "$line" =~ ^# ]] && continue

        # 匹配 upstream 块
        if [[ "$line" =~ ^upstream[[:space:]]+backend_stream_(.+)[[:space:]]*\{ ]]; then
            current_node="${BASH_REMATCH[1]}"
            in_upstream=true
            current_target=""
            current_port=""
            current_whitelist=""
            continue
        fi

        # 匹配 server 行（在 upstream 块内）
        if $in_upstream && [[ "$line" =~ ^server[[:space:]]+([^[:space:]]+)[[:space:]]+resolve ]]; then
            current_target="${BASH_REMATCH[1]}"
        fi

        # upstream 块结束
        if $in_upstream && [[ "$line" == "}" ]]; then
            in_upstream=false
        fi

        # 匹配 server 块
        if [[ "$line" =~ ^server[[:space:]]*\{ ]]; then
            in_server=true
            continue
        fi

        # 在 server 块内匹配监听端口（TCP）
        if $in_server && [[ -z "$current_port" ]] && [[ "$line" =~ ^listen[[:space:]]+([0-9]+)[[:space:]]+reuseport ]]; then
            current_port="${BASH_REMATCH[1]}"
        fi

        # 匹配白名单
        if $in_server && [[ "$line" =~ ^allow[[:space:]]+([^;]+)\; ]]; then
            local allow_ip="${BASH_REMATCH[1]}"
            if [[ -n "$current_whitelist" ]]; then
                current_whitelist="${current_whitelist},${allow_ip}"
            else
                current_whitelist="$allow_ip"
            fi
        fi

        # server 块结束
        if $in_server && [[ "$line" == "}" ]]; then
            in_server=false
            # 保存当前规则
            if [[ -n "$current_node" && -n "$current_target" && -n "$current_port" ]]; then
                rule_nodes+=("$current_node")
                rule_targets+=("$current_target")
                rule_ports+=("$current_port")
                rule_whitelists+=("$current_whitelist")
            fi
            current_node=""
            current_target=""
            current_port=""
            current_whitelist=""
        fi
    done < "$CONFIG_FILE"
}

# ---------- 检查节点名称是否已存在 ----------
check_node_exists() {
    local node="$1"
    for existing_node in "${rule_nodes[@]}"; do
        if [[ "$existing_node" == "$node" ]]; then
            return 0
        fi
    done
    return 1
}

# ---------- 检查监听端口是否已存在 ----------
check_port_exists() {
    local port="$1"
    for existing_port in "${rule_ports[@]}"; do
        if [[ "$existing_port" == "$port" ]]; then
            return 0
        fi
    done
    return 1
}

# ---------- 创建配置文件（如果不存在） ----------
create_config_if_not_exists() {
    mkdir -p "$NGINX_STREAM_DIR" || {
        print_error "创建目录失败: $NGINX_STREAM_DIR"
        return 1
    }

    if [[ ! -f "$CONFIG_FILE" ]]; then
        if ! download_default_proxy_conf; then
            print_error "下载默认配置失败: $CONFIG_FILE"
            return 1
        fi
    fi

    return 0
}

# ---------- 下载默认 proxy.conf（静默） ----------
download_default_proxy_conf() {
    local tmp_file="${CONFIG_FILE}.download"
    rm -f "$tmp_file"

    if command -v curl &>/dev/null; then
        curl -fsSL "$DEFAULT_PROXY_CONF_URL" -o "$tmp_file" >/dev/null 2>&1 || return 1
    elif command -v wget &>/dev/null; then
        wget -q -O "$tmp_file" "$DEFAULT_PROXY_CONF_URL" >/dev/null 2>&1 || return 1
    else
        return 1
    fi

    [[ -s "$tmp_file" ]] || return 1
    mv "$tmp_file" "$CONFIG_FILE" || return 1
    return 0
}

# ---------- 写入基础配置头 ----------
write_base_config_header() {
    cat > "$CONFIG_FILE" <<'EOF'
resolver 8.8.8.8 1.1.1.1 valid=300s;
resolver_timeout 5s;

EOF
}

# ---------- 添加转发规则 ----------
add_forwarding_rule() {
    local node="$1"
    local target="$2"
    local port="$3"
    local whitelist="$4"
    local zone_name
    zone_name=$(build_zone_name "$node")

    # 生成 upstream 块
    cat >> "$CONFIG_FILE" <<EOF || return 1

upstream backend_stream_${node} {
    zone ${zone_name} 64k;
    server ${target} resolve;
}

EOF

    # 生成 server 块
    cat >> "$CONFIG_FILE" <<EOF || return 1
server {
    # --- TCP 监听 ---
    listen ${port} reuseport;
    listen [::]:${port} reuseport;

    # --- UDP 监听 ---
    listen ${port} udp reuseport;
    listen [::]:${port} udp reuseport;

EOF

    # 如果有白名单，添加白名单规则
    if [[ -n "$whitelist" ]]; then
        cat >> "$CONFIG_FILE" <<EOF || return 1
    # --- 白名单设置 ---
EOF
        IFS=',' read -ra ADDR <<< "$whitelist"
        for ip in "${ADDR[@]}"; do
            echo "    allow ${ip};" >> "$CONFIG_FILE" || return 1
        done
        echo "    deny all;" >> "$CONFIG_FILE" || return 1
    fi

    # 添加 proxy_pass 和优化配置
    cat >> "$CONFIG_FILE" <<EOF || return 1
    proxy_pass      backend_stream_${node};

    # 针对 TCP 的优化
    proxy_connect_timeout 5s;       # 连接后端超时建议缩短，提升响应感
    proxy_timeout 1h;               # 保持长连接

    # 针对 UDP 的优化
    proxy_responses 1;              # 预期后端对每个 UDP 包返回 1 个响应
    
    # 缓冲区设置（根据流量大小调整）
    # proxy_buffer_size 16k;
}

EOF
}

# ---------- 测试并重载 Nginx ----------
test_and_reload_nginx() {
    local silent="${1:-false}"

    if [[ "$silent" != "true" ]]; then
        print_info "正在测试 Nginx 配置..."
    fi

    if nginx -t 2>&1 | grep -q "successful"; then
        if [[ "$silent" != "true" ]]; then
            print_success "配置测试通过"
            print_info "正在重载 Nginx..."
        fi

        if nginx -s reload 2>/dev/null; then
            if [[ "$silent" != "true" ]]; then
                print_success "Nginx 已成功重载"
            fi
            return 0
        else
            if [[ "$silent" != "true" ]]; then
                print_error "Nginx 重载失败"
            fi
            return 1
        fi
    else
        if [[ "$silent" != "true" ]]; then
            print_error "Nginx 配置测试失败！"
            nginx -t 2>&1 | tail -5
        fi
        return 1
    fi
}

# ---------- 备份配置文件 ----------
backup_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        cp "$CONFIG_FILE" "$BACKUP_FILE"
    fi
}

# ---------- 恢复配置文件 ----------
restore_config() {
    if [[ -f "$BACKUP_FILE" ]]; then
        mv "$BACKUP_FILE" "$CONFIG_FILE"
        print_warn "配置已回滚到修改前的状态"
    fi
}

# ---------- 删除备份文件 ----------
remove_backup() {
    [[ -f "$BACKUP_FILE" ]] && rm -f "$BACKUP_FILE"
}

# ---------- 添加失败后的统一回滚 ----------
rollback_to_previous_or_default() {
    local had_config_before="$1"

    if [[ "$had_config_before" == "true" ]]; then
        restore_config
    else
        if ! download_default_proxy_conf; then
            write_base_config_header
        fi
        remove_backup
    fi
}

# ---------- 清理多余空行 ----------
tidy_config_spacing() {
    [[ ! -f "$CONFIG_FILE" ]] && return 0

    local temp_file="${CONFIG_FILE}.tidy"
    awk '
    BEGIN { blank=0; started=0 }
    {
        line=$0
        sub(/[[:space:]]+$/, "", line)

        if (line ~ /^[[:space:]]*$/) {
            if (!started) next
            blank++
            if (blank > 1) next
            print ""
            next
        }

        started=1
        blank=0
        print line
    }
    ' "$CONFIG_FILE" > "$temp_file" || return 1

    mv "$temp_file" "$CONFIG_FILE" || return 1
    return 0
}

# ---------- 打印规则列表（首页样式） ----------
print_rules_home_style() {
    if [[ ${#rule_nodes[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}(暂无转发规则)${NC}"
        return
    fi

    for ((i=0; i<${#rule_nodes[@]}; i++)); do
        local wl_info=""
        if [[ -n "${rule_whitelists[$i]}" ]]; then
            local wl_count=$(echo "${rule_whitelists[$i]}" | tr ',' '\n' | wc -l)
            wl_info=" ${GREEN}[白名单: ${wl_count}条]${NC}"
        fi
        echo -e "  ${GREEN}[$((i+1))]${NC} ${GREEN}${rule_nodes[$i]}${NC} ${YELLOW}${rule_ports[$i]}${NC} → ${CYAN}${rule_targets[$i]}${NC} ${YELLOW}(TCP+UDP)${NC}${wl_info}"
    done
    echo ""
}

# ---------- 删除指定规则 ----------
delete_rule_from_config() {
    local index="$1"
    local node="${rule_nodes[$index]}"
    local node_regex
    node_regex=$(escape_regex "$node")
    
    # 创建临时文件
    local temp_file="${CONFIG_FILE}.tmp"
    : > "$temp_file"
    
    # 标记要删除的块
    local skip_upstream=false
    local skip_server=false
    local in_target_upstream=false
    
    while IFS= read -r line; do
        local trimmed
        trimmed=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        # 检测是否是目标 upstream 块
        if [[ "$trimmed" =~ ^upstream[[:space:]]+backend_stream_${node_regex}[[:space:]]*\{$ ]]; then
            skip_upstream=true
            in_target_upstream=true
            continue
        fi
        
        # 如果在要删除的 upstream 块内
        if $skip_upstream; then
            if [[ "$trimmed" == "}" ]]; then
                skip_upstream=false
                continue
            fi
            continue
        fi
        
        # 检测是否是与目标节点对应的 server 块
        if [[ "$trimmed" =~ ^server[[:space:]]*\{$ ]] && $in_target_upstream; then
            skip_server=true
            continue
        fi
        
        # 如果在要删除的 server 块内
        if $skip_server; then
            if [[ "$trimmed" == "}" ]]; then
                skip_server=false
                in_target_upstream=false
                continue
            fi
            continue
        fi
        
        # 输出非删除行
        echo "$line" >> "$temp_file"
    done < "$CONFIG_FILE"
    
    # 替换原文件
    mv "$temp_file" "$CONFIG_FILE"
}

# ---------- 删除全部规则（保留非规则内容） ----------
delete_all_rules_from_config() {
    local temp_file="${CONFIG_FILE}.tmp"
    : > "$temp_file"

    local skip_upstream=false
    local skip_server=false
    local pending_server=false

    while IFS= read -r line; do
        local trimmed
        trimmed=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        # 识别脚本管理的 upstream
        if [[ "$trimmed" =~ ^upstream[[:space:]]+backend_stream_.*[[:space:]]*\{$ ]]; then
            skip_upstream=true
            pending_server=true
            continue
        fi

        if $skip_upstream; then
            if [[ "$trimmed" == "}" ]]; then
                skip_upstream=false
            fi
            continue
        fi

        # 跳过紧随其后的 server 块
        if $pending_server && [[ "$trimmed" == "server {" ]]; then
            skip_server=true
            pending_server=false
            continue
        fi

        if $skip_server; then
            if [[ "$trimmed" == "}" ]]; then
                skip_server=false
            fi
            continue
        fi

        echo "$line" >> "$temp_file"
    done < "$CONFIG_FILE"

    mv "$temp_file" "$CONFIG_FILE"
}

# ---------- 执行添加操作 ----------
do_add() {
    print_banner
    echo -e "${BOLD}${GREEN}[ 添加转发规则 ]${NC}"
    echo ""

    parse_config
    if [[ ${#rule_nodes[@]} -gt 0 ]]; then
        echo -e "${BOLD}${BLUE}当前已有规则:${NC}"
        print_rules_home_style
    fi

    echo -e "${BOLD}${CYAN}--- 新增转发 ---${NC}"
    echo ""

    # 输入节点名称
    local node
    while true; do
        read -r -p "请输入节点名称（如 HK_BoilCloud_17.HKT）: " node
        if [[ -z "$node" ]]; then
            print_error "节点名称不能为空"
            continue
        fi
        if check_node_exists "$node"; then
            print_error "节点名称已存在，请使用其他名称"
            continue
        fi
        break
    done

    # 输入转发目标
    local target
    while true; do
        read -r -p "请输入转发目标（格式: IP/域名:端口，如 node.example.com:30002）: " target
        if ! validate_target "$target"; then
            print_error "格式错误，请使用 IP/域名:端口 格式"
            continue
        fi
        break
    done

    # 输入监听端口
    local port
    while true; do
        read -r -p "请输入监听端口（1-65535）: " port
        if ! validate_port "$port"; then
            print_error "端口格式错误，范围需在 1-65535"
            continue
        fi
        if check_port_exists "$port"; then
            print_error "监听端口 $port 已被占用，请使用其他端口"
            continue
        fi
        break
    done

    # 配置白名单
    echo ""
    local setup_whitelist
    read -r -p "是否配置白名单？[Y/N]: " setup_whitelist
    
    local whitelist=""
    if is_yes "$setup_whitelist"; then
        echo -e "${CYAN}请输入白名单 IP/网段:${NC}"
        local wl_count=1
        while true; do
            local wl_ip
            read -r -p "  允许 IP/网段 #${wl_count}: " wl_ip
            [[ -z "$wl_ip" ]] && {
                print_warn "IP/网段不能为空"
                continue
            }
            
            if ! validate_ip_cidr "$wl_ip"; then
                print_error "IP/CIDR 格式错误，请重新输入"
                continue
            fi
            
            if [[ -n "$whitelist" ]]; then
                whitelist="${whitelist},${wl_ip}"
            else
                whitelist="$wl_ip"
            fi
            wl_count=$((wl_count + 1))

            local add_more
            read -r -p "是否继续添加 allow？[Y/N]: " add_more
            if ! is_yes "$add_more"; then
                break
            fi
        done
    fi

    # 确认信息
    echo ""
    echo -e "${GREEN}即将添加转发:${NC}"
    echo -e "  节点名称: ${CYAN}${node}${NC}"
    echo -e "  转发目标: ${CYAN}${target}${NC}"
    echo -e "  监听端口: ${CYAN}${port}${NC} (TCP+UDP)"
    
    if [[ -n "$whitelist" ]]; then
        echo -e "  白名单:"
        IFS=',' read -ra ADDR <<< "$whitelist"
        for ip in "${ADDR[@]}"; do
            echo -e "    ${GREEN}✓${NC} $ip"
        done
    else
        echo -e "  白名单: ${YELLOW}未配置${NC}"
    fi
    
    echo ""
    read -r -p "确认添加？[Y/N]: " confirm
    if ! is_yes "$confirm"; then
        print_warn "已取消添加"
        return
    fi

    local had_config_before=false
    [[ -f "$CONFIG_FILE" ]] && had_config_before=true

    # 备份配置
    backup_config

    # 确保配置文件存在
    if ! create_config_if_not_exists; then
        set_last_result "error" "创建配置文件失败，请检查目录权限"
        return
    fi

    # 添加规则
    if ! add_forwarding_rule "$node" "$target" "$port" "$whitelist"; then
        rollback_to_previous_or_default "$had_config_before"
        set_last_result "error" "写入 proxy.conf 失败，请检查文件权限"
        return
    fi

    if ! tidy_config_spacing; then
        rollback_to_previous_or_default "$had_config_before"
        set_last_result "error" "整理 proxy.conf 空行失败，配置已回滚"
        return
    fi

    # 测试并重载
    if test_and_reload_nginx; then
        remove_backup
        set_last_result "success" "转发规则添加成功！"
    else
        rollback_to_previous_or_default "$had_config_before"
        print_warn "配置已回滚"
        set_last_result "error" "添加失败，配置已回滚"
    fi
}

# ---------- 执行删除操作 ----------
do_delete() {
    print_banner
    echo -e "${BOLD}${RED}[ 删除转发规则 ]${NC}"
    echo ""

    parse_config
    if [[ ${#rule_nodes[@]} -eq 0 ]]; then
        print_warn "当前没有转发规则"
        read -r -p "按回车返回主菜单..."
        return
    fi

    echo -e "${BOLD}${BLUE}当前转发规则:${NC}"
    print_rules_home_style

    while true; do
        echo ""
        echo -e "输入序号（${CYAN}1-${#rule_nodes[@]}${NC}），输入 ${YELLOW}all${NC} 删除全部，输入 ${NC}0${NC} 返回"
        read -r -p "请选择: " del_input

        if [[ "$del_input" == "0" ]]; then
            return
        fi

        if [[ "$del_input" == "all" || "$del_input" == "ALL" ]]; then
            read -r -p "确认删除全部规则？[Y/N]: " confirm
            if is_yes "$confirm"; then
                backup_config

                # 实际删除全部规则
                if [[ -f "$CONFIG_FILE" ]]; then
                    delete_all_rules_from_config
                    if ! tidy_config_spacing; then
                        restore_config
                        set_last_result "error" "整理空行失败，配置已回滚"
                        return
                    fi
                fi

                if test_and_reload_nginx; then
                    remove_backup
                    set_last_result "success" "已删除全部转发规则！"
                else
                    restore_config
                    set_last_result "error" "删除失败，配置已回滚"
                fi
            fi
            return
        fi

        if [[ ! "$del_input" =~ ^[0-9]+$ ]] || [[ "$del_input" -lt 1 ]] || [[ "$del_input" -gt ${#rule_nodes[@]} ]]; then
            print_error "序号无效！"
            continue
        fi

        local del_idx=$((del_input - 1))
        local del_node="${rule_nodes[$del_idx]}"
        local del_info="${del_node} ${rule_ports[$del_idx]} → ${rule_targets[$del_idx]} (TCP+UDP)"

        echo ""
        echo -e "${YELLOW}即将删除:${NC} ${del_info}"
        read -r -p "确认删除？[Y/N]: " confirm
        if ! is_yes "$confirm"; then
            print_warn "已取消删除"
            continue
        fi

        # 备份配置
        backup_config

        # 删除规则
        delete_rule_from_config "$del_idx"
        if ! tidy_config_spacing; then
            restore_config
            set_last_result "error" "整理空行失败，配置已回滚"
            return
        fi

        # 测试并重载
        if test_and_reload_nginx; then
            remove_backup
            set_last_result "success" "已删除转发: ${del_info}"
        else
            restore_config
            set_last_result "error" "删除失败，配置已回滚"
        fi

        # 删除一条后直接返回首页
        return
    done
}

# ---------- 重载 Nginx ----------
do_reload() {
    parse_config
    if test_and_reload_nginx true; then
        set_last_result "success" "Nginx 重载完成（当前 ${#rule_nodes[@]} 条规则）"
    else
        set_last_result "error" "Nginx 重载失败，请检查配置"
    fi
}

# ---------- 主菜单 ----------
show_menu() {
    print_banner
    show_last_result

    parse_config
    local rule_count=${#rule_nodes[@]}

    echo -e "  配置文件: ${CYAN}${CONFIG_FILE}${NC}"
    echo -e "  转发规则: ${CYAN}${rule_count} 条${NC}"
    
    # 检查 Nginx 状态
    if systemctl is-active --quiet nginx 2>/dev/null || pgrep nginx >/dev/null 2>&1; then
        echo -e "  Nginx 状态: ${GREEN}● 运行中${NC}"
    else
        echo -e "  Nginx 状态: ${RED}● 未运行${NC}"
    fi
    echo ""

    if [[ $rule_count -gt 0 ]]; then
        echo -e "${BOLD}${BLUE}当前转发:${NC}"
        print_rules_home_style
    fi

    echo -e "  ${GREEN}1)${NC} 添加转发规则"
    echo -e "  ${RED}2)${NC} 删除转发规则"
    echo -e "  ${YELLOW}3)${NC} 重载 Nginx"
    echo -e "  ${NC}0)${NC} 退出"
    echo ""

    read -r -p "请选择操作 [0-3]: " choice
}

# ---------- 主入口 ----------
main() {
    check_root
    init_env

    while true; do
        show_menu
        case "$choice" in
            1) do_add ;;
            2) do_delete ;;
            3) do_reload ;;
            0)
                echo ""
                print_info "再见！"
                exit 0
                ;;
            *)
                set_last_result "error" "无效选择，请输入 0-3"
                ;;
        esac
    done
}

main
