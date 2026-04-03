#!/usr/bin/env bash

set -Eeuo pipefail

GH_USER="purepoorx"
GH_REPO="cf_port_test"
INSTALL_DIR="/app"
SERVICE_NAME="cfporttest"
SYSTEMD_SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
NGINX_TEMPLATE_PATH="/etc/nginx/nginx.conf.template"
NGINX_CONFIG_PATH="/etc/nginx/nginx.conf"
SSL_DIR="/etc/nginx/ssl"
ACME_WEBROOT="/var/www/acme"
RESOLV_CONF_PATH="/etc/resolv.conf"
DNS64_BACKUP_PATH="/etc/resolv.conf.cfporttest.bak"
DNS64_PRIMARY="2001:4860:4860::6464"
DNS64_SECONDARY="2001:4860:4860::64"
IPV4_ONLY_TEST_DOMAIN="ipv4only.arpa"

SUDO=""

log() {
    printf '\n==> %s\n' "$1"
}

die() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_root_or_sudo() {
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        SUDO=""
        return
    fi

    if command_exists sudo; then
        SUDO="sudo"
        return
    fi

    die "Run this script as root, or install sudo before continuing."
}

run_as_root() {
    if [ -n "$SUDO" ]; then
        "$SUDO" "$@"
        return
    fi

    "$@"
}

download_to() {
    local url="$1"
    local destination="$2"
    local mode="$3"
    local temp_file

    temp_file="$(mktemp)"
    curl -fsSL "$url" -o "$temp_file"
    run_as_root mkdir -p "$(dirname "$destination")"
    run_as_root install -m "$mode" "$temp_file" "$destination"
    rm -f "$temp_file"
}

download_release_binary() {
    local download_url="https://github.com/${GH_USER}/${GH_REPO}/releases/download/${RELEASE_TAG}/${SERVICE_NAME}"
    download_to "$download_url" "${INSTALL_DIR}/${SERVICE_NAME}" 0755
}

download_repo_file() {
    local ref="$1"
    local repo_path="$2"
    local destination="$3"
    local download_url="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${ref}/${repo_path}"

    download_to "$download_url" "$destination" 0644
}

resolve_release_tag() {
    if [ -n "${TAG:-}" ]; then
        printf '%s\n' "$TAG"
        return
    fi

    local latest_tag
    latest_tag="$(curl -fsSL "https://api.github.com/repos/${GH_USER}/${GH_REPO}/releases/latest" | grep -m1 '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')"
    [ -n "$latest_tag" ] || die "Unable to resolve the latest release tag."

    printf '%s\n' "$latest_tag"
}

normalize_domains() {
    local domain

    DOMAINS="$(printf '%s' "$DOMAINS" | tr -d '[:space:]')"
    [ -n "$DOMAINS" ] || die "The domain list cannot be empty."

    IFS=',' read -r -a domains_array <<< "$DOMAINS"
    ACME_DOMAINS=()

    for domain in "${domains_array[@]}"; do
        [ -n "$domain" ] || continue
        ACME_DOMAINS+=("-d" "$domain")
    done

    [ "${#ACME_DOMAINS[@]}" -gt 0 ] || die "At least one valid domain is required."
    CERT_MAIN_DOMAIN="${domains_array[0]}"
}

install_packages() {
    local packages=("$@")

    command_exists apt-get || die "This installer currently supports Ubuntu/Debian systems with apt-get."
    run_as_root apt-get update
    run_as_root apt-get install -y "${packages[@]}"
}

ensure_dependency() {
    local command_name="$1"
    shift

    if command_exists "$command_name"; then
        log "$command_name is already installed."
        return
    fi

    log "Installing ${command_name}..."
    install_packages "$@"
    command_exists "$command_name" || die "Failed to install ${command_name}."
}

ensure_ca_certificates() {
    if [ -f /etc/ssl/certs/ca-certificates.crt ] || [ -f /etc/ssl/cert.pem ] || [ -f /etc/pki/tls/certs/ca-bundle.crt ]; then
        return
    fi

    log "Installing CA certificates..."
    install_packages ca-certificates
}

