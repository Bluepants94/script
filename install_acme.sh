#!/bin/bash

# ==============================================================================
#
# 脚本名称: acme_ssl_manager.sh
# 脚本功能: 一个用于管理 acme.sh 证书申请和删除的交互式脚本。
# 作者:     (在原作者基础上优化)
# 版本:     3.0
#
# ==============================================================================

# -- 脚本设置 --
set -o errexit
set -o nounset
set -o pipefail

# -- 全局常量和变量 --
readonly ACME_SH_DIR="$HOME/.acme.sh"
readonly ACME_SH_CMD="$ACME_SH_DIR/acme.sh"
readonly CERT_INSTALL_BASE_DIR="/home/ssl"
NGINX_INSTALLED=false

# -- 颜色定义 --
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_NC='\033[0m' # No Color

# -- 工具函数 --
msg_info() { echo -e "${COLOR_GREEN}[INFO]${COLOR_NC} $1"; }
msg_warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_NC} $1"; }
msg_error() { echo -e "${COLOR_RED}[ERROR]${COLOR_NC} $1" >&2; exit 1; }

# -- 核心功能函数 --
check_root() {
  if [ "$(id -u)" -ne "0" ]; then
    msg_error "请以 root 用户运行此脚本."
  fi
}

# 检查 Nginx 是否安装
check_nginx() {
  if command -v nginx &> /dev/null; then
    NGINX_INSTALLED=true
    local nginx_version
    # nginx -v 的输出在 stderr，所以需要重定向 2>&1
    nginx_version=$(nginx -v 2>&1)
    msg_info "Nginx 已安装, 版本: ${nginx_version#nginx version: }"
  else
    NGINX_INSTALLED=false
    msg_info "Nginx 未安装"
  fi
}

install_dependencies() {
  if [ ! -d "$ACME_SH_DIR" ]; then
    msg_info "正在安装 acme.sh..."
    curl https://get.acme.sh | sh
    "$ACME_SH_CMD" --upgrade --auto-upgrade
  else
    msg_info "acme.sh 已安装在 $ACME_SH_DIR"
  fi
  if ! dpkg -l | grep -qw "socat"; then
    msg_info "socat 未安装，正在安装..."
    apt-get update && apt-get install -y socat
  else
    msg_info "socat 已安装"
  fi
}

setup_aliases() {
  msg_info "正在检查和配置别名..."
  local alias_added=false
  if ! grep -q "alias ll='ls -alF'" ~/.bashrc; then
    echo "alias ll='ls -alF'" >> ~/.bashrc
    msg_info "已添加 'll' 别名。"
    alias_added=true
  fi
  if ! grep -q "alias acme.sh=" ~/.bashrc; then
    echo "alias acme.sh='$ACME_SH_CMD'" >> ~/.bashrc
    msg_info "已添加 'acme.sh' 别名。"
    alias_added=true
  fi
  if [ "$alias_added" = true ]; then
    msg_info "别名已添加到 ~/.bashrc"
    msg_warn "请执行以下命令使别名在当前终端生效: source ~/.bashrc"
    msg_warn "或者打开新的终端窗口，别名将自动生效。"
  else
    msg_info "别名已配置完毕。"
  fi
}

