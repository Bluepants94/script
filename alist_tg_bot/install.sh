#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/Bluepants94/script.git"
REPO_SUBDIR="alist_tg_bot"
INSTALL_DIR="/opt/alist_tg_bot"
SERVICE_NAME="alist_tg_bot"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
VENV_DIR="${INSTALL_DIR}/.venv"
TMP_DIR="/tmp/alist_tg_bot_install"
PYTHON_BIN=""
PYTHON_VERSION="未安装"
LINUX_VERSION="未知系统"
PKG_MANAGER="unknown"

red() { printf '\\033[31m%s\\033[0m\n' "$*"; }
green() { printf '\\033[32m%s\\033[0m\n' "$*"; }
yellow() { printf '\\033[33m%s\\033[0m\n' "$*"; }
blue() { printf '\\033[34m%s\\033[0m\n' "$*"; }

pause_menu() {
    echo
    read -r -p "按回车键返回上层菜单..." _
}

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        red "请使用 root 权限运行：sudo bash install.sh"
        return 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

detect_linux() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        LINUX_VERSION="${PRETTY_NAME:-${NAME:-未知系统}}"
    else
        LINUX_VERSION="$(uname -srm 2>/dev/null || echo '未知系统')"
    fi

    if command_exists apt-get; then
        PKG_MANAGER="apt"
    elif command_exists dnf; then
        PKG_MANAGER="dnf"
    elif command_exists yum; then
        PKG_MANAGER="yum"
    elif command_exists pacman; then
        PKG_MANAGER="pacman"
    elif command_exists zypper; then
        PKG_MANAGER="zypper"
    else
        PKG_MANAGER="unknown"
    fi
}

detect_python() {
    PYTHON_BIN=""
    PYTHON_VERSION="未安装"

    if command_exists python3; then
        PYTHON_BIN="python3"
    elif command_exists python; then
        PYTHON_BIN="python"
    fi

    if [[ -n "${PYTHON_BIN}" ]]; then
        PYTHON_VERSION="$(${PYTHON_BIN} --version 2>&1 | sed 's/^Python //')"
    fi
}

refresh_info() {
    detect_linux
    detect_python
}

install_packages() {
    local packages=("$@")
    case "${PKG_MANAGER}" in
        apt)
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
            ;;
        dnf)
            dnf install -y "${packages[@]}"
            ;;
        yum)
            yum install -y "${packages[@]}"
            ;;
        pacman)
            pacman -Sy --noconfirm "${packages[@]}"
            ;;
        zypper)
            zypper --non-interactive install "${packages[@]}"
            ;;
        *)
            red "未识别的包管理器，请手动安装：${packages[*]}"
            return 1
            ;;
    esac
}

venv_package_name() {
    case "${PKG_MANAGER}" in
        apt|dnf|yum) echo "python3-venv" ;;
        pacman) echo "python" ;;
        zypper) echo "python3" ;;
        *) echo "python3-venv" ;;
    esac
}