ensure_base_dependencies() {
    ensure_dependency curl curl
    ensure_ca_certificates
    ensure_dependency awk gawk
    ensure_dependency grep grep
    ensure_dependency sed sed
    ensure_dependency mktemp coreutils
    ensure_dependency dirname coreutils
    ensure_dependency install coreutils
    ensure_dependency tee coreutils
    ensure_dependency tr coreutils
    command_exists getent || die "getent is required but is not available on this system."
    command_exists systemctl || die "systemd/systemctl is required by this installer."
}

enable_service() {
    local service_name="$1"

    run_as_root systemctl enable "$service_name"
    run_as_root systemctl restart "$service_name"
}

ensure_cron_service() {
    if command_exists crontab; then
        if run_as_root systemctl list-unit-files cron.service >/dev/null 2>&1; then
            log "Ensuring cron service is enabled..."
            enable_service cron.service
            return
        fi
    fi

    log "Installing cron service..."
    install_packages cron
    enable_service cron.service
    command_exists crontab || die "Failed to install cron."
}

has_direct_ipv4_access() {
    curl --ipv4 --silent --show-error --output /dev/null --connect-timeout 8 https://api.github.com >/dev/null 2>&1
}

has_dns64_resolution() {
    local synthesized

    synthesized="$(getent ahostsv6 "${IPV4_ONLY_TEST_DOMAIN}" 2>/dev/null | awk 'NR == 1 { print $1 }')"
    [ -n "$synthesized" ]
}

backup_resolver_config() {
    if [ -f "$DNS64_BACKUP_PATH" ]; then
        return
    fi

    if [ -e "$RESOLV_CONF_PATH" ]; then
        run_as_root cp -L "$RESOLV_CONF_PATH" "$DNS64_BACKUP_PATH"
    fi
}

configure_google_dns64() {
    local existing_directives=""

    if [ -e "$RESOLV_CONF_PATH" ]; then
        existing_directives="$(awk '/^(search|options|domain)[[:space:]]/ {print}' "$RESOLV_CONF_PATH" 2>/dev/null || true)"
    fi

    backup_resolver_config

    {
        printf '# Managed by cf_port_test install.sh for IPv6-only DNS64 access\n'
        printf 'nameserver %s\n' "$DNS64_PRIMARY"
        printf 'nameserver %s\n' "$DNS64_SECONDARY"
        if [ -n "$existing_directives" ]; then
            printf '%s\n' "$existing_directives"
        fi
    } | run_as_root tee "$RESOLV_CONF_PATH" >/dev/null
}

ensure_ipv4_only_website_access() {
    if has_direct_ipv4_access; then
        log "Native IPv4 website access is available."
        return
    fi

    if has_dns64_resolution; then
        log "DNS64 resolution for IPv4-only websites is already available."
        return
    fi

    log "IPv4-only website access is unavailable. Configuring Google Public DNS64..."
    configure_google_dns64

    if has_dns64_resolution; then
        log "DNS64 resolution for IPv4-only websites is now available."
        return
    fi

    die "IPv4-only website access is still unavailable. The server does not appear to have a reachable NAT64 gateway."
}

ensure_acme() {
    ACME_BIN="${HOME}/.acme.sh/acme.sh"

    if [ ! -x "$ACME_BIN" ]; then
        log "Installing acme.sh..."
        curl -fsSL https://get.acme.sh | sh -s email="$EMAIL"
    else
        log "acme.sh is already installed."
    fi

    if [ -f "${HOME}/.acme.sh/acme.sh.env" ]; then
        # shellcheck source=/dev/null
        . "${HOME}/.acme.sh/acme.sh.env"
    fi

    [ -x "$ACME_BIN" ] || die "acme.sh installation failed."
}

