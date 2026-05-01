#!/usr/bin/env bash

set -Eeuo pipefail

GH_USER="purepoorx"
GH_REPO="cf_port_test"
INSTALL_DIR="/app"
SERVICE_NAME="cfporttest"
SYSTEMD_SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
NGINX_MAIN_CONFIG_PATH="/etc/nginx/nginx.conf"
NGINX_CONFIG_DIR="/etc/nginx/conf.d"
NGINX_TEMPLATE_PATH="/etc/nginx/cfporttest.conf.template"
NGINX_CONFIG_PATH="${NGINX_CONFIG_DIR}/cfporttest.conf"
SSL_DIR="/etc/nginx/ssl"
ACME_WEBROOT="/var/www/acme"
RESOLV_CONF_PATH="/etc/resolv.conf"
DNS64_BACKUP_PATH="/etc/resolv.conf.cfporttest.bak"
NAT64_NET_PRIMARY="2a01:4f8:c2c:123f::1"
NAT64_NET_SECONDARY="2a01:4f9:c010:3f02::1"
NAT64_NET_TERTIARY="2a00:1098:2c::1"
IPV4_ONLY_TEST_DOMAIN="ipv4only.arpa"
GITHUB_API_RELEASES_URL="https://api.github.com/repos/${GH_USER}/${GH_REPO}/releases/latest"
GITHUB_RAW_INSTALLER_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/main/install.sh"
GITHUB_RELEASES_LATEST_URL="https://github.com/${GH_USER}/${GH_REPO}/releases/latest"
GITHUB_LATEST_BINARY_URL="https://github.com/${GH_USER}/${GH_REPO}/releases/latest/download/${SERVICE_NAME}"
WARP_TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"
WARP_KEYRING_PATH="/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"
WARP_APT_SOURCE_PATH="/etc/apt/sources.list.d/cloudflare-client.list"

SUDO=""
LAST_LOG_MESSAGE=""
IPV6_ONLY="${IPV6_ONLY:-0}"
ROOT_HOME="${ROOT_HOME:-/root}"

log() {
    LAST_LOG_MESSAGE="$1"
    printf '\n==> %s\n' "$1" >&2
}

die() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

on_error() {
    local exit_code="$?"
    local line_no="${1:-unknown}"
    local failed_command="${BASH_COMMAND:-unknown}"

    printf 'Error: Command failed at line %s with exit code %s: %s\n' "$line_no" "$exit_code" "$failed_command" >&2
    if [ -n "$LAST_LOG_MESSAGE" ]; then
        printf 'Error: Last log message: %s\n' "$LAST_LOG_MESSAGE" >&2
    fi
    exit "$exit_code"
}

trap 'on_error $LINENO' ERR

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [options]

Options:
  --ipv6-only       Allow the installer to configure /etc/resolv.conf with DNS64/NAT64
                   resolvers when GitHub download connectivity is unavailable.
  --no-ipv6-only    Disable IPv6-only mode. This is the default.
  -h, --help        Show this help message.
EOF
}

set_ipv6_only_value() {
    case "$1" in
        1 | true | TRUE | yes | YES | on | ON)
            IPV6_ONLY=1
            ;;
        0 | false | FALSE | no | NO | off | OFF)
            IPV6_ONLY=0
            ;;
        *)
            die "Invalid --ipv6-only value: $1"
            ;;
    esac
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --ipv6-only)
                IPV6_ONLY=1
                ;;
            --ipv6-only=*)
                set_ipv6_only_value "${1#*=}"
                ;;
            --no-ipv6-only)
                IPV6_ONLY=0
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
        shift
    done
}

