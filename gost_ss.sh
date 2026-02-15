#!/bin/bash

# ============================================================
#  GOST v3 - SOCKS5 → Shadowsocks 转发管理脚本
#  功能 安装卸载配置管理 GOST 转发服务
#  协议 SOCKS5 入站 → SS 出站 (TCP + UDP)
# ============================================================

# ---------- 颜色定义 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # 无颜色

# ---------- 路径定义 ----------
GOST_BIN=/usr/local/bin/gost
SERVICE_FILE=/etc/systemd/system/gost-ss.service
CONFIG_FILE=/etc/gost/config.yaml
CONFIG_DIR=/etc/gost

# ---------- 工具函数 ----------
print_banner() {
    clear
    echo -e ${CYAN}
    echo ╔══════════════════════════════════════════════╗
    echo ║     GOST v3 SOCKS5 → SS 转发管理工具        ║
    echo ║     支持 TCP + UDP 同时转发                  ║
    echo ╚══════════════════════════════════════════════╝
    echo -e ${NC}
}

print_info()    { echo -e ${GREEN}[信息]${NC} $1; }
print_warn()    { echo -e ${YELLOW}[警告]${NC} $1; }
print_error()   { echo -e ${RED}[错误]${NC} $1; }
print_success() { echo -e ${GREEN}[成功]${NC} $1; }

press_any_key() {
    echo 
    read -n 1 -s -r -p 按任意键返回主菜单...
    echo 
}

# ---------- 检查 root 权限 ----------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error 请使用 root 权限运行此脚本！
        print_info 使用方法 sudo bash $0
        exit 1
    fi
}

# ---------- 检测系统架构 ----------
get_arch() {
    local arch
    arch=$(uname -m)
    case $arch in
        x86_64)  echo amd64 ;;
        aarch64) echo arm64 ;;
        armv7l)  echo armv7 ;;
        i686)    echo 386 ;;
        )
            print_error 不支持的系统架构 $arch
            exit 1
            ;;
    esac
}

# ---------- 检查 GOST 是否已安装 ----------
check_gost_installed() {
    if [[ -f $GOST_BIN ]]; then
        return 0
    else
        return 1
    fi
}

# ---------- 获取 GOST 版本 ----------
get_gost_version() {
    if check_gost_installed; then
        $GOST_BIN -V 2>&1 | head -n 1
    else
        echo 未安装
    fi
}