render_nginx_conf() {
    local domains="$1"
    local cert_path="$2"
    local key_path="$3"
    local template

    template="$(run_as_root cat "$NGINX_TEMPLATE_PATH")"
    template="${template//\{\{DOMAINS\}\}/$domains}"
    template="${template//\{\{CERT_PATH\}\}/$cert_path}"
    template="${template//\{\{KEY_PATH\}\}/$key_path}"

    printf '%s\n' "$template" | run_as_root tee "$NGINX_CONFIG_PATH" >/dev/null
}

validate_and_reload_nginx() {
    run_as_root nginx -t
    run_as_root systemctl restart nginx
    run_as_root systemctl enable nginx
}

setup_service() {
    log "Configuring systemd service..."
    run_as_root systemctl stop "${SERVICE_NAME}.service" || true
    download_repo_file "$RELEASE_REF" "cfport.service" "$SYSTEMD_SERVICE_PATH"
    run_as_root systemctl daemon-reload
}

create_self_signed_cert() {
    if [ -f "${SSL_DIR}/self-signed.crt" ] && [ -f "${SSL_DIR}/self-signed.key" ]; then
        return
    fi

    run_as_root mkdir -p "$SSL_DIR"
    run_as_root openssl req -x509 -nodes -days 365 \
        -newkey rsa:2048 \
        -keyout "${SSL_DIR}/self-signed.key" \
        -out "${SSL_DIR}/self-signed.crt" \
        -subj "/CN=localhost"
}