is_ipv6_only_mode() {
    [ "$IPV6_ONLY" = "1" ]
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_root_or_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        SUDO=""
        HOME="$ROOT_HOME"
        export HOME
        return
    fi

    die "Run this script as root with sudo ./install.sh."
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
    if ! curl -fsSL "$url" -o "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi

    if ! run_as_root mkdir -p "$(dirname "$destination")"; then
        rm -f "$temp_file"
        return 1
    fi

    if ! run_as_root install -m "$mode" "$temp_file" "$destination"; then
        rm -f "$temp_file"
        return 1
    fi

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

http_status_code() {
    local url="$1"
    shift || true

    curl --silent --show-error --location --output /dev/null --connect-timeout 10 --max-time 30 --write-out '%{http_code}' "$@" "$url" 2>/dev/null || printf '000'
}

first_redirect_location() {
    local url="$1"
    local headers

    headers="$(curl --silent --show-error --head --connect-timeout 10 --max-time 30 "$url" 2>/dev/null || true)"
    awk 'tolower($1) == "location:" { location = $2; sub(/\r$/, "", location); print location; exit }' <<< "$headers"
}

github_api_curl() {
    local url="$1"
    shift || true

    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl --silent --show-error --location \
            -H "Accept: application/vnd.github+json" \
            -H "User-Agent: cfporttest-installer" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            "$@" "$url"
        return
    fi

    curl --silent --show-error --location \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: cfporttest-installer" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$@" "$url"
}

github_api_status() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        http_status_code "$1" \
            -H "Accept: application/vnd.github+json" \
            -H "User-Agent: cfporttest-installer" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            -H "Authorization: Bearer ${GITHUB_TOKEN}"
        return
    fi

    http_status_code "$1" \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: cfporttest-installer" \
        -H "X-GitHub-Api-Version: 2022-11-28"
}