# ---------- 下载安装 GOST v3 ----------
install_gost_binary() {
    if check_gost_installed; then
        local version
        version=$(get_gost_version)
        print_info GOST 已安装 $version
        echo 
        read -r -p 是否重新安装更新？[yN]  confirm
        if [[ $confirm != y && $confirm != Y ]]; then
            print_info 跳过安装 GOST 二进制文件
            return 0
        fi
    fi

    # 检查依赖工具
    for cmd in curl tar gzip; do
        if ! command -v $cmd &>/dev/null; then
            print_error 缺少依赖工具 $cmd，请先安装
            return 1
        fi
    done

    print_info 正在获取 GOST v3 最新版本信息...

    # 获取最新版本号
    local latest_version
    latest_version=$(curl -sL --connect-timeout 10 --max-time 30 \
        https://api.github.com/repos/go-gost/gost/releases/latest \
        | grep 'tag_name' \
        | sed -E 's/.*"([^\"]+)".*/\1/')

    if [[ -z $latest_version ]]; then
        print_warn 无法从 GitHub API 获取版本信息，尝试备用方式...
        latest_version=$(curl -sL --connect-timeout 10 --max-time 30 \
            -o /dev/null -w '%{redirect_url}' \
            https://github.com/go-gost/gost/releases/latest \
            | grep -oP 'tag/\K[^/]+')
        if [[ -z $latest_version ]]; then
            print_error 无法获取最新版本信息，请检查网络连接
            return 1
        fi
    fi

    print_info 最新版本 $latest_version

    local arch
    arch=$(get_arch)
    local version_num=${latest_version#v}
    local filename=gost_${version_num}_linux_${arch}.tar.gz
    local download_url=https://github.com/go-gost/gost/releases/download/${latest_version}/${filename}

    print_info 正在下载 $filename
    print_info 下载地址 $download_url

    # 创建临时目录
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local filepath=${tmp_dir}/${filename}

    # 下载文件（使用 -L 跟随重定向，显示进度）
    if ! curl -L --connect-timeout 15 --max-time 300 --retry 3 --retry-delay 3 
        -o $filepath --progress-bar $download_url; then
        print_error 下载失败，请检查网络连接
        rm -rf $tmp_dir
        return 1
    fi

    # 验证下载的文件
    local filesize
    filesize=$(stat -c%s $filepath 2>/dev/null || stat -f%z $filepath 2>/dev/null || echo 0)

    if [[ $filesize -lt 1000000 ]]; then
        print_error 下载的文件大小异常 (${filesize} bytes)，可能下载失败
        print_warn 文件内容预览
        head -c 200 $filepath 2>/dev/null
        echo 
        rm -rf $tmp_dir
        return 1
    fi

    print_info 文件大小 $(( filesize  1024  1024 )) MB

    # 验证文件是否为 gzip 格式
    if ! file $filepath 2>/dev/null | grep -qi "gzip compressed"; then
        # 备用检查：检查 gzip 魔数 (1f 8b)
        local magic
        magic=$(xxd -l 2 -p $filepath 2>/dev/null)
        if [[ $magic != 1f8b ]]; then
            print_error 下载的文件不是有效的 gzip 格式
            print_warn 文件头信息
            xxd -l 16 $filepath 2>/dev/null | head -c 50
            echo 
            rm -rf $tmp_dir
            return 1
        fi
    fi

    print_info 正在解压安装...

    # 解压
    if ! tar -xzf $filepath -C $tmp_dir 2>&1; then
        print_error 解压失败
        rm -rf $tmp_dir
        return 1
    fi

    # 查找 gost 可执行文件（可能在子目录中）
    local gost_file
    gost_file=$(find $tmp_dir -name gost -type f | head -n 1)

    if [[ -n $gost_file ]]; then
        mv $gost_file $GOST_BIN
        chmod +x $GOST_BIN
        print_success GOST 安装成功 $GOST_BIN
    else
        print_error 解压后未找到 gost 可执行文件
        print_warn 解压目录内容
        ls -la $tmp_dir
        rm -rf $tmp_dir
        return 1
    fi

    # 清理临时文件
    rm -rf $tmp_dir

    # 验证安装
    local version
    version=$(get_gost_version)
    print_success 安装版本 $version
    return 0
}

# ---------- 用户输入单条转发配置 ----------
input_single_config() {
    echo 
    echo -e ${BOLD}${BLUE}========== 请输入第 $1 条转发配置 ==========${NC}
    echo 

    # SS 密码
    while true; do
        read -r -p 请输入 SS 密码  ss_password
        if [[ -n $ss_password ]]; then
            break
        fi
        print_error 密码不能为空！
    done

    # 加密方式
    echo 
    echo -e ${CYAN}常用加密方式${NC}
    echo   1) aes-128-gcm
    echo   2) aes-256-gcm
    echo   3) chacha20-ietf-poly1305
    echo   4) 自定义输入
    echo 
    read -r -p 请选择加密方式 [1-4] (默认 2)  method_choice
    case $method_choice in
        1) ss_method=aes-128-gcm ;;
        3) ss_method=chacha20-ietf-poly1305 ;;
        4)
            read -r -p 请输入自定义加密方式  ss_method
            if [[ -z $ss_method ]]; then
                ss_method=aes-256-gcm
                print_warn 未输入，使用默认 aes-256-gcm
            fi
            ;;
        *) ss_method=aes-256-gcm ;;
    esac

    # SS 监听端口
    echo 
    while true; do
        read -r -p 请输入 SS 监听端口 (默认 8388)  ss_port
        ss_port=${ss_port-8388}
        if [[ $ss_port =~ ^[0-9]+$ ]] && [ $ss_port -ge 1 ] && [ $ss_port -le 65535 ]; then
            break
        fi
        print_error 端口号无效，请输入 1-65535 之间的数字！
    done

    # SOCKS5 地址
    echo 
    while true; do
        read -r -p 请输入上游 SOCKS5 代理地址 (如 127.0.0.1:1080)  socks5_addr
        if [[ -n $socks5_addr ]]; then
            break
        fi
        print_error SOCKS5 地址不能为空！
    done

    # 返回配置信息
    echo "${ss_password}|${ss_method}|${ss_port}|${socks5_addr}"
}