prompt_dns_credentials() {
    local env_name
    local env_value
    local count=0

    echo "Enter the environment variables required by the selected acme.sh DNS provider."
    echo "Leave the variable name blank when you are done."

    while true; do
        read -r -p "Variable name: " env_name
        if [ -z "$env_name" ]; then
            break
        fi

        if ! [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "Invalid variable name: ${env_name}"
            continue
        fi

        read -r -s -p "Value for ${env_name}: " env_value
        echo
        export "${env_name}=${env_value}"
        count=$((count + 1))
    done

    [ "$count" -gt 0 ] || die "At least one DNS credential variable is required."
}

issue_certificate() {
    local cert_mode
    local dns_api

    log "Obtaining SSL certificate..."
    echo "Choose certificate mode:"
    echo "1. Webroot mode"
    echo "2. DNS mode"
    read -r -p "Selection (1-2): " cert_mode

    if [ "$cert_mode" = "1" ]; then
        log "Using webroot mode..."
        run_as_root mkdir -p "$ACME_WEBROOT"
        download_repo_file "$RELEASE_REF" "nginx.conf.template" "$NGINX_TEMPLATE_PATH"
        create_self_signed_cert
        render_nginx_conf "$CERT_MAIN_DOMAIN" "${SSL_DIR}/self-signed.crt" "${SSL_DIR}/self-signed.key"
        validate_and_reload_nginx
        "$ACME_BIN" --issue --webroot "$ACME_WEBROOT" "${ACME_DOMAINS[@]}" --force --server letsencrypt
        return
    fi

    if [ "$cert_mode" = "2" ]; then
        log "Using DNS mode..."
        read -r -p "DNS API name (example: dns_cf): " dns_api
        [ -n "$dns_api" ] || die "The DNS API name cannot be empty."
        echo "Provider-specific variables are documented at:"
        echo "https://github.com/acmesh-official/acme.sh/wiki/dnsapi"
        prompt_dns_credentials
        "$ACME_BIN" --issue --dns "$dns_api" "${ACME_DOMAINS[@]}" --force --server letsencrypt
        return
    fi

    die "Invalid certificate mode selection."
}

install_certificate_and_nginx() {
    local cert_path="${SSL_DIR}/${CERT_MAIN_DOMAIN}.crt"
    local key_path="${SSL_DIR}/${CERT_MAIN_DOMAIN}.key"
    local reload_cmd="systemctl restart nginx"

    if [ -n "$SUDO" ]; then
        reload_cmd="sudo systemctl restart nginx"
    fi

    log "Installing certificate and configuring nginx..."
    run_as_root mkdir -p "$SSL_DIR"
    "$ACME_BIN" --install-cert -d "$CERT_MAIN_DOMAIN" \
        --key-file "$key_path" \
        --fullchain-file "$cert_path" \
        --reloadcmd "$reload_cmd"

    download_repo_file "$RELEASE_REF" "nginx.conf.template" "$NGINX_TEMPLATE_PATH"
    render_nginx_conf "$DOMAINS" "$cert_path" "$key_path"
    validate_and_reload_nginx
}

deploy() {
    log "Starting deployment..."

    require_root_or_sudo
    ensure_base_dependencies
    ensure_ipv4_only_website_access

    read -r -p "Domains (comma separated): " DOMAINS
    normalize_domains

    read -r -p "Email address for acme.sh registration: " EMAIL
    [ -n "$EMAIL" ] || die "The email address cannot be empty."

    read -r -p "Release tag to install (leave blank for latest): " TAG

    RELEASE_TAG="$(resolve_release_tag)"
    RELEASE_REF="$RELEASE_TAG"
    log "Using release tag: ${RELEASE_TAG}"

    ensure_dependency nginx nginx
    ensure_dependency socat socat
    ensure_dependency openssl openssl
    ensure_cron_service
    ensure_acme

    log "Downloading release binary..."
    download_release_binary
    setup_service
    issue_certificate
    install_certificate_and_nginx

    log "Starting services..."
    run_as_root systemctl enable "${SERVICE_NAME}.service"
    run_as_root systemctl restart "${SERVICE_NAME}.service"

    log "Deployment completed successfully."
}

uninstall() {
    local purge_choice

    log "Starting uninstall..."
    require_root_or_sudo
    ensure_base_dependencies
    read -r -p "Domains used during installation (comma separated): " DOMAINS
    normalize_domains

    read -r -p "Purge nginx and acme.sh as well? (y/N): " purge_choice

    run_as_root systemctl stop "${SERVICE_NAME}.service" || true
    run_as_root systemctl disable "${SERVICE_NAME}.service" || true
    run_as_root systemctl stop nginx || true

    if [ -f "$SYSTEMD_SERVICE_PATH" ]; then
        run_as_root rm -f "$SYSTEMD_SERVICE_PATH"
        run_as_root systemctl daemon-reload
    fi

    run_as_root rm -f "${INSTALL_DIR}/${SERVICE_NAME}"
    run_as_root rmdir "$INSTALL_DIR" 2>/dev/null || true
    run_as_root rm -f "$NGINX_CONFIG_PATH" "$NGINX_TEMPLATE_PATH"

    if [ -x "${HOME}/.acme.sh/acme.sh" ]; then
        "${HOME}/.acme.sh/acme.sh" --revoke "${ACME_DOMAINS[@]}" --server letsencrypt || true
        "${HOME}/.acme.sh/acme.sh" --remove "${ACME_DOMAINS[@]}" || true
    fi

    run_as_root rm -f "${SSL_DIR}/${CERT_MAIN_DOMAIN}.crt" "${SSL_DIR}/${CERT_MAIN_DOMAIN}.key"

    if [[ "$purge_choice" =~ ^[Yy]$ ]]; then
        if command_exists nginx; then
            run_as_root apt-get purge -y nginx nginx-common
        fi

        if [ -x "${HOME}/.acme.sh/acme.sh" ]; then
            "${HOME}/.acme.sh/acme.sh" --uninstall || true
            run_as_root rm -rf "${HOME}/.acme.sh"
        fi
    fi

    log "Uninstall completed."
}

main() {
    log "Welcome to the cf_port_test management script."
    echo "1. Install or update"
    echo "2. Uninstall"
    read -r -p "Selection (1-2): " action_choice

    case "$action_choice" in
        1) deploy ;;
        2) uninstall ;;
        *) die "Invalid selection." ;;
    esac
}

main "$@"
