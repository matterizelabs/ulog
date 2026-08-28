#!/bin/bash
readonly VALID_BAUDS=(300 1200 2400 4800 9600 19200 38400 57600 115200 230400 460800 921600)

parse_config() {
    local config_file="$1"

    PARSED_DEVICE=""
    PARSED_BAUD=""
    PARSED_LOG_DIR=""

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        return 1
    fi

    local file_owner file_perms
    file_owner=$(stat -c %u "$config_file")
    file_perms=$(stat -c %a "$config_file")

    if [[ "$file_owner" != "0" ]]; then
        log_error "Config file must be owned by root: $config_file"
        return 1
    fi

    if [[ "${file_perms: -1}" != "0" ]]; then
        log_error "Config file must not be world-accessible (expected 0640): $config_file"
        return 1
    fi

    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

        case "$key" in
            DEVICE)  PARSED_DEVICE="$value" ;;
            BAUD)    PARSED_BAUD="$value" ;;
            LOG_DIR) PARSED_LOG_DIR="$value" ;;
        esac
    done < "$config_file"
}

validate_device() {
    local device="$1"
    [[ "$device" =~ ^/dev/tty[A-Za-z]+[0-9]*$ ]] || return 1
    [[ ! "$device" =~ [!\"\'\`\$\(\)\{\}\[\]\|\;\&\<\>] ]] || return 1
    return 0
}

validate_dev_name() {
    local dev_name="$1"
    [[ "$dev_name" =~ ^tty[A-Za-z]+[0-9]*$ ]] || return 1
    [[ ! "$dev_name" =~ [\"\'\`\$\(\)\{\}\[\]\|\;\&\<\>\,\=] ]] || return 1
    return 0
}

validate_baud() {
    local baud="$1"
    [[ "$baud" =~ ^[0-9]+$ ]] || return 1
    for valid_baud in "${VALID_BAUDS[@]}"; do
        [[ "$baud" == "$valid_baud" ]] && return 0
    done
    return 1
}

validate_log_dir() {
    local log_dir="$1"
    [[ "$log_dir" =~ ^/ ]] || return 1
    [[ ! "$log_dir" =~ \.\. ]] || return 1
    [[ "$log_dir" =~ ^/[a-zA-Z0-9/_-]+$ ]] || return 1
    local canonical_dir
    canonical_dir=$(realpath -m "$log_dir")
    [[ "$canonical_dir" =~ ^/var/log/ ]] && return 0
    return 1
}

format_identity() {
    local identity="$1"
    local vendor product serial
    IFS=':' read -r vendor product serial <<< "$identity"
    if [[ ${#serial} -gt 8 ]]; then
        serial="${serial:0:8}"
    fi
    echo "${vendor}:${product}:${serial}"
}

identity_slug() {
    local identity="$1"
    local fallback="$2"
    local vendor product serial
    IFS=':' read -r vendor product serial <<< "$identity"
    if [[ -z "$vendor" || "$vendor" == "unknown" || -z "$product" || "$product" == "unknown" ]]; then
        echo "$fallback"
        return
    fi
    local slug="${vendor}-${product}"
    [[ -n "$serial" && "$serial" != "unknown" ]] && slug="${slug}-${serial}"
    slug=$(echo "$slug" | tr -c 'A-Za-z0-9._-' '_' | tr -s '_' | sed 's/^_//;s/_$//')
    echo "$slug"
}
