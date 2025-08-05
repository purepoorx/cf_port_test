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

    read -p "请输入您的邮箱 (用于 acme.sh 注册): " EMAIL
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
    
    if ! command_exists "socat"; then
        log "未找到 socat (acme.sh 依赖)，正在安装..."
        if command_exists apt-get; then sudo apt-get update && sudo apt-get install -y socat;
        elif command_exists yum; then sudo yum install -y socat;
        elif command_exists dnf; then sudo dnf install -y socat;
        else log "错误：不支持的包管理器。请手动安装 socat。"; exit 1; fi
    else
        log "socat 已安装。"
    fi

    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        log "正在安装 acme.sh..."
        curl https://get.acme.sh | sh -s email="$EMAIL"
    else
        log "acme.sh 已安装。"
    fi
    # shellcheck source=/dev/null
    source "$HOME/.acme.sh/acme.sh.env"

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
    log "获取 SSL 证书..."
    echo "请选择证书申请模式:"
    echo "1. Webroot 模式 (推荐, 需要 80 端口可公网访问)"
    echo "2. DNS 模式 (支持通配符, 需要 DNS 提供商 API Key)"
    read -p "请输入您的选择 (1-2): " CERT_MODE

    CERT_MAIN_DOMAIN=$(echo "$DOMAINS" | cut -d, -f1)
    ACME_DOMAINS_PARAMS="-d $(echo "$DOMAINS" | sed 's/,/ -d /g')"

    if [ "$CERT_MODE" == "1" ]; then
        # --- Webroot Mode ---
        log "使用 Webroot 模式..."
        sudo mkdir -p /var/www/acme
        # Pre-configure Nginx for ACME challenge
        sudo curl -L -o "/etc/nginx/nginx.conf.template" "https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/main/nginx.conf.template"
        if [ ! -f /etc/nginx/ssl/self-signed.crt ]; then
            sudo mkdir -p /etc/nginx/ssl
            sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/nginx/ssl/self-signed.key -out /etc/nginx/ssl/self-signed.crt -subj "/CN=localhost"
        fi
        TEMP_CONF=$(cat /etc/nginx/nginx.conf.template); TEMP_CONF=${TEMP_CONF//\{\{DOMAINS\}\}/$CERT_MAIN_DOMAIN}; TEMP_CONF=${TEMP_CONF//\{\{CERT_PATH\}\}/\/etc\/nginx\/ssl\/self-signed.crt}; TEMP_CONF=${TEMP_CONF//\{\{KEY_PATH\}\}/\/etc\/nginx\/ssl\/self-signed.key}; echo "$TEMP_CONF" | sudo tee /etc/nginx/nginx.conf > /dev/null
        sudo systemctl restart nginx
        
        # shellcheck disable=SC2086
        "$HOME/.acme.sh/acme.sh" --issue --webroot /var/www/acme $ACME_DOMAINS_PARAMS --force --server letsencrypt

    elif [ "$CERT_MODE" == "2" ]; then
        # --- DNS Mode ---
        log "使用 DNS 模式..."
        read -p "请输入您的 DNS 提供商 API (例如: dns_cf for Cloudflare): " DNS_API
        if [ -z "$DNS_API" ]; then echo "错误: DNS API 不能为空。"; exit 1; fi
        
        echo "请输入 DNS API 所需的环境变量 (例如: CF_Key=\"your_key\" CF_Email=\"your_email\")"
        echo "请参考 acme.sh 文档了解您的提供商需要哪些变量: https://github.com/acmesh-official/acme.sh/wiki/dnsapi"
        read -p "请输入环境变量: " DNS_ENV_VARS

        # shellcheck disable=SC2086
        eval "export $DNS_ENV_VARS" "$HOME/.acme.sh/acme.sh" --issue --dns "$DNS_API" $ACME_DOMAINS_PARAMS --force --server letsencrypt
    else
        log "无效的选择。"; exit 1
    fi

    # --- 6. Install Certificate and Configure Nginx ---
    log "安装证书并配置 Nginx..."
    CERT_PATH="/etc/nginx/ssl/${CERT_MAIN_DOMAIN}.crt"
    KEY_PATH="/etc/nginx/ssl/${CERT_MAIN_DOMAIN}.key"
    sudo mkdir -p /etc/nginx/ssl
    # shellcheck disable=SC2086
    "$HOME/.acme.sh/acme.sh" --install-cert -d "$CERT_MAIN_DOMAIN" \
        --key-file       "$KEY_PATH" \
        --fullchain-file "$CERT_PATH" \
        --reloadcmd      "sudo systemctl restart nginx"

    sudo curl -L -o "/etc/nginx/nginx.conf.template" "https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/main/nginx.conf.template"
    FINAL_CONF=$(cat /etc/nginx/nginx.conf.template)
    FINAL_CONF=${FINAL_CONF//\{\{DOMAINS\}\}/$DOMAINS}
    FINAL_CONF=${FINAL_CONF//\{\{CERT_PATH\}\}/$CERT_PATH}
    FINAL_CONF=${FINAL_CONF//\{\{KEY_PATH\}\}/$KEY_PATH}
    echo "$FINAL_CONF" | sudo tee /etc/nginx/nginx.conf > /dev/null
    
    # --- 7. Start Services ---
    log "启动服务..."
    sudo systemctl start "${SERVICE_NAME}.service"
    sudo systemctl enable "${SERVICE_NAME}.service"
    sudo systemctl restart nginx
    sudo systemctl enable nginx

    log "部署成功！"
}

# --- Uninstall Function ---
function uninstall() {
    log "开始卸载..."

    read -p "请输入您要卸载的域名 (必须与安装时一致): " DOMAINS
    if [ -z "$DOMAINS" ]; then echo "错误：域名不能为空。"; exit 1; fi
    
    read -p "是否要彻底清除 Nginx 和 acme.sh? (y/N): " PURGE_CHOICE
    PURGE=false
    if [[ "$PURGE_CHOICE" == "y" || "$PURGE_CHOICE" == "Y" ]]; then
        PURGE=true
    fi

    sudo systemctl stop "${SERVICE_NAME}.service" || true
    sudo systemctl disable "${SERVICE_NAME}.service" || true
    sudo systemctl stop nginx || true

    if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
        sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        sudo systemctl daemon-reload
    fi
    sudo rm -rf "$INSTALL_DIR"
    sudo rm -f /etc/nginx/nginx.conf

    if [ -f "$HOME/.acme.sh/acme.sh" ]; then
        CERT_MAIN_DOMAIN=$(echo "$DOMAINS" | cut -d, -f1)
        ACME_DOMAINS_PARAMS="-d $(echo "$DOMAINS" | sed 's/,/ -d /g')"
        # shellcheck disable=SC2086
        "$HOME/.acme.sh/acme.sh" --revoke $ACME_DOMAINS_PARAMS --server letsencrypt || true
        # shellcheck disable=SC2086
        "$HOME/.acme.sh/acme.sh" --remove $ACME_DOMAINS_PARAMS || true
        sudo rm -rf "/etc/nginx/ssl/${CERT_MAIN_DOMAIN}.crt" "/etc/nginx/ssl/${CERT_MAIN_DOMAIN}.key"
    fi

    if [ "$PURGE" = true ]; then
        if command_exists "nginx"; then
            if command_exists apt-get; then sudo apt-get purge -y nginx nginx-common;
            elif command_exists yum; then sudo yum remove -y nginx;
            elif command_exists dnf; then sudo dnf remove -y nginx; fi
        fi
        if [ -d "$HOME/.acme.sh" ]; then
            "$HOME/.acme.sh/acme.sh" --uninstall
            sudo rm -rf "$HOME/.acme.sh"
        fi
    fi

    log "卸载成功！"
}

# --- Main Script Logic ---
log "欢迎使用 cf_port_test 管理脚本"
echo "1. 安装或更新应用"
echo "2. 卸载应用"
read -p "请选择您要执行的操作 (1-2): " ACTION_CHOICE

case "$ACTION_CHOICE" in
    1) deploy ;;
    2) uninstall ;;
    *) echo "无效的选择。"; exit 1 ;;
esac