# ---------- 用户输入多条转发配置 ----------
input_multi_config() {
    echo 
    echo -e ${BOLD}${BLUE}========== 请输入多条转发配置 ==========${NC}
    echo 

    # 获取转发数量
    while true; do
        read -r -p 请输入转发数量 (默认 1)  num_forwards
        num_forwards=${num_forwards-1}
        if [[ $num_forwards =~ ^[0-9]+$ ]] && [ $num_forwards -ge 1 ] && [ $num_forwards -le 100 ]; then
            break
        fi
        print_error 数量无效，请输入 1-100 之间的数字！
    done

    # 初始化数组
    declare -a configs
    config_count=0

    for ((i=1; i<=num_forwards; i++)); do
        config_result=$(input_single_config $i)
        IFS='|' read -ra config_parts <<< "$config_result"
        
        # 添加到配置数组
        configs+=("${config_parts[0]}|${config_parts[1]}|${config_parts[2]}|${config_parts[3]}")
        ((config_count++))
        
        echo -e ${GREEN}第 $i 条配置已添加${NC}
        echo 
    done

    # 显示所有配置确认
    echo 
    echo -e ${BOLD}${BLUE}========== 所有配置确认 ==========${NC}
    for ((i=0; i<${#configs[@]}; i++)); do
        IFS='|' read -ra config_parts <<< "${configs[i]}"
        echo -e   第 $((i+1)) 条配置
        echo -e     SS 密码      ${GREEN}${config_parts[0]}${NC}
        echo -e     加密方式     ${GREEN}${config_parts[1]}${NC}
        echo -e     SS 监听端口  ${GREEN}${config_parts[2]}${NC}
        echo -e     SOCKS5 地址  ${GREEN}${config_parts[3]}${NC}
        echo 
    done
    echo -e ${BOLD}${BLUE}=================================${NC}
    echo 

    read -r -p 确认以上所有配置？[Yn]  confirm
    if [[ $confirm == n || $confirm == N ]]; then
        print_warn 已取消，请重新输入
        return 1
    fi

    # 将配置保存到全局变量
    GLOB_CONFIGS=("${configs[@]}")
    GLOB_CONFIG_COUNT=$config_count

    return 0
}

# ---------- 创建配置文件 ----------
create_config() {
    mkdir -p $CONFIG_DIR

    # 生成配置文件内容
    {
        echo "# GOST v3 配置文件 - SOCKS5 → Shadowsocks 转发"
        echo "# 自动生成，请勿手动修改（可通过脚本修改配置菜单修改）"
        echo ""
        echo "services:"
        
        # 为每个配置创建服务项
        for ((i=0; i<GLOB_CONFIG_COUNT; i++)); do
            IFS='|' read -ra config_parts <<< "${GLOB_CONFIGS[i]}"
            ss_password="${config_parts[0]}"
            ss_method="${config_parts[1]}"
            ss_port="${config_parts[2]}"
            socks5_addr="${config_parts[3]}"
            
            # TCP转发服务
            echo "  - name: ss-forward-${i}-tcp"
            echo "    addr: ${ss_port}"
            echo "    handler:"
            echo "      type: ss"
            echo "      auth:"
            echo "        username: ${ss_method}"
            echo "        password: ${ss_password}"
            echo "    listener:"
            echo "      type: tcp"
            echo "    forwarder:"
            echo "      nodes:"
            echo "        - name: socks5-upstream-${i}-tcp"
            echo "          addr: ${socks5_addr}"
            echo "          connector:"
            echo "            type: socks5"
            echo ""
            
            # UDP转发服务
            echo "  - name: ss-forward-${i}-udp"
            echo "    addr: ${ss_port}"
            echo "    handler:"
            echo "      type: ss"
            echo "      auth:"
            echo "        username: ${ss_method}"
            echo "        password: ${ss_password}"
            echo "    listener:"
            echo "      type: udp"
            echo "    forwarder:"
            echo "      nodes:"
            echo "        - name: socks5-upstream-${i}-udp"
            echo "          addr: ${socks5_addr}"
            echo "          connector:"
            echo "            type: socks5"
            echo ""
        done
    } > $CONFIG_FILE

    print_success 配置文件已创建 $CONFIG_FILE
}

# ---------- 创建 Systemd 服务 ----------
create_service() {
    # 为多条转发创建单独的服务文件
    for ((i=0; i<GLOB_CONFIG_COUNT; i++)); do
        IFS='|' read -ra config_parts <<< "${GLOB_CONFIGS[i]}"
        ss_password="${config_parts[0]}"
        ss_method="${config_parts[1]}"
        ss_port="${config_parts[2]}"
        socks5_addr="${config_parts[3]}"
        
        # 创建独立的服务文件
        service_file_i="/etc/systemd/system/gost-ss-${i}.service"
        cat > $service_file_i << EOF
[Unit]
Description=GOST v3 SOCKS5 to Shadowsocks Forwarding Service - Port ${ss_port}
Documentation=httpsgost.run
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${GOST_BIN} -L ss://${ss_method}:${ss_password}@:${ss_port}?udp=true -F socks5://${socks5_addr}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

        print_success 服务文件已创建 $service_file_i
    done

    # 重新加载 systemd
    systemctl daemon-reload
}

# ---------- 安装完整流程 ----------
do_install() {
    print_banner
    echo -e ${BOLD}${GREEN}[ 安装 GOST 并配置转发 ]${NC}
    echo 

    # 步骤1 安装 GOST 二进制文件
    print_info 步骤 1/4 安装 GOST...
    if ! install_gost_binary; then
        print_error GOST 安装失败！
        press_any_key
        return
    fi

    # 步骤2 用户输入配置
    echo 
    print_info 步骤 2/4 配置转发参数...
    while true; do
        if input_multi_config; then
            break
        fi
    done

    # 步骤3 创建配置文件
    echo 
    print_info 步骤 3/4 创建配置文件...
    create_config

    # 步骤4 创建服务文件
    echo 
    print_info 步骤 4/4 创建系统服务...
    create_service

    # 启用并启动所有服务
    echo 
    print_info 正在启用并启动所有转发服务...
    for ((i=0; i<GLOB_CONFIG_COUNT; i++)); do
        service_name="gost-ss-${i}.service"
        systemctl enable $service_name 2>/dev/null
        systemctl start $service_name
        sleep 1
        
        if systemctl is-active --quiet $service_name; then
            print_success 服务 $service_name 已启动！
        else
            print_error 服务 $service_name 启动失败，请查看日志
            echo -e ${YELLOW}  journalctl -u $service_name -n 20${NC}
        fi
    done

    print_success 所有 GOST 转发服务已启动！
    echo 
    echo -e ${BOLD}${GREEN}========== 安装完成 ==========${NC}
    echo -e   已创建 ${GLOB_CONFIG_COUNT} 条转发服务
    for ((i=0; i<GLOB_CONFIG_COUNT; i++)); do
        IFS='|' read -ra config_parts <<< "${GLOB_CONFIGS[i]}"
        ss_password="${config_parts[0]}"
        ss_method="${config_parts[1]}"
        ss_port="${config_parts[2]}"
        echo -e   转发 ${i+1}: 端口 ${ss_port}，密码 ${ss_password}
    done
    echo -e ${BOLD}${GREEN}===============================${NC}

    press_any_key
}

# ---------- 卸载完整流程 ----------
do_uninstall() {
    print_banner
    echo -e ${BOLD}${RED}[ 卸载 GOST ]${NC}
    echo 

    if ! check_gost_installed; then
        print_warn GOST 未安装，无需卸载
        press_any_key
        return
    fi

    echo -e ${RED}${BOLD}警告 此操作将完全卸载 GOST，包括${NC}
    echo -e   - 停止并禁用所有 gost-ss 服务
    echo -e   - 删除服务文件
    echo -e   - 删除二进制文件 $GOST_BIN
    echo -e   - 删除配置目录 $CONFIG_DIR
    echo 

    read -r -p 确认卸载？请输入 'yes' 确认  confirm
    if [[ $confirm != yes ]]; then
        print_info 已取消卸载
        press_any_key
        return
    fi

    echo 

    # 停止所有服务
    for service_file in /etc/systemd/system/gost-ss-*.service; do
        if [[ -f "$service_file" ]]; then
            service_name=$(basename "$service_file")
            if systemctl is-active --quiet "$service_name" 2>/dev/null; then
                print_info 正在停止服务 $service_name...
                systemctl stop "$service_name"
                print_success 服务 $service_name 已停止
            fi
            
            if systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
                print_info 正在禁用开机自启 $service_name...
                systemctl disable "$service_name" 2>/dev/null
                print_success 服务 $service_name 已禁用开机自启
            fi
        fi
    done

    # 删除所有服务文件
    for service_file in /etc/systemd/system/gost-ss-*.service; do
        if [[ -f "$service_file" ]]; then
            rm -f "$service_file"
            print_success 服务文件已删除 $service_file
        fi
    done

    # 删除二进制文件
    if [[ -f $GOST_BIN ]]; then
        rm -f $GOST_BIN
        print_success 二进制文件已删除 $GOST_BIN
    fi

    # 删除配置文件目录
    if [[ -d $CONFIG_DIR ]]; then
        rm -rf $CONFIG_DIR
        print_success 配置目录已删除 $CONFIG_DIR
    fi

    # 重新加载 systemd
    systemctl daemon-reload

    echo 
    print_success GOST 已完全卸载！

    press_any_key
}

# ---------- 查看服务状态 ----------
do_status() {
    print_banner
    echo -e ${BOLD}${BLUE}[ 服务状态 ]${NC}
    echo 

    # GOST 安装状态
    if check_gost_installed; then
        local version
        version=$(get_gost_version)
        echo -e   GOST 安装状态 ${GREEN}已安装${NC} ($version)
    else
        echo -e   GOST 安装状态 ${RED}未安装${NC}
        press_any_key
        return
    fi

    # 统计服务数量
    local service_files=($(ls /etc/systemd/system/gost-ss-*.service 2>/dev/null))
    local total_services=${#service_files[@]}
    
    if [ $total_services -gt 0 ]; then
        echo -e   服务文件      ${GREEN}已配置${NC} (${total_services}个服务)
        
        # 检查每个服务的状态
        local running_count=0
        local enabled_count=0
        
        for service_file in "${service_files[@]}"; do
            service_name=$(basename "$service_file")
            local status
            status=$(systemctl is-active "$service_name" 2>/dev/null)
            if [[ $status == active ]]; then
                ((running_count++))
            fi
            
            local enabled
            enabled=$(systemctl is-enabled "$service_name" 2>/dev/null)
            if [[ $enabled == enabled ]]; then
                ((enabled_count++))
            fi
        done
        
        if [ $running_count -eq $total_services ]; then
            echo -e   运行状态      ${GREEN}全部运行中${NC} ($running_count/$total_services)
        elif [ $running_count -gt 0 ]; then
            echo -e   运行状态      ${YELLOW}部分运行中${NC} ($running_count/$total_services)
        else
            echo -e   运行状态      ${RED}全部已停止${NC} ($running_count/$total_services)
        fi
        
        if [ $enabled_count -eq $total_services ]; then
            echo -e   开机自启      ${GREEN}全部启用${NC} ($enabled_count/$total_services)
        elif [ $enabled_count -gt 0 ]; then
            echo -e   开机自启      ${YELLOW}部分启用${NC} ($enabled_count/$total_services)
        else
            echo -e   开机自启      ${RED}全部未启用${NC} ($enabled_count/$total_services)
        fi
    else
        echo -e   服务文件      ${RED}未配置${NC}
    fi

    # 显示所有服务的详细配置
    if [ $total_services -gt 0 ]; then
        echo 
        echo -e ${BOLD}${BLUE}[ 所有转发配置详情 ]${NC}
        for service_file in "${service_files[@]}"; do
            service_name=$(basename "$service_file")
            echo -e ${BOLD}服务: ${CYAN}$service_name${NC}
            
            local exec_line
            exec_line=$(grep ExecStart "$service_file" 2>/dev/null)
            if [[ -n $exec_line ]]; then
                # 解析配置
                local current_method current_password current_port current_socks5
                current_method=$(echo $exec_line | grep -oP 'ss://\K[^:]+')
                current_password=$(echo $exec_line | grep -oP ':[^@]+@' | sed 's/[/:@]//g')
                current_port=$(echo $exec_line | grep -oP ':[0-9]+\?' | sed 's/[?:]//g')
                current_socks5=$(echo $exec_line | grep -oP 'socks5://[^"]*')
                
                echo -e   加密方式     ${CYAN}${current_method}${NC}
                echo -e   SS 密码      ${CYAN}${current_password}${NC}
                echo -e   SS 端口      ${CYAN}${current_port}${NC}
                echo -e   SOCKS5 上游  ${CYAN}${current_socks5}${NC}
            fi
            echo
        done
    fi

    echo 
    echo -e ${BOLD}${BLUE}[ 所有服务日志摘要 ]${NC}
    for service_file in "${service_files[@]}" 2>/dev/null; do
        service_name=$(basename "$service_file")
        echo -e ${BOLD}日志: ${CYAN}$service_name${NC}
        journalctl -u "$service_name" -n 3 --no-pager 2>/dev/null || echo "   (无日志)"
        echo
    done

    press_any_key
}

# ---------- 重启服务 ----------
do_restart() {
    print_banner
    echo -e ${BOLD}${BLUE}[ 重启服务 ]${NC}
    echo 

    # 检查是否有任何gost服务存在
    local service_files=($(ls /etc/systemd/system/gost-ss-*.service 2>/dev/null))
    local total_services=${#service_files[@]}

    if [ $total_services -eq 0 ]; then
        print_error 服务未配置，请先安装！
        press_any_key
        return
    fi

    print_info 正在重启 $total_services 个 gost-ss 服务...
    
    for service_file in "${service_files[@]}"; do
        service_name=$(basename "$service_file")
        systemctl restart "$service_name"
        sleep 1
        
        if systemctl is-active --quiet "$service_name"; then
            print_success 服务 $service_name 已成功重启！
        else
            print_error 服务 $service_name 重启失败，请查看日志
            echo -e ${YELLOW}  journalctl -u $service_name -n 20${NC}
        fi
    done

    press_any_key
}

# ---------- 停止服务 ----------
do_stop() {
    print_banner
    echo -e ${BOLD}${YELLOW}[ 停止服务 ]${NC}
    echo 

    # 检查是否有任何gost服务存在
    local service_files=($(ls /etc/systemd/system/gost-ss-*.service 2>/dev/null))
    local total_services=${#service_files[@]}

    if [ $total_services -eq 0 ]; then
        print_error 服务未配置，请先安装！
        press_any_key
        return
    fi

    # 检查是否有正在运行的服务
    local running_count=0
    for service_file in "${service_files[@]}"; do
        service_name=$(basename "$service_file")
        if systemctl is-active --quiet "$service_name"; then
            ((running_count++))
        fi
    done

    if [ $running_count -eq 0 ]; then
        print_warn 所有服务当前都未运行
        press_any_key
        return
    fi

    print_info 正在停止 $running_count 个正在运行的 gost-ss 服务...
    
    for service_file in "${service_files[@]}"; do
        service_name=$(basename "$service_file")
        if systemctl is-active --quiet "$service_name"; then
            systemctl stop "$service_name"
            print_success 服务 $service_name 已停止
        fi
    done

    press_any_key
}

# ---------- 修改配置 ----------
do_modify() {
    print_banner
    echo -e ${BOLD}${BLUE}[ 修改配置 ]${NC}
    echo 

    # 检查是否有任何gost服务存在
    local service_files=($(ls /etc/systemd/system/gost-ss-*.service 2>/dev/null))
    local total_services=${#service_files[@]}

    if [ $total_services -eq 0 ]; then
        print_error 服务未配置，请先安装！
        press_any_key
        return
    fi

    print_info 检测到 $total_services 个转发服务
    echo
    
    # 显示所有服务供用户选择
    echo -e ${BOLD}现有服务列表${NC}
    for i in "${!service_files[@]}"; do
        service_name=$(basename "${service_files[$i]}")
        echo -e "  ${i}) $service_name"
    done
    echo

    # 让用户选择要修改的服务
    while true; do
        read -r -p "请选择要修改的服务 (0-$((total_services-1))) 或输入 'all' 修改所有服务"  selection
        if [[ "$selection" == "all" ]]; then
            modify_all=true
            break
        elif [[ $selection =~ ^[0-9]+$ ]] && [ $selection -ge 0 ] && [ $selection -lt $total_services ]; then
            selected_index=$selection
            modify_all=false
            break
        else
            print_error 无效选择，请输入 0-$((total_services-1)) 或 'all'"
        fi
    done

    if [ "$modify_all" = true ]; then
        # 重新输入所有配置
        print_info 正在重新配置所有服务...
        while true; do
            if input_multi_config; then
                break
            fi
        done
        
        # 重建所有配置和服务
        create_config
        create_service
        
        # 重启所有服务
        print_info 正在重启所有服务以应用新配置...
        for service_file in "${service_files[@]}"; do
            service_name=$(basename "$service_file")
            systemctl restart "$service_name"
            sleep 1
            
            if systemctl is-active --quiet "$service_name"; then
                print_success 服务 $service_name 已更新并重启！
            else
                print_error 服务 $service_name 重启失败，请查看日志
                echo -e ${YELLOW}  journalctl -u $service_name -n 20${NC}
            fi
        done
    else
        # 修改单个服务
        selected_service_file="${service_files[$selected_index]}"
        selected_service_name=$(basename "$selected_service_file")
        
        # 解析当前选定服务的配置
        local exec_line
        exec_line=$(grep ExecStart "$selected_service_file" 2>/dev/null)
        
        local current_method current_password current_port current_socks5
        # 使用更精确的正则表达式解析配置
        current_method=$(echo $exec_line | grep -oP 'ss://\K[^:]+(?::)')
        current_password=$(echo $exec_line | grep -oP ':[^@]+(?=@)' | sed 's/^://' )
        current_port=$(echo $exec_line | grep -oP ':[0-9]+\?' | sed 's/[?:]//g')
        current_socks5=$(echo $exec_line | grep -oP 'socks5://[^"]*' | sed 's/socks5:\/\///')
        
        echo -e ${BOLD}当前配置 (直接回车保持不变)${NC}
        echo -e "  服务: ${selected_service_name}"
        echo 

        # SS 密码
        read -r -p "SS 密码 [${current_password}] "  new_password
        ss_password=${new_password-$current_password}

        # 加密方式
        read -r -p "加密方式 [${current_method}] "  new_method
        ss_method=${new_method-$current_method}

        # SS 端口
        while true; do
            read -r -p "SS 端口 [${current_port}] "  new_port
            ss_port=${new_port-$current_port}
            if [[ $ss_port =~ ^[0-9]+$ ]] && [ $ss_port -ge 1 ] && [ $ss_port -le 65535 ]; then
                break
            fi
            print_error 端口号无效，请输入 1-65535 之间的数字！
        done

        # SOCKS5 地址
        read -r -p "SOCKS5 地址 [${current_socks5}] "  new_socks5
        socks5_addr=${new_socks5-$current_socks5}

        # 确认
        echo 
        echo -e ${BOLD}${BLUE}========== 新配置确认 ==========${NC}
        echo -e "  服务: ${selected_service_name}"
        echo -e   SS 密码      ${GREEN}${ss_password}${NC}
        echo -e   加密方式     ${GREEN}${ss_method}${NC}
        echo -e   SS 监听端口  ${GREEN}${ss_port}${NC}
        echo -e   SOCKS5 地址  ${GREEN}${socks5_addr}${NC}
        echo -e ${BOLD}${BLUE}=================================${NC}
        echo 

        read -r -p 确认修改？[Yn]  confirm
        if [[ $confirm == n  $confirm == N ]]; then
            print_info 已取消修改
            press_any_key
            return
        fi

        # 从现有配置中提取所有配置，然后更新选中的那一个
        local all_configs=()
        local config_count=0
        
        # 从配置文件中提取所有现有配置
        if [[ -f $CONFIG_FILE ]]; then
            # 解析yaml格式的配置文件来获取现有配置
            while IFS= read -r line; do
                if [[ $line =~ addr:[[:space:]]*([0-9]+) ]]; then
                    port="${BASH_REMATCH[1]}"
                    # 这里需要进一步解析完整的配置，但为了简化，我们采用另一种方法
                fi
            done < $CONFIG_FILE
        fi
        
        # 为简化实现，我们重新收集所有配置（包括修改的）
        # 首先显示当前所有配置
        print_info 提取当前所有配置...
        
        # 临时保存当前全局变量
        local old_configs=("${GLOB_CONFIGS[@]:-}")
        local old_config_count=${GLOB_CONFIG_COUNT:-0}
        
        # 重新构建配置数组，替换被修改的那个
        local new_configs=()
        local new_config_count=0
        
        for ((i=0; i<total_services; i++)); do
            service_file="${service_files[$i]}"
            service_name=$(basename "$service_file")
            
            # 解析服务配置
            local exec_line
            exec_line=$(grep ExecStart "$service_file" 2>/dev/null)
            
            if [ $i -eq $selected_index ]; then
                # 这是要修改的服务，使用新值
                new_configs+=("${ss_password}|${ss_method}|${ss_port}|${socks5_addr}")
            else
                # 这是其他服务，使用原值
                local current_method current_password current_port current_socks5
                current_method=$(echo $exec_line | grep -oP 'ss://\K[^:]+(?::)')
                current_password=$(echo $exec_line | grep -oP ':[^@]+(?=@)' | sed 's/^://' )
                current_port=$(echo $exec_line | grep -oP ':[0-9]+\?' | sed 's/[?:]//g')
                current_socks5=$(echo $exec_line | grep -oP 'socks5://[^"]*' | sed 's/socks5:\/\///')
                
                new_configs+=("${current_password}|${current_method}|${current_port}|${current_socks5}")
            fi
            ((new_config_count++))
        done
        
        # 更新全局变量
        GLOB_CONFIGS=("${new_configs[@]}")
        GLOB_CONFIG_COUNT=$new_config_count
        
        # 重建配置和服务文件
        create_config
        create_service
        
        # 重启被修改的服务
        print_info 正在重启服务以应用新配置...
        systemctl restart "$selected_service_name"
        sleep 1

        if systemctl is-active --quiet "$selected_service_name"; then
            print_success 配置已更新，服务 $selected_service_name 已重启！
        else
            print_error 服务重启失败，请查看日志
            echo -e ${YELLOW}  journalctl -u $selected_service_name -n 20${NC}
        fi
    fi

    press_any_key
}

# ---------- 主菜单 ----------
show_menu() {
    print_banner

    # 显示简要状态
    if check_gost_installed; then
        # 检查是否存在任何gost服务
        local service_files=($(ls /etc/systemd/system/gost-ss-*.service 2>/dev/null))
        local total_services=${#service_files[@]}
        
        if [ $total_services -gt 0 ]; then
            # 检查运行状态
            local running_count=0
            for service_file in "${service_files[@]}"; do
                service_name=$(basename "$service_file")
                if systemctl is-active --quiet "$service_name" 2>/dev/null; then
                    ((running_count++))
                fi
            done
            
            if [ $running_count -eq $total_services ]; then
                status_text="${GREEN}● 全部运行中 ($total_services/${total_services})${NC}"
            elif [ $running_count -gt 0 ]; then
                status_text="${YELLOW}● 部分运行中 ($running_count/${total_services})${NC}"
            else
                status_text="${RED}● 全部已停止 ($total_services/${total_services})${NC}"
            fi
        else
            status_text="${YELLOW}● 已安装但未配置${NC}"
        fi
        echo -e   状态 $status_text
    else
        echo -e   状态 ${YELLOW}● 未安装${NC}
    fi
    echo 

    echo -e   ${GREEN}1)${NC} 安装 GOST 并配置转发
    echo -e   ${RED}2)${NC} 卸载 GOST（移除所有配置）
    echo -e   ${BLUE}3)${NC} 查看服务状态
    echo -e   ${CYAN}4)${NC} 重启服务
    echo -e   ${YELLOW}5)${NC} 停止服务
    echo -e   ${BLUE}6)${NC} 修改配置
    echo -e   ${NC}0)${NC} 退出
    echo 

    read -r -p 请选择操作 [0-6]  choice
}

# ---------- 主入口 ----------
main() {
    check_root

    while true; do
        show_menu
        case $choice in
            1) do_install ;;
            2) do_uninstall ;;
            3) do_status ;;
            4) do_restart ;;
            5) do_stop ;;
            6) do_modify ;;
            0)
                echo 
                print_info 再见！
                exit 0
                ;;
            )
                print_error 无效选择，请输入 0-6
                sleep 1
                ;;
        esac
    done
}

# 启动脚本
main
