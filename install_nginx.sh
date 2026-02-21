#!/bin/bash
set -e

# ========== 日志函数 ==========
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
error_exit() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ $1" >&2; exit 1; }

# ========== 定义Nginx下载页面和配置文件下载链接 ==========
NGINX_DOWNLOAD_PAGE="http://nginx.org/download/"
NGINX_CONF_URL="https://bluepants.oss-cn-hangzhou.aliyuncs.com/shell/nginx/nginx.conf"

# ========== 获取最新版本号 ==========
log "正在从 $NGINX_DOWNLOAD_PAGE 获取最新版本..."
LATEST_VERSION=$(curl -s "$NGINX_DOWNLOAD_PAGE" | grep -oP 'nginx-\K[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -n 1)
if [ -z "$LATEST_VERSION" ]; then
    error_exit "无法获取最新的Nginx版本号，请检查网络连接或下载页面。"
fi
log "检测到最新的Nginx版本为: $LATEST_VERSION"

# ========== 检查当前安装状态 ==========
IS_FRESH_INSTALL=true
if command -v nginx &> /dev/null; then
    IS_FRESH_INSTALL=false
    INSTALLED_VERSION=$(nginx -v 2>&1 | grep -oP "(?<=nginx/)[^ ]+")
    log "检测到已安装的Nginx版本: $INSTALLED_VERSION"
    if [ "$INSTALLED_VERSION" == "$LATEST_VERSION" ]; then
        read -p "Nginx已经是最新版本: $LATEST_VERSION。是否重新安装？(y/n): " REINSTALL
        if [ "$REINSTALL" != "y" ]; then
            log "取消安装，如果需要下载初始配置文件，请手动下载: $NGINX_CONF_URL"
            exit 0
        fi
    else
        log "检测到旧版本Nginx: $INSTALLED_VERSION，开始更新到版本: $LATEST_VERSION。"
    fi
else
    log "未检测到已安装的Nginx，开始安装版本: $LATEST_VERSION。"
fi

# ========== 检测系统发行版和版本 ==========
if command -v lsb_release >/dev/null 2>&1; then
    DISTRO=$(lsb_release -is)
    DISTRO_VERSION=$(lsb_release -rs | cut -d. -f1)
elif [ -f /etc/os-release ]; then
    DISTRO=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
    DISTRO_VERSION=$(grep -oP '(?<=^VERSION_ID=").+(?=")' /etc/os-release | cut -d. -f1)
else
    error_exit "无法检测系统发行版信息。"
fi

# 统一转小写
DISTRO=$(echo "$DISTRO" | tr '[:upper:]' '[:lower:]')
log "检测到系统: $DISTRO, 版本: $DISTRO_VERSION"

# ========== 安装依赖包 ==========
sudo apt-get update

# Debian 9/10/11 或 Ubuntu < 22 使用 libpcre3
# Debian 12/13 或 Ubuntu >= 22 使用 libpcre2-dev
USE_PCRE2=false
if [ "$DISTRO" == "debian" ]; then
    if [[ "$DISTRO_VERSION" -ge 12 ]]; then
        USE_PCRE2=true
    fi
elif [ "$DISTRO" == "ubuntu" ]; then
    if [[ "$DISTRO_VERSION" -ge 22 ]]; then
        USE_PCRE2=true
    fi
else
    log "⚠️ 未知的发行版: $DISTRO，将尝试使用 libpcre2-dev 依赖包..."
    USE_PCRE2=true
fi

COMMON_DEPS="build-essential zlib1g zlib1g-dev libssl-dev git libxml2-dev apache2-utils"

if [ "$USE_PCRE2" = true ]; then
    log "使用 libpcre2-dev + libxslt1-dev 依赖包..."
    sudo apt-get install -y $COMMON_DEPS libpcre2-dev libxslt1-dev
else
    log "使用 libpcre3 + libxslt-dev 依赖包..."
    sudo apt-get install -y $COMMON_DEPS libpcre3 libpcre3-dev libxslt-dev
fi

# ========== 下载并解压 Nginx 源码 ==========
WORK_DIR=$(mktemp -d)
log "工作目录: $WORK_DIR"
cd "$WORK_DIR" || error_exit "无法进入工作目录"

log "正在下载 nginx-${LATEST_VERSION}.tar.gz ..."
wget -q "http://nginx.org/download/nginx-${LATEST_VERSION}.tar.gz" || error_exit "下载 Nginx 源码失败"
tar -zxf "nginx-${LATEST_VERSION}.tar.gz" || error_exit "解压 Nginx 源码失败"
cd "nginx-${LATEST_VERSION}" || error_exit "进入 Nginx 源码目录失败"

log "正在克隆 nginx-dav-ext-module ..."
git clone https://github.com/arut/nginx-dav-ext-module.git || error_exit "克隆 nginx-dav-ext-module 失败"

# ========== 配置编译参数 ==========
log "正在配置编译参数..."
./configure \
  --with-cc-opt='-g -O2 -fstack-protector-strong -Wformat -Werror=format-security -fPIC -Wdate-time -D_FORTIFY_SOURCE=2' \
  --with-ld-opt='-Wl,-z,relro -Wl,-z,now -fPIC' \
  --prefix=/usr/share/nginx \
  --conf-path=/etc/nginx/nginx.conf \
  --http-log-path=/var/log/nginx/access.log \
  --error-log-path=/var/log/nginx/error.log \
  --lock-path=/var/lock/nginx.lock \
  --pid-path=/run/nginx.pid \
  --modules-path=/usr/lib/nginx/modules \
  --http-client-body-temp-path=/var/lib/nginx/body \
  --http-fastcgi-temp-path=/var/lib/nginx/fastcgi \
  --http-proxy-temp-path=/var/lib/nginx/proxy \
  --http-scgi-temp-path=/var/lib/nginx/scgi \
  --http-uwsgi-temp-path=/var/lib/nginx/uwsgi \
  --with-compat \
  --with-debug \
  --with-pcre-jit \
  --with-http_ssl_module \
  --with-http_stub_status_module \
  --with-http_realip_module \
  --with-http_auth_request_module \
  --with-http_v2_module \
  --with-http_dav_module \
  --with-http_slice_module \
  --with-threads \
  --with-http_addition_module \
  --with-http_gunzip_module \
  --with-http_gzip_static_module \
  --with-http_sub_module \
  --with-stream \
  --with-stream_ssl_module \
  --with-stream_ssl_preread_module \
  --add-module=nginx-dav-ext-module \
  || error_exit "Nginx configure 配置失败"

# ========== 创建所需的目录 ==========
sudo mkdir -p /var/lib/nginx/{body,fastcgi,proxy,scgi,uwsgi}
sudo mkdir -p /etc/nginx/{conf.d,sites-enabled,modules-enabled,stream}

# ========== 编译并安装 ==========
log "正在编译 Nginx（使用 $(nproc) 个线程）..."
make -j"$(nproc)" || error_exit "Nginx 编译失败"
log "正在安装 Nginx..."
sudo make install || error_exit "Nginx 安装失败"

# ========== 仅在首次安装时下载配置文件 ==========
if [ "$IS_FRESH_INSTALL" = true ]; then
    log "正在下载并替换默认的Nginx配置文件..."
    MAX_RETRIES=3
    RETRY_DELAY=3
    SUCCESS=0

    for ((i=1; i<=MAX_RETRIES; i++)); do
        if sudo curl -fsSL -o /etc/nginx/nginx.conf "$NGINX_CONF_URL"; then
            log "Nginx配置文件已成功替换。"
            SUCCESS=1
            break
        else
            log "第 $i 次下载失败，等待 $RETRY_DELAY 秒后重试..."
            sleep $RETRY_DELAY
        fi
    done

    if [ $SUCCESS -ne 1 ]; then
        log "⚠️ Nginx配置文件下载失败，请手动下载: $NGINX_CONF_URL"
    fi
else
    log "Nginx 更新安装，跳过配置文件下载（保留现有配置）。"
fi

# ========== 创建 systemd 服务文件 ==========
sudo bash -c 'cat > /etc/systemd/system/nginx.service << EOF
[Unit]
Description=A high performance web server and a reverse proxy server
After=network.target

[Service]
Type=forking
ExecStart=/usr/share/nginx/sbin/nginx
ExecReload=/usr/share/nginx/sbin/nginx -s reload
ExecStop=/usr/share/nginx/sbin/nginx -s stop
PIDFile=/run/nginx.pid
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF'

# ========== 添加 Nginx 到 PATH ==========
if ! grep -q 'export PATH=.*:/usr/share/nginx/sbin' ~/.bashrc; then
    echo 'export PATH="$PATH:/usr/share/nginx/sbin"' >> ~/.bashrc
    log "Nginx 路径已添加到环境变量。请运行 'source ~/.bashrc' 或重新登录以生效。"
else
    log "Nginx 路径已存在于环境变量中，无需重复添加。"
fi

# 确保当前脚本后续命令能找到 nginx
export PATH="$PATH:/usr/share/nginx/sbin"

# ========== 检查配置文件语法 ==========
log "正在检查 Nginx 配置文件语法..."
/usr/share/nginx/sbin/nginx -t || error_exit "Nginx 配置文件语法错误，请检查 /etc/nginx/nginx.conf"

# ========== 启动或重启 Nginx ==========
sudo systemctl daemon-reload
if systemctl is-active --quiet nginx; then
    log "Nginx 已经在运行，正在重启服务..."
    sudo systemctl restart nginx
else
    log "Nginx 尚未运行，正在启动服务..."
    sudo systemctl enable nginx
    sudo systemctl start nginx
fi

# ========== 清理工作目录 ==========
cd /
if [ -d "$WORK_DIR" ]; then
    sudo rm -rf "$WORK_DIR"
    log "已清理临时工作目录: $WORK_DIR"
fi

log "✅ Nginx 已成功安装/更新到版本: $LATEST_VERSION 并已启动！"