handle_cert_deletion() {
  echo
  msg_info "正在查找已安装的证书..."
  local cert_paths=()
  while IFS= read -r line; do
    cert_paths+=("$line")
  done < <(find "$ACME_SH_DIR" -maxdepth 1 -type d -name '*_ecc' 2>/dev/null)
  if [ ${#cert_paths[@]} -eq 0 ]; then
    msg_warn "没有找到任何证书。"
    return
  fi
  local menu_options=()
  for path in "${cert_paths[@]}"; do
    menu_options+=("$(basename "$path" _ecc)")
  done
  menu_options+=("取消操作")
  echo "请选择需要删除的证书:"
  local old_ps3=${PS3:-#? }
  PS3="请输入选项: "
  select opt in "${menu_options[@]}"; do
    if [[ "$opt" == "取消操作" ]]; then
      msg_info "操作已取消。"
      break
    fi
    if [ -n "$opt" ]; then
      local domain="$opt"
      local dir="${cert_paths[$REPLY - 1]}"
      read -p "您确定要删除域名 '${domain}' 的所有相关证书和文件吗？(y/n): " confirm
      if [[ "$confirm" != "y" ]]; then
        msg_info "删除已取消，请重新选择。"
        continue
      fi
      msg_info "正在删除证书: $domain"
      msg_info "正在尝试通过 acme.sh 吊销和移除证书..."
      set +e
      "$ACME_SH_CMD" --remove -d "$domain" --ecc
      local exit_code=$?
      set -e
      if [ $exit_code -ne 0 ]; then
        msg_warn "acme.sh --remove 命令执行时遇到问题 (退出码: $exit_code)。将继续强制清理文件。"
      fi
      local installed_cert_dir="$CERT_INSTALL_BASE_DIR/$domain"
      if [ -d "$installed_cert_dir" ]; then
        rm -rf "$installed_cert_dir"
        msg_info "已删除安装目录: $installed_cert_dir"
      fi
      if [ -d "$dir" ]; then
        rm -rf "$dir"
        msg_info "已强制删除 acme.sh 证书目录: $dir"
      fi
      msg_info "${domain} 证书及相关文件已成功删除。"
      break
    else
      msg_warn "无效选项，请重新选择。"
    fi
  done
  PS3=$old_ps3
}

set_default_ca_to_le() {
    "$ACME_SH_CMD" --set-default-ca --server letsencrypt
    msg_info "默认CA服务器已切换至Let's Encrypt"
}

# 安装证书到指定目录 (增强的错误处理)
install_certificate() {
    local domain=$1
    msg_info "正在为域名 '$domain' 安装证书..."
    local install_dir="$CERT_INSTALL_BASE_DIR/$domain"
    mkdir -p "$install_dir"

    # 根据 Nginx 是否安装来决定是否添加 reload 命令
    local reload_opt=""
    if [ "$NGINX_INSTALLED" = true ]; then
        reload_opt="--reloadcmd 'service nginx force-reload'"
    fi

    local install_cmd="$ACME_SH_CMD --install-cert -d '$domain' --ecc \
      --cert-file      '$install_dir/cert.pem' \
      --key-file       '$install_dir/key.pem' \
      --fullchain-file '$install_dir/fullchain.pem' \
      $reload_opt"

    set +e
    local output
    output=$(eval "$install_cmd" 2>&1)
    local exit_code=$?
    set -e

    # 检查核心目标：证书文件是否成功创建
    if [ -s "$install_dir/cert.pem" ] && [ -s "$install_dir/key.pem" ]; then
        msg_info "证书文件已成功安装到: $install_dir"
        # 如果命令有非零退出码，意味着可能是 reload 失败
        if [ $exit_code -ne 0 ]; then
            msg_warn "Nginx 重载失败！请检查 Nginx 配置并手动执行 'service nginx force-reload' 或 'systemctl restart nginx'。"
            msg_warn "acme.sh 输出: $output"
        elif [ "$NGINX_INSTALLED" = true ]; then
            msg_info "Nginx 服务已成功重新加载。"
        fi
    else
        # 如果证书文件不存在，则为致命错误
        msg_error "证书安装失败！无法在目标位置找到证书文件。acme.sh 输出: $output"
    fi
}

issue_certificate() {
    local issue_cmd=$1
    local domain=$2
    msg_info "正在执行证书申请命令..."
    local output
    local exit_code=0
    set +e
    output=$(eval "$issue_cmd" 2>&1)
    exit_code=$?
    set -e
    echo "$output"
    case $exit_code in
        0)
            install_certificate "$domain"
            msg_info "证书申请流程全部完成！"
            ;;
        2)
            read -p "证书未更改。是否需要强制续签？(y/n): " force_update
            if [[ "$force_update" == "y" ]]; then
                msg_info "正在强制续签..."
                issue_certificate "$issue_cmd --force" "$domain"
            else
                msg_info "操作已取消。"
            fi
            ;;
        *)
            if echo "$output" | grep -q "Verify error"; then
                msg_error "域名验证失败。请检查DNS API凭证是否正确，或相关域名权限配置。"
            elif echo "$output" | grep -q "Error creating new order"; then
                msg_error "创建订单失败。请检查您的域名和 CA 账户信息是否正确。"
            else
                msg_error "ACME 证书申请失败 (退出码: $exit_code)。请检查以上 acme.sh 输出日志获取详细信息。"
            fi
            ;;
    esac
}

