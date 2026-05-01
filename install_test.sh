#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    local got="$1"
    local want="$2"
    local message="$3"

    if [ "$got" != "$want" ]; then
        fail "${message}: got '${got}', want '${want}'"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    case "$haystack" in
        *"$needle"*) ;;
        *) fail "${message}: expected output to contain '${needle}'" ;;
    esac
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    case "$haystack" in
        *"$needle"*) fail "${message}: output should not contain '${needle}'" ;;
        *) ;;
    esac
}

assert_file_missing() {
    local path="$1"
    local message="$2"

    if [ -e "$path" ]; then
        fail "${message}: '${path}' still exists"
    fi
}

assert_file_exists() {
    local path="$1"
    local message="$2"

    if [ ! -e "$path" ]; then
        fail "${message}: '${path}' is missing"
    fi
}

source_installer() {
    CFPORTTEST_TESTING=1 # shellcheck disable=SC1091
    source "${ROOT_DIR}/install.sh"
}

test_parse_args_defaults_to_no_ipv6_only() {
    source_installer

    IPV6_ONLY=0
    parse_args

    assert_eq "$IPV6_ONLY" "0" "--ipv6-only should be disabled by default"
}

test_parse_args_enables_ipv6_only() {
    source_installer

    IPV6_ONLY=0
    parse_args --ipv6-only

    assert_eq "$IPV6_ONLY" "1" "--ipv6-only should enable IPv6-only mode"
}

test_default_connectivity_failure_does_not_change_resolver() {
    source_installer

    local configured=0
    IPV6_ONLY=0

    has_required_download_connectivity() { return 1; }
    has_direct_ipv4_access() { return 1; }
    has_dns64_resolution() { return 1; }
    configure_nat64_net_dns64() { configured=1; }
    ensure_warp_connected() { fail "WARP should not be used in default mode"; }

    local output=""
    if output="$(ensure_ipv4_only_website_access 2>&1)"; then
        fail "connectivity failure should stop in default mode"
    fi

    assert_eq "$configured" "0" "default mode must not rewrite /etc/resolv.conf"
    assert_contains "$output" "--ipv6-only" "failure should explain the IPv6-only opt-in"
}

test_ipv6_only_connectivity_failure_configures_dns64() {
    source_installer

    local configured=0
    local attempts=0
    IPV6_ONLY=1

    has_required_download_connectivity() {
        attempts=$((attempts + 1))
        [ "$attempts" -ge 2 ]
    }
    has_direct_ipv4_access() { return 1; }
    has_dns64_resolution() { return 1; }
    configure_nat64_net_dns64() { configured=1; }
    ensure_warp_connected() { fail "WARP should not be needed when DNS64 fixes connectivity"; }

    ensure_ipv4_only_website_access >/dev/null 2>&1

    assert_eq "$configured" "1" "--ipv6-only should allow DNS64 resolver configuration"
}

test_normalize_domains_builds_nginx_server_names() {
    source_installer

    DOMAINS="example.com, www.example.com,*.example.net"
    normalize_domains

    assert_eq "$CERT_MAIN_DOMAIN" "example.com" "first domain should be certificate main domain"
    assert_eq "$NGINX_DOMAINS" "example.com www.example.com *.example.net" "nginx server_name should use spaces"
    assert_eq "${ACME_DOMAINS[*]}" "-d example.com -d www.example.com -d *.example.net" "acme domains should be expanded"
}

test_require_root_rejects_non_root_even_when_sudo_exists() {
    source_installer

    if [ "$(id -u)" = "0" ]; then
        printf 'skip - %s\n' "test_require_root_rejects_non_root_even_when_sudo_exists"
        return
    fi

    command_exists() {
        [ "$1" = "sudo" ]
    }

    local output=""
    if output="$(require_root_or_sudo 2>&1)"; then
        fail "non-root execution should be rejected even when sudo exists"
    fi

    assert_contains "$output" "sudo ./install.sh" "root error should tell the user how to rerun"
}

test_normalize_domains_rejects_internal_whitespace() {
    source_installer

    DOMAINS="bad domain.com"

    local output=""
    if output="$(normalize_domains 2>&1)"; then
        fail "domain names with internal whitespace should be rejected"
    fi

    assert_contains "$output" "whitespace" "domain whitespace error should be clear"
}

