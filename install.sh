#!/bin/bash

# install.sh: An interactive script to deploy or uninstall the cfporttest application.
# This script is intended to be run on the target server.

set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
GH_USER="purepoorx"
GH_REPO="cf_port_test"
INSTALL_DIR="/app"
SERVICE_NAME="cfporttest"

# --- Helper Functions ---
function log() {
    echo "--- $1 ---"
}

function command_exists() {
    command -v "$1" &> /dev/null
}

# --- Deploy Function ---
function deploy() {
    log "Starting deployment..."

    # --- 1. Gather Information Interactively ---
    read -p "请输入您的域名 (多个域名请用逗号分隔, 例如: domain1.com,www.domain1.com): " DOMAINS
    if [ -z "$DOMAINS" ]; then echo "错误：域名不能为空。"; exit 1; fi

    read -p "请输入您的邮箱 (用于 Let's Encrypt 证书提醒): " EMAIL
    if [ -z "$EMAIL" ]; then echo "错误：邮箱不能为空。"; exit 1; fi
    
    read -p "请输入要安装的版本标签 (例如: v1.0.0, 直接回车则安装最新版): " TAG

    # --- 2. Install Dependencies ---
    log "Checking and installing dependencies..."
    if ! command_exists "nginx"; then
        log "未找到 Nginx，正在安装..."
        if command_exists apt-get; then sudo apt-get update && sudo apt-get install -y nginx;
        elif command_exists yum; then sudo yum install -y nginx;
        elif command_exists dnf; then sudo dnf install -y nginx;
        else log "错误：不支持的包管理器。请手动安装 Nginx。"; exit 1; fi
    else
        log "Nginx 已安装。"
    fi

    if ! command_exists "certbot"; then
        log "未找到 Certbot，正在通过 snap 安装..."
        if command_exists apt-get; then sudo apt-get update && sudo apt-get install -y snapd;
        elif command_exists yum; then sudo yum install -y snapd;
        elif command_exists dnf; then sudo dnf install -y snapd; fi
        sudo snap install --classic certbot
        sudo ln -s /snap/bin/certbot /usr/bin/certbot
    else
        log "Certbot 已安装。"
    fi

    # --- 3. Download Application ---
    log "从 GitHub 下载应用..."
    if [ -z "$TAG" ]; then
        TAG=$(curl -s "https://api.github.com/repos/${GH_USER}/${GH_REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [ -z "$TAG" ]; then log "错误：无法获取最新的发布版本。"; exit 1; fi
    fi
    log "正在使用版本: $TAG"
    DOWNLOAD_URL="https://github.com/${GH_USER}/${GH_REPO}/releases/download/${TAG}/${SERVICE_NAME}"
    sudo mkdir -p "$INSTALL_DIR"
    sudo curl -L -o "${INSTALL_DIR}/${SERVICE_NAME}" "$DOWNLOAD_URL"
    sudo chmod +x "${INSTALL_DIR}/${SERVICE_NAME}"

    # --- 4. Setup Systemd Service ---
    log "设置 systemd 服务..."
    sudo systemctl stop "${SERVICE_NAME}.service" || true
    sudo curl -L -o "/etc/systemd/system/${SERVICE_NAME}.service" "https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/main/cfport.service"
    sudo systemctl daemon-reload

    # --- 5. Obtain SSL Certificate ---
    log "申请 SSL 证书..."
    sudo systemctl stop nginx
    CERTBOT_DOMAINS=$(echo "$DOMAINS" | sed 's/,/ -d /g')
    CERT_MAIN_DOMAIN=$(echo "$DOMAINS" | cut -d, -f1)
    sudo certbot certonly --standalone --non-interactive --agree-tos -m "$EMAIL" -d $CERTBOT_DOMAINS

    # --- 6. Configure Nginx ---
    log "配置 Nginx..."
    sudo curl -L -o "/etc/nginx/nginx.conf.template" "https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/main/nginx.conf.template"
    TEMP_CONF=$(cat /etc/nginx/nginx.conf.template)
    TEMP_CONF=${TEMP_CONF//\{\{DOMAINS\}\}/$DOMAINS}
    TEMP_CONF=${TEMP_CONF//\{\{CERT_MAIN_DOMAIN\}\}/$CERT_MAIN_DOMAIN}
    echo "$TEMP_CONF" | sudo tee /etc/nginx/nginx.conf > /dev/null

    # --- 7. Start Services ---
    log "启动服务..."
    sudo systemctl start "${SERVICE_NAME}.service"
    sudo systemctl enable "${SERVICE_NAME}.service"
    sudo systemctl start nginx
    sudo systemctl enable nginx

    log "部署成功！"
}

# --- Uninstall Function ---
function uninstall() {
    log "开始卸载..."

    # --- 1. Gather Information ---
    read -p "请输入您要卸载的域名 (必须与安装时一致): " DOMAINS
    if [ -z "$DOMAINS" ]; then echo "错误：域名不能为空。"; exit 1; fi
    
    read -p "是否要彻底清除 Nginx 和 Certbot? (y/N): " PURGE_CHOICE
    PURGE=false
    if [[ "$PURGE_CHOICE" == "y" || "$PURGE_CHOICE" == "Y" ]]; then
        PURGE=true
    fi

    # --- 2. Stop and Disable Services ---
    log "停止并禁用服务..."
    sudo systemctl stop "${SERVICE_NAME}.service" || echo "服务 ${SERVICE_NAME} 未运行。"
    sudo systemctl disable "${SERVICE_NAME}.service" || echo "服务 ${SERVICE_NAME} 未启用。"
    sudo systemctl stop nginx || echo "Nginx 未运行。"
    sudo systemctl disable nginx || echo "Nginx 未启用。"

    # --- 3. Remove Application Files ---
    log "移除应用文件..."
    if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
        sudo rm "/etc/systemd/system/${SERVICE_NAME}.service"
        log "已移除 systemd 服务文件。"
        sudo systemctl daemon-reload
    fi
    if [ -d "$INSTALL_DIR" ]; then sudo rm -rf "$INSTALL_DIR"; log "已移除应用目录。"; fi

    # --- 4. Remove Nginx Configuration ---
    if [ -f "/etc/nginx/nginx.conf" ]; then sudo rm /etc/nginx/nginx.conf; log "已移除 nginx.conf。"; fi

    # --- 5. Delete SSL Certificate ---
    if command_exists "certbot"; then
        log "删除 SSL 证书..."
        CERT_MAIN_DOMAIN=$(echo "$DOMAINS" | cut -d, -f1)
        if sudo certbot certificates | grep -q "Certificate Name: ${CERT_MAIN_DOMAIN}"; then
            sudo certbot delete --cert-name "$CERT_MAIN_DOMAIN" --non-interactive
        else
            log "未找到域名 ${CERT_MAIN_DOMAIN} 的证书。"
        fi
    fi

    # --- 6. Purge Dependencies (Optional) ---
    if [ "$PURGE" = true ]; then
        log "彻底清除依赖..."
        if command_exists "nginx"; then
            if command_exists apt-get; then sudo apt-get purge -y nginx nginx-common;
            elif command_exists yum; then sudo yum remove -y nginx;
            elif command_exists dnf; then sudo dnf remove -y nginx; fi
        fi
        if command_exists "certbot"; then sudo snap remove certbot; fi
    fi

    log "卸载成功！"
}

# --- Main Script Logic ---
log "欢迎使用 cf_port_test 管理脚本"
echo "1. 安装或更新应用"
echo "2. 卸载应用"
read -p "请选择您要执行的操作 (1-2): " ACTION_CHOICE

case "$ACTION_CHOICE" in
    1)
        deploy
        ;;
    2)
        uninstall
        ;;
    *)
        echo "无效的选择。"
        exit 1
        ;;
esac