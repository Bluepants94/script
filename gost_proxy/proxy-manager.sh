#!/usr/bin/env bash
# proxy-manager.sh — gost 端口代理管理脚本（交互菜单版）
# 在同一端口同时提供 HTTP 与 SOCKS5 代理（gost auto handler 按首字节自动识别协议），
# 支持单用户鉴权、多 IP 客户端白名单、开机自启、gost 在线安装/更新。
# 用法：直接以 root 运行本脚本，无需任何命令行参数。

set -uo pipefail

readonly GOST_BIN="/usr/local/bin/gost"
readonly CONF_DIR="/etc/gost-proxy"
readonly SETTINGS_FILE="${CONF_DIR}/settings.env"
readonly ADMISSION_LIST="${CONF_DIR}/admission.list"
readonly BYPASS_LIST="${CONF_DIR}/bypass.list"
readonly CONFIG_FILE="${CONF_DIR}/config.yaml"
readonly SERVICE_NAME="gost-proxy.service"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
readonly GITHUB_API="https://api.github.com/repos/go-gost/gost/releases/latest"

# ---------------------------------------------------------------------------
# 运行期设置（默认值，load_settings 会从 settings.env 覆盖）
# ---------------------------------------------------------------------------
PORT="38080"
AUTH_USER=""
AUTH_PASS=""
WHITELIST_ENABLED="off"   # on / off
BYPASS_ENABLED="off"      # on / off
# 旧版兼容：条目曾内嵌在 settings.env，现已迁移到 admission.list / bypass.list
WHITELIST_ENTRIES=""
BYPASS_ENTRIES=""

ENV_OK=1
ENV_PROBLEMS=()