test_cert_file_stem_sanitizes_wildcard_domain() {
    source_installer

    assert_eq "$(cert_file_stem "*.example.com")" "wildcard.example.com" "wildcard certificate file stem should be filesystem-friendly"
    assert_eq "$(cert_file_stem "example.com")" "example.com" "regular certificate file stem should remain unchanged"
}

test_webroot_rejects_wildcard_domains() {
    source_installer

    DOMAINS="*.example.com"
    normalize_domains

    local output=""
    if output="$(ensure_webroot_compatible_domains 2>&1)"; then
        fail "webroot mode should reject wildcard domains"
    fi

    assert_contains "$output" "DNS mode" "webroot wildcard error should direct users to DNS mode"
}

test_download_to_removes_temp_file_on_failure() {
    local temp_dir
    local temp_file
    temp_dir="$(mktemp -d)"
    temp_file="${temp_dir}/download.tmp"

    trap - ERR
    set +e
    (
        export TEST_TEMP_FILE="$temp_file"
        source_installer

        mktemp() {
            : > "$TEST_TEMP_FILE"
            printf '%s\n' "$TEST_TEMP_FILE"
        }

        curl() {
            return 22
        }

        download_to "https://example.invalid/file" "${temp_dir}/out" 0644
    ) >/dev/null 2>&1
    local status=$?
    set -e
    trap 'on_error $LINENO' ERR

    if [ "$status" -eq 0 ]; then
        fail "download_to should fail when curl fails"
    fi

    assert_file_missing "$temp_file" "download_to should remove its temporary file on failure"
    rmdir "$temp_dir"
}

test_nginx_defaults_use_conf_d_app_config() {
    source_installer

    assert_eq "${NGINX_MAIN_CONFIG_PATH:-}" "/etc/nginx/nginx.conf" "nginx main config path should be explicit"
    assert_eq "$NGINX_CONFIG_PATH" "/etc/nginx/conf.d/cfporttest.conf" "installer should manage only its conf.d file"
    assert_eq "$NGINX_TEMPLATE_PATH" "/etc/nginx/cfporttest.conf.template" "installer template should not masquerade as nginx.conf"
}

test_nginx_template_is_conf_d_fragment() {
    local template
    template="$(cat "${ROOT_DIR}/nginx.conf.template")"

    assert_contains "$template" "server {" "nginx fragment should contain server blocks"
    assert_not_contains "$template" "worker_processes" "nginx fragment should not contain global directives"
    assert_not_contains "$template" "events {" "nginx fragment should not contain an events block"
    assert_not_contains "$template" "http {" "nginx fragment should not contain an http block"
}

test_validate_nginx_conf_d_include_rejects_missing_include() {
    source_installer

    local temp_dir
    temp_dir="$(mktemp -d)"
    NGINX_MAIN_CONFIG_PATH="${temp_dir}/nginx.conf"
    printf 'events {}\nhttp {}\n' > "$NGINX_MAIN_CONFIG_PATH"

    local output=""
    if output="$(validate_nginx_conf_d_include 2>&1)"; then
        fail "nginx main config without conf.d include should be rejected"
    fi

    assert_contains "$output" "conf.d/*.conf" "missing include error should name the required include"
    rm -rf "$temp_dir"
}

test_remove_nginx_config_files_keeps_main_config() {
    source_installer

    local temp_dir
    temp_dir="$(mktemp -d)"
    NGINX_MAIN_CONFIG_PATH="${temp_dir}/nginx.conf"
    NGINX_TEMPLATE_PATH="${temp_dir}/cfporttest.conf.template"
    NGINX_CONFIG_PATH="${temp_dir}/conf.d/cfporttest.conf"
    mkdir -p "$(dirname "$NGINX_CONFIG_PATH")"
    printf 'main\n' > "$NGINX_MAIN_CONFIG_PATH"
    printf 'template\n' > "$NGINX_TEMPLATE_PATH"
    printf 'app\n' > "$NGINX_CONFIG_PATH"

    run_as_root() {
        "$@"
    }

    remove_nginx_config_files

    assert_file_exists "$NGINX_MAIN_CONFIG_PATH" "removing app config must keep nginx main config"
    assert_file_missing "$NGINX_TEMPLATE_PATH" "installer template should be removed"
    assert_file_missing "$NGINX_CONFIG_PATH" "app nginx config should be removed"
    rm -rf "$temp_dir"
}