handle_dns_provider_selection() {
    echo
    echo "请选择您的 DNS 服务商:"
    echo "  1. Cloudflare"
    echo "  2. HuaweiCloud"
    read -p "请输入选项 (1-2): " provider_option
    local domain
    read -p "请输入要申请证书的域名 (例如: example.com): " domain
    if [ -z "$domain" ]; then
        msg_error "域名不能为空。"
    fi
    case $provider_option in
        1)
            local cf_key cf_email
            read -rs -p "请输入 Cloudflare Global API Key: " cf_key
            echo
            read -p "请输入 Cloudflare 账户邮箱: " cf_email
            export CF_Key="$cf_key"
            export CF_Email="$cf_email"
            local cmd="$ACME_SH_CMD --issue -d '$domain' --ecc --dns dns_cf"
            issue_certificate "$cmd" "$domain"
            ;;
        2)
            local huawei_user huawei_pass huawei_domain
            read -p "请输入华为云 IAM 用户名 (Username): " huawei_user
            read -rs -p "请输入华为云 IAM 用户密码 (Password): " huawei_pass
            echo
            read -p "请输入华为云域名所在的项目名 (DomainName): " huawei_domain
            export HUAWEICLOUD_Username="$huawei_user"
            export HUAWEICLOUD_Password="$huawei_pass"
            export HUAWEICLOUD_DomainName="$huawei_domain"
            local cmd="$ACME_SH_CMD --issue -d '$domain' --ecc --dns dns_huaweicloud"
            issue_certificate "$cmd" "$domain"
            ;;
        *) msg_error "无效的服务商选项";;
    esac
}

handle_cert_application() {
    set_default_ca_to_le
    echo
    echo "请选择证书申请方式:"
    echo "  1. Standalone (HTTP-01)"
    echo "  2. DNS API (DNS-01)"
    read -p "请输入选项 (1-2): " option
    case $option in
      1)
        local domain
        read -p "请输入要申请证书的域名 (例如: example.com): " domain
        if [ -z "$domain" ]; then
            msg_error "域名不能为空。"
        fi
        local cmd="$ACME_SH_CMD --issue -d '$domain' --ecc --standalone"
        issue_certificate "$cmd" "$domain"
        ;;
      2)
        handle_dns_provider_selection
        ;;
      *) msg_error "无效选项";;
    esac
}

# -- 主函数 --
main() {
  check_root
  check_nginx
  install_dependencies
  setup_aliases

  echo
  echo "================================="
  echo "    ACME.sh 证书管理脚本"
  echo "================================="
  echo "请选择要执行的操作:"
  echo "  1. 申请新证书"
  echo "  2. 删除现有证书"
  echo "  3. 退出"
  read -p "请输入选项 (1-3): " main_option

  case $main_option in
    1) handle_cert_application;;
    2) handle_cert_deletion;;
    3) msg_info "退出脚本。";;
    *) msg_error "无效选项";;
  esac

  msg_info "操作完成。"
}

# -- 脚本入口 --
main