ensure_dependencies() {
    local packages=()

    if [[ "${PYTHON_VERSION}" == "未安装" ]]; then
        red "当前系统未安装 Python，请先安装 Python。"
        return 1
    fi

    command_exists git || packages+=(git)
    command_exists curl || packages+=(curl)
    command_exists ffmpeg || packages+=(ffmpeg)
    command_exists rsync || packages+=(rsync)

    if ! "${PYTHON_BIN}" -m venv --help >/dev/null 2>&1; then
        packages+=("$(venv_package_name)")
    fi

    if ((${#packages[@]} > 0)); then
        yellow "正在安装系统依赖：${packages[*]}"
        install_packages "${packages[@]}"
    else
        green "系统依赖已满足。"
    fi
}

copy_from_current_dir() {
    local source_dir
    source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    mkdir -p "${INSTALL_DIR}"
    rsync -a --delete --exclude '.git' --exclude '.env' --exclude '.venv' --exclude '__pycache__' "${source_dir}/" "${INSTALL_DIR}/"
}

download_from_github() {
    rm -rf "${TMP_DIR}"
    git clone --depth 1 "${REPO_URL}" "${TMP_DIR}"
    mkdir -p "${INSTALL_DIR}"
    rsync -a --delete --exclude '.git' --exclude '.env' --exclude '.venv' --exclude '__pycache__' "${TMP_DIR}/${REPO_SUBDIR}/" "${INSTALL_DIR}/"
    rm -rf "${TMP_DIR}"
}

install_python_deps() {
    "${PYTHON_BIN}" -m venv "${VENV_DIR}"
    "${VENV_DIR}/bin/python" -m pip install --upgrade pip
    "${VENV_DIR}/bin/pip" install -r "${INSTALL_DIR}/requirements.txt"
}

prompt_value() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="${3:-}"
    local value

    if [[ -n "${default_value}" ]]; then
        read -r -p "${prompt_text} [${default_value}]: " value
        value="${value:-${default_value}}"
    else
        while true; do
            read -r -p "${prompt_text}: " value
            if [[ -n "${value}" ]]; then
                break
            fi
            red "该项不能为空。"
        done
    fi

    printf -v "${var_name}" '%s' "${value}"
}

write_env_file() {
    local env_file="${INSTALL_DIR}/.env"

    prompt_value API_ID "请输入 Telegram API_ID"
    prompt_value API_HASH "请输入 Telegram API_HASH"
    prompt_value BOT_TOKEN "请输入 Telegram BOT_TOKEN"
    prompt_value SESSION_NAME "请输入 Pyrogram 会话名称" "my_bot"
    prompt_value USER_WHITELIST "请输入用户白名单 ID，多个用英文逗号分隔"
    prompt_value GROUP_WHITELIST "请输入群组白名单 ID，多个用英文逗号分隔"
    prompt_value FIXED_DOWNLOAD_DIR "请输入本地下载目录" "/storage/alistdata/telegram"
    prompt_value UPLOAD_TO_ALIST "是否上传到 Alist？true/false" "true"
    prompt_value BASE_URL "请输入 Alist 地址，例如 https://pan.example.com"
    prompt_value ALIST_USERNAME "请输入 Alist 用户名"
    prompt_value ALIST_PASSWORD "请输入 Alist 密码"
    prompt_value SRC_DIR "请输入 Alist 源路径（映射本地下载目录）" "/local/telegram"
    prompt_value DST_DIR "请输入 Alist 目标网盘路径" "/115/TG_Downloader"
    prompt_value GENERATE_GRID "是否生成九宫格预览图？true/false" "true"
    prompt_value MAX_CONCURRENT_DOWNLOADS "请输入最大并发下载数" "2"

    cat > "${env_file}" <<EOF
# Telegram API 配置
API_ID=${API_ID}
API_HASH=${API_HASH}
BOT_TOKEN=${BOT_TOKEN}
SESSION_NAME=${SESSION_NAME}

# 访问白名单
USER_WHITELIST=${USER_WHITELIST}
GROUP_WHITELIST=${GROUP_WHITELIST}

# 本地下载目录
FIXED_DOWNLOAD_DIR=${FIXED_DOWNLOAD_DIR}

# Alist 上传配置
UPLOAD_TO_ALIST=${UPLOAD_TO_ALIST}
BASE_URL=${BASE_URL}
ALIST_USERNAME=${ALIST_USERNAME}
ALIST_PASSWORD=${ALIST_PASSWORD}
SRC_DIR=${SRC_DIR}
DST_DIR=${DST_DIR}

# 视频处理配置
GENERATE_GRID=${GENERATE_GRID}
MAX_CONCURRENT_DOWNLOADS=${MAX_CONCURRENT_DOWNLOADS}
EOF

    chmod 600 "${env_file}"
    mkdir -p "${FIXED_DOWNLOAD_DIR}"
}

configure_env() {
    mkdir -p "${INSTALL_DIR}"
    if [[ -f "${INSTALL_DIR}/.env" ]]; then
        yellow "已存在配置文件：${INSTALL_DIR}/.env"
        read -r -p "是否覆盖？[y/N]: " overwrite
        if [[ ! "${overwrite}" =~ ^[Yy]$ ]]; then
            green "已保留现有 .env。"
            return 0
        fi
    fi
    write_env_file
    green "配置文件已写入：${INSTALL_DIR}/.env"
}

write_service() {
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Alist Telegram Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=-${INSTALL_DIR}/.env
ExecStart=${VENV_DIR}/bin/python ${INSTALL_DIR}/alist_tg_bot.py
Restart=always
RestartSec=5
TimeoutStopSec=30
KillSignal=SIGINT
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    green "systemd 服务已写入：${SERVICE_FILE}"
}

install_or_update() {
    need_root || return 1
    refresh_info
    if [[ "${PYTHON_VERSION}" == "未安装" ]]; then
        red "当前系统未安装 Python，请先安装 Python。"
        return 1
    fi
    ensure_dependencies || return 1

    echo
    echo "请选择安装来源："
    echo "1）从 GitHub 下载（${REPO_URL}，子目录：${REPO_SUBDIR}）"
    echo "2）使用当前脚本所在目录"
    echo "0）返回上层"
    read -r -p "请选择 [默认 1]: " source_choice
    source_choice="${source_choice:-1}"
    case "${source_choice}" in
        1) download_from_github ;;
        2) copy_from_current_dir ;;
        0) return 0 ;;
        *) red "无效选项。"; return 1 ;;
    esac

    install_python_deps
    configure_env
    write_service

    read -r -p "是否立即启动服务？[Y/n]: " start_now
    if [[ ! "${start_now}" =~ ^[Nn]$ ]]; then
        systemctl enable --now "${SERVICE_NAME}"
        systemctl status "${SERVICE_NAME}" --no-pager || true
    fi
    green "安装 / 更新完成。"
}