# ---------------------------------------------------------------------------
# 终端颜色（非 TTY 时禁用）
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
    C_CYAN=$'\e[36m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_RESET=$'\e[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

info() { printf '%s\n' "${C_CYAN}[*]${C_RESET} $*"; }
ok()   { printf '%s\n' "${C_GREEN}[OK]${C_RESET} $*"; }
warn() { printf '%s\n' "${C_YELLOW}[!]${C_RESET} $*"; }
err()  { printf '%s\n' "${C_RED}[X]${C_RESET} $*" >&2; }

pause() {
    printf '\n%s' "${C_DIM}按回车键继续...${C_RESET}"
    read -r _ || true
}

# ---------------------------------------------------------------------------
# 环境检查：root / systemctl / curl / tar 缺一不可执行管理操作
# ---------------------------------------------------------------------------
check_env() {
    ENV_PROBLEMS=()
    [[ ${EUID:-$(id -u)} -eq 0 ]] || ENV_PROBLEMS+=("需要以 root 权限运行（或使用 sudo）")
    command -v systemctl >/dev/null 2>&1 || ENV_PROBLEMS+=("未找到 systemctl（本脚本依赖 systemd）")
    command -v curl     >/dev/null 2>&1 || ENV_PROBLEMS+=("未找到 curl")
    command -v tar      >/dev/null 2>&1 || ENV_PROBLEMS+=("未找到 tar")
    if [[ ${#ENV_PROBLEMS[@]} -eq 0 ]]; then
        ENV_OK=1
    else
        ENV_OK=0
    fi
}

require_env() {
    if [[ $ENV_OK -ne 1 ]]; then
        err "当前环境不满足管理条件："
        local p
        for p in "${ENV_PROBLEMS[@]}"; do
            printf '    - %s\n' "$p" >&2
        done
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 设置的读取与保存
# ---------------------------------------------------------------------------
load_settings() {
    if [[ -f $SETTINGS_FILE ]]; then
        # shellcheck disable=SC1090
        . "$SETTINGS_FILE"
    fi
}

save_settings() {
    mkdir -p "$CONF_DIR"
    {
        printf 'PORT=%q\n' "$PORT"
        printf 'AUTH_USER=%q\n' "$AUTH_USER"
        printf 'AUTH_PASS=%q\n' "$AUTH_PASS"
        printf 'WHITELIST_ENABLED=%q\n' "$WHITELIST_ENABLED"
        printf 'BYPASS_ENABLED=%q\n' "$BYPASS_ENABLED"
    } > "$SETTINGS_FILE"
    chmod 600 "$SETTINGS_FILE"
}

# 从列表文件读取条目：忽略 # 注释与空行，兼容 CRLF 与首尾空白
read_entries() {
    local file="$1"
    [[ -f $file ]] || return 0
    sed 's/#.*$//' "$file" | tr -d '\r' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | grep -v '^$' || true
}

# 旧版 settings.env 内嵌条目 → 独立列表文件（仅当列表文件不存在时）
migrate_legacy_entries() {
    if [[ ! -f $ADMISSION_LIST && -n $WHITELIST_ENTRIES ]]; then
        mkdir -p "$CONF_DIR"
        tr ' ' '\n' <<< "$WHITELIST_ENTRIES" | grep -v '^$' > "$ADMISSION_LIST" || true
        chmod 600 "$ADMISSION_LIST" 2>/dev/null || true
        WHITELIST_ENTRIES=""
    fi
    if [[ ! -f $BYPASS_LIST && -n $BYPASS_ENTRIES ]]; then
        mkdir -p "$CONF_DIR"
        tr ' ' '\n' <<< "$BYPASS_ENTRIES" | grep -v '^$' > "$BYPASS_LIST" || true
        chmod 600 "$BYPASS_LIST" 2>/dev/null || true
        BYPASS_ENTRIES=""
    fi
}

# ---------------------------------------------------------------------------
# 生成 gost v3 YAML 配置
# ---------------------------------------------------------------------------
yaml_escape() {
    # 转义双引号字符串中的反斜杠与双引号
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

generate_config() {
    mkdir -p "$CONF_DIR"

    local -a wl_entries=() bp_entries=()
    if [[ $WHITELIST_ENABLED == "on" ]]; then
        mapfile -t wl_entries < <(read_entries "$ADMISSION_LIST")
    fi
    if [[ $BYPASS_ENABLED == "on" ]]; then
        mapfile -t bp_entries < <(read_entries "$BYPASS_LIST")
    fi

    {
        echo "services:"
        echo "- name: gost-proxy"
        echo "  addr: \":${PORT}\""
        echo "  handler:"
        echo "    type: auto"
        if [[ -n $AUTH_USER ]]; then
            echo "    auth:"
            echo "      username: \"$(yaml_escape "$AUTH_USER")\""
            echo "      password: \"$(yaml_escape "$AUTH_PASS")\""
        fi
        echo "  listener:"
        echo "    type: tcp"
        # gost v3 要求 admission/bypass 为命名引用，定义在顶层列表
        if [[ ${#wl_entries[@]} -gt 0 ]]; then
            echo "  admission: gost-proxy-wl"
        fi
        if [[ ${#bp_entries[@]} -gt 0 ]]; then
            echo "  bypass: gost-proxy-bp"
        fi
        if [[ ${#wl_entries[@]} -gt 0 ]]; then
            echo "admissions:"
            echo "- name: gost-proxy-wl"
            echo "  whitelist: true"
            echo "  matchers:"
            local e
            for e in "${wl_entries[@]}"; do
                echo "  - \"${e}\""
            done
        fi
        if [[ ${#bp_entries[@]} -gt 0 ]]; then
            echo "bypasses:"
            echo "- name: gost-proxy-bp"
            echo "  whitelist: true"
            echo "  matchers:"
            local t
            for t in "${bp_entries[@]}"; do
                echo "  - \"${t}\""
            done
        fi
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

write_service_unit() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=gost proxy (HTTP + SOCKS5 on one port)
After=network.target

[Service]
ExecStart=${GOST_BIN} -C ${CONFIG_FILE}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# 状态查询
# ---------------------------------------------------------------------------
gost_version_text() {
    if [[ -x $GOST_BIN ]]; then
        local v
        v=$("$GOST_BIN" -V 2>/dev/null | head -n1)
        printf '%s' "${v:-未知}"
    else
        printf '%s' "未安装"
    fi
}

service_active() {
    [[ $(systemctl is-active "$SERVICE_NAME" 2>/dev/null) == "active" ]]
}

service_enabled() {
    [[ $(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null) == "enabled" ]]
}

# 探测指定端口是否有 TCP 监听；无法探测时返回 2
port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnH "sport = :${port}" 2>/dev/null | grep -q .
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
    else
        return 2
    fi
}

# ---------------------------------------------------------------------------
# 状态栏
# ---------------------------------------------------------------------------
show_status() {
    local ver listen_state port_state auth_state wl_state bp_state boot_state
    ver=$(gost_version_text)

    if service_active; then
        listen_state="${C_GREEN}运行中${C_RESET}"
    else
        listen_state="${C_RED}已停止${C_RESET}"
    fi

    if port_in_use "$PORT"; then
        port_state="${PORT} ${C_GREEN}(监听中)${C_RESET}"
    else
        port_state="${PORT} ${C_DIM}(未监听)${C_RESET}"
    fi

    if [[ -n $AUTH_USER ]]; then
        auth_state="${C_GREEN}已启用${C_RESET}（用户: ${AUTH_USER}）"
    else
        auth_state="${C_YELLOW}未启用${C_RESET}"
    fi

    local -a wl_arr=() bp_arr=()
    mapfile -t wl_arr < <(read_entries "$ADMISSION_LIST")
    mapfile -t bp_arr < <(read_entries "$BYPASS_LIST")

    local count=${#wl_arr[@]}
    if [[ $WHITELIST_ENABLED == "on" ]]; then
        wl_state="${C_GREEN}开启${C_RESET}（${count} 条）"
    else
        wl_state="${C_YELLOW}关闭${C_RESET}（已保存 ${count} 条）"
    fi

    local bp_count=${#bp_arr[@]}
    if [[ $BYPASS_ENABLED == "on" ]]; then
        bp_state="${C_GREEN}开启${C_RESET}（${bp_count} 条）"
    else
        bp_state="${C_YELLOW}关闭${C_RESET}（已保存 ${bp_count} 条）"
    fi

    if service_enabled; then
        boot_state="${C_GREEN}已开启${C_RESET}"
    else
        boot_state="${C_DIM}未开启${C_RESET}"
    fi

    echo "${C_BOLD}================ gost 端口代理管理 ================${C_RESET}"
    printf '  gost 版本    : %s\n' "$ver"
    printf '  监听状态     : %b\n' "$listen_state"
    printf '  当前端口     : %b\n' "$port_state"
    printf '  访问鉴权     : %b\n' "$auth_state"
    printf '  来源白名单   : %b\n' "$wl_state"
    printf '  目标白名单   : %b\n' "$bp_state"
    printf '  开机自启     : %b\n' "$boot_state"
    printf '  配置文件     : %s\n' "$CONFIG_FILE"
    if [[ $ENV_OK -ne 1 ]]; then
        echo "  ${C_YELLOW}环境异常（仅可查看状态）：${C_RESET}"
        local p
        for p in "${ENV_PROBLEMS[@]}"; do
            printf '    - %s\n' "$p"
        done
    fi
    echo "${C_BOLD}==================================================${C_RESET}"
}

# ---------------------------------------------------------------------------
# 1. 安装 / 更新 gost
# ---------------------------------------------------------------------------
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        armv7l|armv7)   echo "armv7" ;;
        *)              return 1 ;;
    esac
}

install_or_update_gost() {
    require_env || return 1

    local arch
    if ! arch=$(detect_arch); then
        err "暂不支持的 CPU 架构：$(uname -m)"
        return 1
    fi

    info "正在查询 go-gost/gost 最新版本..."
    local json
    if ! json=$(curl -fsSL --connect-timeout 10 "$GITHUB_API"); then
        err "无法访问 GitHub API，请检查网络或稍后重试"
        return 1
    fi

    local tag
    tag=$(grep -m1 '"tag_name"' <<< "$json" | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
    if [[ -z $tag ]]; then
        err "解析版本号失败"
        return 1
    fi
    info "最新版本：${tag}"

    local url
    url=$(grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' <<< "$json" \
        | sed -E 's/.*"([^"]+)"$/\1/' \
        | grep -E "linux_${arch}.*\.tar\.gz$" | head -n1)
    if [[ -z $url ]]; then
        err "未找到适配 linux/${arch} 的下载资产"
        return 1
    fi
    info "下载地址：${url}"

    local tmpdir
    tmpdir=$(mktemp -d) || { err "创建临时目录失败"; return 1; }
    # 确保任何路径下都清理临时目录
    trap 'rm -rf "$tmpdir"' RETURN

    info "正在下载..."
    if ! curl -fSL --connect-timeout 15 -o "${tmpdir}/gost.tar.gz" "$url"; then
        err "下载失败"
        return 1
    fi

    info "正在解压安装..."
    if ! tar -xzf "${tmpdir}/gost.tar.gz" -C "$tmpdir"; then
        err "解压失败（下载内容可能已损坏）"
        return 1
    fi
    local bin
    bin=$(find "$tmpdir" -maxdepth 2 -type f -name gost | head -n1)
    if [[ -z $bin ]]; then
        err "压缩包中未找到 gost 可执行文件"
        return 1
    fi

    install -m 0755 "$bin" "$GOST_BIN" || { err "写入 ${GOST_BIN} 失败"; return 1; }

    if ! "$GOST_BIN" -V >/dev/null 2>&1; then
        err "新二进制无法运行，可能与本机架构不匹配"
        return 1
    fi
    ok "gost 已安装/更新为：$(gost_version_text)"

    if service_active; then
        info "检测到服务正在运行，正在重启以应用新版本..."
        systemctl restart "$SERVICE_NAME"
        sleep 1
        if service_active; then
            ok "服务已重启，当前版本：$(gost_version_text)"
        else
            err "服务重启失败，请检查：journalctl -u ${SERVICE_NAME} -n 50"
            return 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# 2 / 3. 开启 / 关闭代理
# ---------------------------------------------------------------------------
start_proxy() {
    require_env || return 1

    if [[ ! -x $GOST_BIN ]]; then
        err "尚未安装 gost，请先选择菜单 1 安装"
        return 1
    fi
    if [[ -z $PORT ]]; then
        err "尚未设置监听端口，请先选择菜单 4"
        return 1
    fi
    if ! service_active && port_in_use "$PORT"; then
        err "端口 ${PORT} 已被其他进程占用，请更换端口（菜单 4）"
        return 1
    fi

    generate_config
    write_service_unit

    if service_active; then
        info "服务已在运行，正在重启以应用最新配置..."
        systemctl restart "$SERVICE_NAME"
    else
        systemctl start "$SERVICE_NAME"
    fi
    sleep 1

    if service_active; then
        ok "代理已开启：HTTP / SOCKS5 同端口监听 :${PORT}"
    else
        err "启动失败，请检查日志：journalctl -u ${SERVICE_NAME} -n 50"
        return 1
    fi
}

stop_proxy() {
    require_env || return 1

    if ! service_active; then
        warn "代理当前未在运行"
        return 0
    fi
    systemctl stop "$SERVICE_NAME"
    sleep 1
    if service_active; then
        err "停止失败，请检查：systemctl status ${SERVICE_NAME}"
        return 1
    fi
    ok "代理已关闭"
}

# ---------------------------------------------------------------------------
# 4. 设置监听端口
# ---------------------------------------------------------------------------
set_port() {
    require_env || return 1

    local input
    read -rp "请输入新的监听端口（1-65535，当前：${PORT}）: " input
    if ! [[ $input =~ ^[0-9]+$ ]] || (( input < 1 || input > 65535 )); then
        err "无效端口：${input}"
        return 1
    fi
    # 若服务未运行且新端口被占用，拒绝；若占用者就是本服务（同端口），允许
    if [[ $input != "$PORT" ]] && port_in_use "$input"; then
        err "端口 ${input} 已被占用，请换一个"
        return 1
    fi

    PORT="$input"
    save_settings
    generate_config
    ok "监听端口已设置为 ${PORT}"

    if service_active; then
        info "正在重启服务以应用新端口..."
        systemctl restart "$SERVICE_NAME"
        sleep 1
        if service_active; then
            ok "服务已重启，正在监听 :${PORT}"
        else
            err "重启失败，请检查：journalctl -u ${SERVICE_NAME} -n 50"
            return 1
        fi
    else
        info "服务当前未运行，下次开启时生效"
    fi
}

# ---------------------------------------------------------------------------
# 5. 设置鉴权（HTTP / SOCKS5 共用同一组用户名密码）
# ---------------------------------------------------------------------------
set_auth() {
    require_env || return 1

    echo "--- 访问鉴权设置 ---"
    if [[ -n $AUTH_USER ]]; then
        echo "当前状态：已启用（用户: ${AUTH_USER}）"
    else
        echo "当前状态：未启用"
    fi
    echo "1) 设置 / 修改用户名密码"
    echo "2) 关闭鉴权"
    echo "0) 返回"
    local choice
    read -rp "请选择 [0-2]: " choice

    case "$choice" in
        1)
            local user pass1 pass2
            read -rp "请输入用户名: " user
            if [[ -z $user ]]; then
                err "用户名不能为空"
                return 1
            fi
            read -rsp "请输入密码: " pass1; echo
            if [[ -z $pass1 ]]; then
                err "密码不能为空"
                return 1
            fi
            read -rsp "请再次输入密码: " pass2; echo
            if [[ $pass1 != "$pass2" ]]; then
                err "两次输入的密码不一致"
                return 1
            fi
            AUTH_USER="$user"
            AUTH_PASS="$pass1"
            save_settings
            generate_config
            ok "鉴权已启用（用户: ${AUTH_USER}）"
            ;;
        2)
            AUTH_USER=""
            AUTH_PASS=""
            save_settings
            generate_config
            ok "鉴权已关闭（任何人可连接，建议配合 IP 白名单使用）"
            ;;
        0) return 0 ;;
        *) err "无效选择"; return 1 ;;
    esac

    if service_active; then
        info "正在重启服务以应用鉴权配置..."
        systemctl restart "$SERVICE_NAME"
        sleep 1
        service_active && ok "服务已重启" || { err "重启失败"; return 1; }
    fi
}

# ---------------------------------------------------------------------------
# 6 / 7. 白名单管理（来源 admission / 目标 bypass，支持多条，逐条增删）
# ---------------------------------------------------------------------------
valid_ip_cidr() {
    local s="$1" ip mask octet
    ip="${s%%/*}"
    if [[ $s == */* ]]; then
        mask="${s##*/}"
        [[ $mask =~ ^[0-9]+$ ]] && (( mask >= 0 && mask <= 32 )) || return 1
    fi
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    for octet in $ip; do
        (( octet <= 255 )) || return 1
    done
    return 0
}

# bypass 条目：域名 / 通配符域名 / IP / CIDR / IP 范围
valid_bypass_entry() {
    local s="$1"
    [[ -n $s && $s != *[[:space:]]* ]] || return 1
    valid_ip_cidr "$s" && return 0
    [[ $s =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}-([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0
    [[ $s =~ ^(\*\.)?([A-Za-z0-9-]+\.)*[A-Za-z0-9-]+$ ]] && return 0
    return 1
}

# 通用白名单编辑菜单：list_editor admission | bypass
list_editor() {
    require_env || return 1

    local kind="$1"
    local title hint validator off_msg on_msg list_file
    local -n enabled_ref
    case "$kind" in
        admission)
            enabled_ref=WHITELIST_ENABLED
            list_file="$ADMISSION_LIST"
            title="来源 IP 白名单"
            hint="IP 或 CIDR（如 1.2.3.4 或 10.0.0.0/8）"
            validator="valid_ip_cidr"
            off_msg="放行全部来源"
            on_msg="仅允许列表中的来源连接"
            ;;
        bypass)
            enabled_ref=BYPASS_ENABLED
            list_file="$BYPASS_LIST"
            title="目标地址白名单"
            hint="域名/通配符/IP/CIDR（如 example.com、*.example.com、1.2.3.4、10.0.0.0/8）"
            validator="valid_bypass_entry"
            off_msg="放行全部目标"
            on_msg="仅允许访问列表中的目标"
            ;;
        *)
            err "未知白名单类型：${kind}"
            return 1
            ;;
    esac

    local choice
    while true; do
        echo
        echo "--- ${title} ---"
        if [[ $enabled_ref == "on" ]]; then
            echo "状态：${C_GREEN}开启${C_RESET}（${on_msg}）"
        else
            echo "状态：${C_YELLOW}关闭${C_RESET}（${off_msg}）"
        fi

        local -a entries=()
        local i
        mapfile -t entries < <(read_entries "$list_file")
        if [[ ${#entries[@]} -eq 0 ]]; then
            echo "当前条目：（空）"
        else
            echo "当前条目："
            for i in "${!entries[@]}"; do
                printf '  %d) %s\n' "$((i + 1))" "${entries[$i]}"
            done
        fi

        echo
        echo "1) 添加条目"
        echo "2) 删除条目"
        if [[ $enabled_ref == "on" ]]; then
            echo "3) 关闭白名单（${off_msg}）"
        else
            echo "3) 开启白名单"
        fi
        echo "0) 返回"
        read -rp "请选择 [0-3]: " choice || break

        case "$choice" in
            1)
                local newentry e
                read -rp "请输入条目（${hint}）: " newentry
                if ! "$validator" "$newentry"; then
                    err "格式无效：${newentry}"
                    continue
                fi
                for e in "${entries[@]}"; do
                    if [[ $e == "$newentry" ]]; then
                        warn "该条目已存在"
                        continue 2
                    fi
                done
                mkdir -p "$CONF_DIR"
                printf '%s\n' "$newentry" >> "$list_file"
                chmod 600 "$list_file"
                save_settings
                generate_config
                ok "已添加：${newentry}"
                ;;
            2)
                if [[ ${#entries[@]} -eq 0 ]]; then
                    warn "当前没有可删除的条目"
                    continue
                fi
                local idx
                read -rp "请输入要删除的条目编号: " idx
                if ! [[ $idx =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#entries[@]} )); then
                    err "无效编号"
                    continue
                fi
                local removed="${entries[$((idx - 1))]}"
                local tmpf
                tmpf=$(mktemp) || { err "创建临时文件失败"; continue; }
                grep -vxF -- "$removed" "$list_file" > "$tmpf" 2>/dev/null || true
                mv "$tmpf" "$list_file"
                chmod 600 "$list_file"
                save_settings
                generate_config
                ok "已删除：${removed}"
                ;;
            3)
                if [[ $enabled_ref == "on" ]]; then
                    enabled_ref="off"
                    ok "白名单已关闭，${off_msg}"
                else
                    if [[ ${#entries[@]} -eq 0 ]]; then
                        err "白名单为空，开启后将拒绝所有连接，请先添加条目"
                        continue
                    fi
                    enabled_ref="on"
                    ok "白名单已开启，${on_msg}"
                fi
                save_settings
                generate_config
                ;;
            0)
                break
                ;;
            *)
                err "无效选择"
                continue
                ;;
        esac

        if service_active; then
            info "正在重启服务以应用白名单配置..."
            systemctl restart "$SERVICE_NAME"
            sleep 1
            if service_active; then
                ok "服务已重启"
            else
                err "重启失败，请检查：journalctl -u ${SERVICE_NAME} -n 50"
            fi
        fi
    done
}

# ---------------------------------------------------------------------------
# 8. 重载代理：设置/列表文件较新时先重新生成配置；config.yaml 较新时
#    保留手动修改，仅重启服务
# ---------------------------------------------------------------------------
reload_proxy() {
    require_env || return 1

    load_settings

    if [[ ! -f $CONFIG_FILE ]]; then
        err "配置文件不存在：${CONFIG_FILE}（请先通过菜单 2 开启一次代理）"
        return 1
    fi

    if [[ $SETTINGS_FILE -nt $CONFIG_FILE ]] \
        || [[ -f $ADMISSION_LIST && $ADMISSION_LIST -nt $CONFIG_FILE ]] \
        || [[ -f $BYPASS_LIST && $BYPASS_LIST -nt $CONFIG_FILE ]]; then
        info "检测到设置/白名单文件更新，正在重新生成配置..."
        generate_config
    fi

    if ! service_active; then
        warn "代理当前未在运行，配置已就绪，如需启动请使用菜单 2"
        return 0
    fi

    info "正在重载..."
    systemctl restart "$SERVICE_NAME"
    sleep 1
    if service_active; then
        ok "重载完成"
    else
        err "重载失败，配置可能有误，请检查：journalctl -u ${SERVICE_NAME} -n 50"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 7. 开机自启开关
# ---------------------------------------------------------------------------
toggle_autostart() {
    require_env || return 1

    if service_enabled; then
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
        ok "开机自启已关闭"
    else
        if [[ ! -f $SERVICE_FILE ]]; then
            if [[ ! -x $GOST_BIN ]]; then
                err "尚未安装 gost，请先选择菜单 1 安装后再开启自启"
                return 1
            fi
            generate_config
            write_service_unit
        fi
        systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
        ok "开机自启已开启"
    fi
}

# ---------------------------------------------------------------------------
# 主菜单
# ---------------------------------------------------------------------------
main_menu() {
    local choice
    while true; do
        clear
        load_settings
        check_env
        show_status
        echo "  1) 安装 / 更新 gost"
        echo "  2) 开启代理"
        echo "  3) 关闭代理"
        echo "  4) 设置监听端口"
        echo "  5) 设置访问鉴权"
        echo "  6) 来源 IP 白名单"
        echo "  7) 目标地址白名单"
        echo "  8) 重载代理"
        echo "  9) 开机自启（开启 / 关闭）"
        echo "  10) 退出"
        echo
        read -rp "请选择 [1-10]: " choice || { echo; exit 0; }

        case "$choice" in
            1)  install_or_update_gost; pause ;;
            2)  start_proxy;            pause ;;
            3)  stop_proxy;             pause ;;
            4)  set_port;               pause ;;
            5)  set_auth;               pause ;;
            6)  list_editor admission ;;
            7)  list_editor bypass ;;
            8)  reload_proxy;           pause ;;
            9)  toggle_autostart;       pause ;;
            10) echo "再见。"; exit 0 ;;
            *)  warn "无效选择，请输入 1-10"; sleep 1 ;;
        esac
    done
}

trap 'echo; echo "已退出。"; exit 0' INT TERM
load_settings
migrate_legacy_entries
main_menu