resolve_release_tag() {
    if [ -n "${TAG:-}" ]; then
        printf '%s\n' "$TAG"
        return
    fi

    local latest_tag=""
    local api_status=""
    local redirect_location=""

    redirect_location="$(first_redirect_location "$GITHUB_LATEST_BINARY_URL")"
    case "$redirect_location" in
        */releases/download/*/"${SERVICE_NAME}")
            latest_tag="$(printf '%s\n' "$redirect_location" | sed -E 's#^.*/releases/download/([^/]+)/'"${SERVICE_NAME}"'([?#].*)?$#\1#')"
            ;;
    esac

    if [ -n "$latest_tag" ]; then
        printf '%s\n' "$latest_tag"
        return
    fi

    api_status="$(github_api_status "$GITHUB_API_RELEASES_URL")"
    if [ "$api_status" = "200" ]; then
        latest_tag="$(github_api_curl "$GITHUB_API_RELEASES_URL" | grep -m1 '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')"
    elif [ "$api_status" = "403" ]; then
        log "GitHub API returned 403. Falling back to releases/latest redirect resolution."
    elif [ "$api_status" != "000" ]; then
        log "GitHub API returned HTTP ${api_status}. Falling back to releases/latest redirect resolution."
    fi

    if [ -z "$latest_tag" ]; then
        redirect_location="$(first_redirect_location "$GITHUB_RELEASES_LATEST_URL")"
        case "$redirect_location" in
            */releases/tag/*)
                latest_tag="$(printf '%s\n' "$redirect_location" | sed -E 's#^.*/releases/tag/([^/?#]+).*$#\1#')"
                ;;
        esac
    fi

    [ -n "$latest_tag" ] || die "Unable to resolve the latest release tag. If GitHub is rate-limiting your server IP, set GITHUB_TOKEN before running the installer."

    printf '%s\n' "$latest_tag"
}

validate_release_tag() {
    local tag="$1"

    [[ "$tag" =~ ^v[0-9A-Za-z._-]+$ ]] || die "Resolved release tag is invalid: ${tag}. Re-download the latest install.sh and retry."
}

validate_email() {
    local email="$1"
    local local_part=""
    local domain_part=""

    [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || die "Email address format is invalid: ${email}"
    [[ "$email" != *"'"* ]] || die "Email address must not contain single quotes: ${email}"

    local_part="${email%@*}"
    domain_part="${email#*@}"

    [ -n "$local_part" ] || die "Email address format is invalid: ${email}"
    [[ "$domain_part" == *.* ]] || die "Email domain must contain a public suffix: ${domain_part}"
    [[ "$domain_part" != .* ]] || die "Email domain is invalid: ${domain_part}"
    [[ "$domain_part" != *. ]] || die "Email domain is invalid: ${domain_part}"
    [[ "$domain_part" != *..* ]] || die "Email domain is invalid: ${domain_part}"
    [[ "$domain_part" =~ \.[A-Za-z]{2,}$ ]] || die "Email domain must end with a valid public suffix: ${domain_part}"
}

validate_domain() {
    local domain="$1"

    [[ "$domain" != *"'"* ]] || die "Domain must not contain single quotes: ${domain}"
    [[ "$domain" != *","* ]] || die "Domain must not contain commas: ${domain}"
    [[ "$domain" != -* ]] || die "Domain label must not start with a hyphen: ${domain}"
    [[ "$domain" != *.-* ]] || die "Domain label must not start with a hyphen: ${domain}"
    [[ "$domain" != *-. ]] || die "Domain label must not end with a hyphen: ${domain}"
    [[ "$domain" =~ ^(\*\.)?([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "Domain format is invalid: ${domain}"
}

trim() {
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

cert_file_stem() {
    local domain="$1"

    if [[ "$domain" == \*.* ]]; then
        printf 'wildcard.%s\n' "${domain#*.}"
        return
    fi

    printf '%s\n' "$domain"
}

ensure_webroot_compatible_domains() {
    local domain

    for domain in "${NORMALIZED_DOMAINS[@]}"; do
        if [[ "$domain" == \*.* ]]; then
            die "Wildcard domains require DNS mode. Choose DNS mode to issue certificates for ${domain}."
        fi
    done
}

normalize_domains() {
    local domain
    local nginx_domains=()
    local normalized_domains=()

    DOMAINS="$(trim "$DOMAINS")"
    [ -n "$DOMAINS" ] || die "The domain list cannot be empty."

    IFS=',' read -r -a domains_array <<< "$DOMAINS"
    ACME_DOMAINS=()
    CERT_MAIN_DOMAIN=""
    NORMALIZED_DOMAINS=()
    NGINX_DOMAINS=""

    for domain in "${domains_array[@]}"; do
        domain="$(trim "$domain")"
        [ -n "$domain" ] || continue
        [[ "$domain" != *[[:space:]]* ]] || die "Domain must not contain whitespace: ${domain}"
        validate_domain "$domain"
        ACME_DOMAINS+=("-d" "$domain")
        nginx_domains+=("$domain")
        normalized_domains+=("$domain")
        if [ -z "$CERT_MAIN_DOMAIN" ]; then
            CERT_MAIN_DOMAIN="$domain"
        fi
    done

    [ "${#ACME_DOMAINS[@]}" -gt 0 ] || die "At least one valid domain is required."
    NORMALIZED_DOMAINS=("${normalized_domains[@]}")
    DOMAINS="$(IFS=,; printf '%s' "${NORMALIZED_DOMAINS[*]}")"
    NGINX_DOMAINS="${nginx_domains[*]}"
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

has_required_download_connectivity() {
    local api_status=""
    local raw_status=""
    local release_status=""
    local binary_status=""

    api_status="$(github_api_status "$GITHUB_API_RELEASES_URL")"
    raw_status="$(http_status_code "$GITHUB_RAW_INSTALLER_URL")"
    release_status="$(http_status_code "$GITHUB_RELEASES_LATEST_URL")"
    binary_status="$(http_status_code "$GITHUB_LATEST_BINARY_URL")"

    [ "$api_status" != "000" ] && [ "$raw_status" != "000" ] && [ "$release_status" != "000" ] && [ "$binary_status" != "000" ]
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

configure_nat64_net_dns64() {
    local existing_directives=""

    if [ -e "$RESOLV_CONF_PATH" ]; then
        existing_directives="$(awk '/^(search|options|domain)[[:space:]]/ {print}' "$RESOLV_CONF_PATH" 2>/dev/null || true)"
    fi

    backup_resolver_config

    {
        printf '# Managed by cf_port_test install.sh for IPv6-only DNS64+NAT64 access via nat64.net\n'
        printf 'nameserver %s\n' "$NAT64_NET_PRIMARY"
        printf 'nameserver %s\n' "$NAT64_NET_SECONDARY"
        printf 'nameserver %s\n' "$NAT64_NET_TERTIARY"
        if [ -n "$existing_directives" ]; then
            printf '%s\n' "$existing_directives"
        fi
    } | run_as_root tee "$RESOLV_CONF_PATH" >/dev/null
}

resolver_config_is_managed() {
    [ -f "$RESOLV_CONF_PATH" ] && grep -q '^# Managed by cf_port_test install.sh' "$RESOLV_CONF_PATH"
}

restore_resolver_config() {
    [ -f "$DNS64_BACKUP_PATH" ] || return

    if [ -e "$RESOLV_CONF_PATH" ] && ! resolver_config_is_managed; then
        log "Leaving ${RESOLV_CONF_PATH} unchanged because it is no longer managed by cfporttest."
        return
    fi

    log "Restoring resolver configuration from ${DNS64_BACKUP_PATH}..."
    run_as_root cp "$DNS64_BACKUP_PATH" "$RESOLV_CONF_PATH"
    run_as_root rm -f "$DNS64_BACKUP_PATH"
}

ubuntu_codename() {
    if [ -r /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        if [ -n "${VERSION_CODENAME:-}" ]; then
            printf '%s\n' "$VERSION_CODENAME"
            return
        fi
    fi

    ensure_dependency lsb_release lsb-release
    lsb_release -cs
}

ensure_warp_repository() {
    local codename

    ensure_dependency gpg gpg
    codename="$(ubuntu_codename)"

    if [ ! -f "$WARP_KEYRING_PATH" ]; then
        log "Installing Cloudflare WARP signing key..."
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | run_as_root gpg --yes --dearmor --output "$WARP_KEYRING_PATH"
    fi

    printf 'deb [signed-by=%s] https://pkg.cloudflareclient.com/ %s main\n' "$WARP_KEYRING_PATH" "$codename" | run_as_root tee "$WARP_APT_SOURCE_PATH" >/dev/null
}

warp_is_connected() {
    curl --silent --show-error --location --connect-timeout 10 --max-time 30 "$WARP_TRACE_URL" 2>/dev/null | grep -q '^warp=on$'
}

ensure_warp_connected() {
    if ! command_exists warp-cli; then
        log "Installing Cloudflare WARP to restore outbound IPv4 connectivity..."
        ensure_warp_repository
        run_as_root apt-get update
        run_as_root apt-get install -y cloudflare-warp
    else
        log "Cloudflare WARP is already installed."
    fi

    enable_service warp-svc

    if ! run_as_root warp-cli registration show >/dev/null 2>&1; then
        log "Registering Cloudflare WARP client..."
        run_as_root warp-cli registration new
    fi

    run_as_root warp-cli mode warp >/dev/null 2>&1 || true

    if ! warp_is_connected; then
        log "Connecting Cloudflare WARP..."
        run_as_root warp-cli connect || true
        sleep 5
    fi

    warp_is_connected || die "Cloudflare WARP could not establish connectivity."
}

ensure_ipv4_only_website_access() {
    if has_required_download_connectivity; then
        log "GitHub download connectivity is available."
        return
    fi

    if has_direct_ipv4_access; then
        log "Native IPv4 is available, but GitHub is still unreachable."
    else
        if has_dns64_resolution; then
            log "Existing DNS64 is present, but GitHub is still unreachable."
        else
            log "IPv4-only website access is unavailable."
        fi
    fi

    if ! is_ipv6_only_mode; then
        log "GitHub download connectivity is unavailable. Leaving ${RESOLV_CONF_PATH} unchanged."
        die "If this is an IPv6-only server, rerun the installer with --ipv6-only to allow DNS64/NAT64 resolver configuration."
    fi

    log "Configuring nat64.net DNS64+NAT64 service..."
    configure_nat64_net_dns64

    if has_required_download_connectivity; then
        log "GitHub download connectivity is now available through nat64.net."
        return
    fi

    log "GitHub is still unreachable. Falling back to Cloudflare WARP."
    ensure_warp_connected

    if has_required_download_connectivity; then
        log "GitHub download connectivity is now available through Cloudflare WARP."
        return
    fi

    die "GitHub is still unreachable after enabling Cloudflare WARP."
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

set_shell_conf_value() {
    local file_path="$1"
    local key="$2"
    local value="$3"
    local temp_file
    local existing_file=""

    mkdir -p "$(dirname "$file_path")"
    temp_file="$(mktemp)"

    if [ -f "$file_path" ]; then
        existing_file="$file_path"
    fi

    if [ -n "$existing_file" ]; then
        grep -v "^${key}=" "$existing_file" > "$temp_file" || true
    fi

    printf "%s='%s'\n" "$key" "$value" >> "$temp_file"
    install -m 0600 "$temp_file" "$file_path"
    rm -f "$temp_file"
}

backup_file_once() {
    local file_path="$1"
    local backup_path="${file_path}.cfporttest.bak"

    log "Checking whether ${file_path} needs a backup..."
    [ -f "$file_path" ] || return
    [ -f "$backup_path" ] || cp "$file_path" "$backup_path"
}

sync_acme_account_email_files() {
    local account_conf="${HOME}/.acme.sh/account.conf"
    local ca_conf="${HOME}/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory/ca.conf"

    log "Syncing acme.sh email into ${account_conf}..."
    backup_file_once "$account_conf"
    backup_file_once "$ca_conf"
    set_shell_conf_value "$account_conf" "ACCOUNT_EMAIL" "$EMAIL"
    log "Syncing acme.sh email into ${ca_conf}..."
    set_shell_conf_value "$ca_conf" "CA_EMAIL" "$EMAIL"
    log "acme.sh email configuration files have been updated."
}

read_shell_conf_value() {
    local file_path="$1"
    local key="$2"

    [ -f "$file_path" ] || return 0
    sed -n -E "s/^${key}='(.*)'$/\1/p" "$file_path" | head -n 1 || true
}

current_acme_account_url() {
    local ca_conf="${HOME}/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory/ca.conf"

    log "Reading ACCOUNT_URL from ${ca_conf}..."
    read_shell_conf_value "$ca_conf" "ACCOUNT_URL"
}

reset_letsencrypt_account_cache() {
    local letsencrypt_ca_dir="${HOME}/.acme.sh/ca/acme-v02.api.letsencrypt.org"
    local backup_dir=""

    [ -d "$letsencrypt_ca_dir" ] || return

    backup_dir="${letsencrypt_ca_dir}.cfporttest.reset.$(date +%Y%m%d%H%M%S)"
    mv "$letsencrypt_ca_dir" "$backup_dir"
    log "Moved stale acme.sh Let's Encrypt cache to ${backup_dir}."
}

run_acme_with_email() {
    if command_exists timeout; then
        ACCOUNT_EMAIL="$EMAIL" CA_EMAIL="$EMAIL" timeout --foreground 180 "$ACME_BIN" "$@"
        return
    fi

    ACCOUNT_EMAIL="$EMAIL" CA_EMAIL="$EMAIL" "$ACME_BIN" "$@"
}

ensure_acme_account_email() {
    local account_url=""

    log "Ensuring acme.sh account uses the requested email..."

    log "Starting local acme.sh email configuration sync..."
    if ! sync_acme_account_email_files; then
        die "Failed to update local acme.sh email configuration."
    fi
    log "Local acme.sh email configuration sync finished."

    log "Checking whether acme.sh already has persisted Let's Encrypt account metadata..."
    account_url="$(current_acme_account_url || true)"
    if [ -n "$account_url" ]; then
        log "Found persisted Let's Encrypt account metadata."
        return
    fi

    log "No persisted Let's Encrypt account metadata found yet. acme.sh will register an account during certificate issuance if needed."
}

run_acme_issue_with_recovery() {
    local issue_log
    local issue_status=0

    issue_log="$(mktemp)"

    if run_acme_with_email "$@" >"$issue_log" 2>&1; then
        cat "$issue_log"
        rm -f "$issue_log"
        return
    else
        issue_status=$?
    fi
    cat "$issue_log"

    if grep -Eq 'invalidContact|The account URL is empty|contact email has invalid domain' "$issue_log"; then
        log "acme.sh account state is invalid. Resetting Let's Encrypt account cache and retrying once..."
        reset_letsencrypt_account_cache
        sync_acme_account_email_files
        : > "$issue_log"

        if run_acme_with_email "$@" >"$issue_log" 2>&1; then
            cat "$issue_log"
            rm -f "$issue_log"
            return
        else
            issue_status=$?
        fi
        cat "$issue_log"
    fi

    rm -f "$issue_log"
    return "$issue_status"
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

validate_nginx_conf_d_include() {
    [ -f "$NGINX_MAIN_CONFIG_PATH" ] || die "Nginx main config is missing: ${NGINX_MAIN_CONFIG_PATH}"

    grep -Eq 'include[[:space:]]+(/etc/nginx/)?conf\.d/\*\.conf;' "$NGINX_MAIN_CONFIG_PATH" \
        || die "Nginx main config must include /etc/nginx/conf.d/*.conf before cfporttest can install a conf.d fragment."
}

reload_nginx() {
    run_as_root nginx -t
    run_as_root systemctl reload nginx || run_as_root systemctl restart nginx
}

validate_and_reload_nginx() {
    validate_nginx_conf_d_include
    reload_nginx
    run_as_root systemctl enable nginx
}

remove_nginx_config_files() {
    run_as_root rm -f "$NGINX_CONFIG_PATH" "$NGINX_TEMPLATE_PATH"
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
        ensure_webroot_compatible_domains
        run_as_root mkdir -p "$ACME_WEBROOT"
        download_repo_file "$RELEASE_REF" "nginx.conf.template" "$NGINX_TEMPLATE_PATH"
        create_self_signed_cert
        render_nginx_conf "$NGINX_DOMAINS" "${SSL_DIR}/self-signed.crt" "${SSL_DIR}/self-signed.key"
        validate_and_reload_nginx
        run_acme_issue_with_recovery --issue --webroot "$ACME_WEBROOT" "${ACME_DOMAINS[@]}" --force --server letsencrypt || die "Failed to issue the certificate with webroot mode."
        return
    fi

    if [ "$cert_mode" = "2" ]; then
        log "Using DNS mode..."
        read -r -p "DNS API name (example: dns_cf): " dns_api
        [ -n "$dns_api" ] || die "The DNS API name cannot be empty."
        echo "Provider-specific variables are documented at:"
        echo "https://github.com/acmesh-official/acme.sh/wiki/dnsapi"
        prompt_dns_credentials
        run_acme_issue_with_recovery --issue --dns "$dns_api" "${ACME_DOMAINS[@]}" --force --server letsencrypt || die "Failed to issue the certificate with DNS mode."
        return
    fi

    die "Invalid certificate mode selection."
}

install_certificate_and_nginx() {
    local cert_stem
    cert_stem="$(cert_file_stem "$CERT_MAIN_DOMAIN")"
    local cert_path="${SSL_DIR}/${cert_stem}.crt"
    local key_path="${SSL_DIR}/${cert_stem}.key"
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
    render_nginx_conf "$NGINX_DOMAINS" "$cert_path" "$key_path"
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
    validate_email "$EMAIL"

    read -r -p "Release tag to install (leave blank for latest): " TAG

    RELEASE_TAG="$(resolve_release_tag | awk 'NF { line = $0 } END { sub(/\r$/, "", line); print line }')"
    validate_release_tag "$RELEASE_TAG"
    RELEASE_REF="$RELEASE_TAG"
    log "Using release tag: ${RELEASE_TAG}"

    ensure_dependency nginx nginx
    ensure_dependency socat socat
    ensure_dependency openssl openssl
    ensure_cron_service
    ensure_acme
    ensure_acme_account_email

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

    if [ -f "$SYSTEMD_SERVICE_PATH" ]; then
        run_as_root rm -f "$SYSTEMD_SERVICE_PATH"
        run_as_root systemctl daemon-reload
    fi

    run_as_root rm -f "${INSTALL_DIR}/${SERVICE_NAME}"
    run_as_root rmdir "$INSTALL_DIR" 2>/dev/null || true
    remove_nginx_config_files
    if command_exists nginx; then
        reload_nginx || true
    fi

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

    restore_resolver_config

    log "Uninstall completed."
}

main() {
    parse_args "$@"

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

if [ "${CFPORTTEST_TESTING:-0}" != "1" ]; then
    main "$@"
fi