start_service() { need_root || return 1; systemctl start "${SERVICE_NAME}"; systemctl status "${SERVICE_NAME}" --no-pager || true; }
stop_service() { need_root || return 1; systemctl stop "${SERVICE_NAME}"; green "服务已停止。"; }
restart_service() { need_root || return 1; systemctl restart "${SERVICE_NAME}"; systemctl status "${SERVICE_NAME}" --no-pager || true; }
show_status() { systemctl status "${SERVICE_NAME}" --no-pager || true; }
show_logs() { journalctl -u "${SERVICE_NAME}" -f; }
enable_service() { need_root || return 1; systemctl enable "${SERVICE_NAME}"; green "已设置开机自启。"; }
disable_service() { need_root || return 1; systemctl disable "${SERVICE_NAME}"; green "已取消开机自启。"; }

uninstall_all() {
    need_root || return 1
    yellow "即将卸载 alist_tg_bot："
    echo "1）停止并禁用 systemd 服务"
    echo "2）删除 systemd 服务文件：${SERVICE_FILE}"
    echo "3）删除项目目录：${INSTALL_DIR}"
    echo "4）删除临时目录：${TMP_DIR}"
    echo "不会卸载 Python、pip、ffmpeg、git、rsync、curl 等系统依赖。"
    read -r -p "确认卸载？[y/N]: " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || return 0

    systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
    rm -f "${SERVICE_FILE}"
    rm -rf "${INSTALL_DIR}"
    rm -rf "${TMP_DIR}"
    systemctl daemon-reload
    systemctl reset-failed "${SERVICE_NAME}" >/dev/null 2>&1 || true
    green "卸载完成，已移除项目文件和 systemd 相关内容。"
}

show_menu() {
    refresh_info
    clear || true
    blue "========================================"
    blue " Alist Telegram Bot 交互安装脚本"
    blue "========================================"
    echo "Linux 版本 ：${LINUX_VERSION}"
    echo "Python 版本：${PYTHON_VERSION}"
    echo
    echo "1）安装 / 更新"
    echo "2）配置 .env"
    echo "3）启动服务"
    echo "4）停止服务"
    echo "5）重启服务"
    echo "6）查看服务状态"
    echo "7）查看服务日志"
    echo "8）设置开机自启"
    echo "9）取消开机自启"
    echo "10）卸载"
    echo "0）退出"
    echo
}

main() {
    while true; do
        show_menu
        read -r -p "请选择功能：" choice
        case "${choice}" in
            1) install_or_update; pause_menu ;;
            2) need_root && configure_env; pause_menu ;;
            3) start_service; pause_menu ;;
            4) stop_service; pause_menu ;;
            5) restart_service; pause_menu ;;
            6) show_status; pause_menu ;;
            7) show_logs ;;
            8) enable_service; pause_menu ;;
            9) disable_service; pause_menu ;;
            10) uninstall_all; pause_menu ;;
            0) exit 0 ;;
            *) red "无效选项。"; pause_menu ;;
        esac
    done
}

main
