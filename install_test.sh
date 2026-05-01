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

assert_file_missing() {
    local path="$1"
    local message="$2"

    if [ -e "$path" ]; then
        fail "${message}: '${path}' still exists"
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
    test_download_to_removes_temp_file_on_failure