test_restore_resolver_config_restores_managed_backup() {
    source_installer

    local temp_dir
    temp_dir="$(mktemp -d)"
    RESOLV_CONF_PATH="${temp_dir}/resolv.conf"
    DNS64_BACKUP_PATH="${temp_dir}/resolv.conf.cfporttest.bak"
    printf 'nameserver 1.1.1.1\n' > "$DNS64_BACKUP_PATH"
    printf '# Managed by cf_port_test install.sh for IPv6-only DNS64+NAT64 access via nat64.net\nnameserver %s\n' "$NAT64_NET_PRIMARY" > "$RESOLV_CONF_PATH"

    run_as_root() {
        "$@"
    }

    restore_resolver_config

    assert_eq "$(cat "$RESOLV_CONF_PATH")" "nameserver 1.1.1.1" "managed resolver should be restored from backup"
    assert_file_missing "$DNS64_BACKUP_PATH" "resolver backup should be consumed after restore"
    rm -rf "$temp_dir"
}

test_restore_resolver_config_skips_unmanaged_resolver() {
    source_installer

    local temp_dir
    temp_dir="$(mktemp -d)"
    RESOLV_CONF_PATH="${temp_dir}/resolv.conf"
    DNS64_BACKUP_PATH="${temp_dir}/resolv.conf.cfporttest.bak"
    printf 'nameserver 1.1.1.1\n' > "$DNS64_BACKUP_PATH"
    printf 'nameserver 9.9.9.9\n' > "$RESOLV_CONF_PATH"

    run_as_root() {
        "$@"
    }

    restore_resolver_config

    assert_eq "$(cat "$RESOLV_CONF_PATH")" "nameserver 9.9.9.9" "unmanaged resolver should not be overwritten"
    assert_file_exists "$DNS64_BACKUP_PATH" "backup should remain when resolver is unmanaged"
    rm -rf "$temp_dir"
}

test_first_redirect_location_tolerates_early_pipeline_close() {
    source_installer

    curl() {
        printf 'HTTP/2 302\r\n'
        printf 'location: https://github.com/purepoorx/cf_port_test/releases/download/v1.2.3/cfporttest\r\n'
        local i=0
        while [ "$i" -lt 100000 ]; do
            printf 'x-extra-%s: value\r\n' "$i"
            i=$((i + 1))
        done
    }

    local got=""
    got="$(first_redirect_location "https://example.test/latest/download/cfporttest")"

    assert_eq "$got" "https://github.com/purepoorx/cf_port_test/releases/download/v1.2.3/cfporttest" "first_redirect_location should ignore harmless SIGPIPE from early Location match"
}

run_tests() {
    local test_name

    for test_name in "$@"; do
        "$test_name"
        printf 'ok - %s\n' "$test_name"
    done
}

run_tests \
    test_parse_args_defaults_to_no_ipv6_only \
    test_parse_args_enables_ipv6_only \
    test_default_connectivity_failure_does_not_change_resolver \
    test_ipv6_only_connectivity_failure_configures_dns64 \
    test_normalize_domains_builds_nginx_server_names \
    test_require_root_rejects_non_root_even_when_sudo_exists \
    test_normalize_domains_rejects_internal_whitespace \
    test_cert_file_stem_sanitizes_wildcard_domain \
    test_webroot_rejects_wildcard_domains \
    test_download_to_removes_temp_file_on_failure \
    test_nginx_defaults_use_conf_d_app_config \
    test_nginx_template_is_conf_d_fragment \
    test_validate_nginx_conf_d_include_rejects_missing_include \
    test_remove_nginx_config_files_keeps_main_config \
    test_restore_resolver_config_restores_managed_backup \
    test_restore_resolver_config_skips_unmanaged_resolver \
    test_first_redirect_location_tolerates_early_pipeline_close
