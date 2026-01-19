#!/bin/bash
# ulog - USB serial logger
set -euo pipefail

readonly CONFIG_FILE="/etc/ulog.conf"

# Valid baud rates whitelist
readonly VALID_BAUDS=(300 1200 2400 4800 9600 19200 38400 57600 115200 230400 460800 921600)

# Logging functions
log_error() { echo "ulog: ERROR: $*" >&2; }
log_info() { echo "ulog: $*"; }

parse_config() {
    local config_file="$1"

    # Check file exists and is a regular file
    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        return 1
    fi

    # Check file is owned by root (only root can modify)
    local file_owner
    file_owner=$(stat -c %u "$config_file")

    if [[ "$file_owner" != "0" ]]; then
        log_error "Config file must be owned by root: $config_file"
        return 1
    fi

    # Check file is not world-writable or world-readable (should be 0640 root:ulog)
    local file_perms
    file_perms=$(stat -c %a "$config_file")

    if [[ "${file_perms: -1}" != "0" ]]; then
        log_error "Config file must not be world-accessible (expected 0640): $config_file"
        return 1
    fi

    # Parse config safely - only read key=value pairs
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        # Skip empty lines and comments
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue

        # Remove leading/trailing whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

        # Only accept known configuration keys
        case "$key" in
            DEVICE)  CONFIG_DEVICE="$value" ;;
            BAUD)    CONFIG_BAUD="$value" ;;
            LOG_DIR) CONFIG_LOG_DIR="$value" ;;
            *)       log_error "Unknown config key ignored: $key" ;;
        esac
    done < "$config_file"
}

# Validate device path
validate_device() {
    local device="$1"

    # Must match strict pattern: /dev/tty[A-Za-z]+[0-9]*
    if [[ ! "$device" =~ ^/dev/tty[A-Za-z]+[0-9]*$ ]]; then
        log_error "Invalid device path format: $device"
        log_error "Device must match pattern: /dev/tty[A-Za-z]+[0-9]*"
        return 1
    fi

    # Ensure no special characters that could be used for injection
    if [[ "$device" =~ [!\"\'\`\$\(\)\{\}\[\]\|\;\&\<\>] ]]; then
        log_error "Device path contains invalid characters: $device"
        return 1
    fi

    return 0
}

# Validate baud rate
validate_baud() {
    local baud="$1"

    # Must be numeric only
    if [[ ! "$baud" =~ ^[0-9]+$ ]]; then
        log_error "Invalid baud rate (must be numeric): $baud"
        return 1
    fi

    # Check against whitelist
    local valid=0
    for valid_baud in "${VALID_BAUDS[@]}"; do
        if [[ "$baud" == "$valid_baud" ]]; then
            valid=1
            break
        fi
    done

    if [[ $valid -eq 0 ]]; then
        log_error "Non-standard baud rate: $baud"
        log_error "Valid rates: ${VALID_BAUDS[*]}"
        return 1
    fi

    return 0
}

# Validate log directory
validate_log_dir() {
    local log_dir="$1"

    # Must be absolute path
    if [[ ! "$log_dir" =~ ^/ ]]; then
        log_error "Log directory must be absolute path: $log_dir"
        return 1
    fi

    # No path traversal sequences
    if [[ "$log_dir" =~ \.\. ]]; then
        log_error "Log directory must not contain '..': $log_dir"
        return 1
    fi

    # Only allow safe characters
    if [[ ! "$log_dir" =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
        log_error "Log directory contains invalid characters: $log_dir"
        return 1
    fi

    # Canonicalize and ensure under /var/log/
    local canonical_dir
    canonical_dir=$(realpath -m "$log_dir")

    if [[ ! "$canonical_dir" =~ ^/var/log/ ]]; then
        log_error "Log directory must be under /var/log/: $log_dir"
        return 1
    fi

    return 0
}

# Safe log file creation
create_log_file() {
    local log_dir="$1"
    local today="$2"
    local day_dir="$log_dir/$today"
    local logfile="$day_dir/$(date +%Y-%m-%d_%H-%M-%S).log"

    # Create directory with safe permissions
    if [[ ! -d "$day_dir" ]]; then
        mkdir -p "$day_dir"
        chmod 0750 "$day_dir"
    fi

    # Check logfile doesn't exist and isn't a symlink
    if [[ -e "$logfile" || -L "$logfile" ]]; then
        log_error "Log file already exists or is a symlink: $logfile"
        return 1
    fi

    # Create file with safe permissions
    touch "$logfile"
    chmod 0640 "$logfile"

    echo "$logfile"
}

# Main
main() {
    # Defaults
    local device="/dev/ttyUSB0"
    local baud="115200"
    local log_dir="/var/log/ttyUSB0"

    # Parse config if exists
    if [[ -f "$CONFIG_FILE" ]]; then
        parse_config "$CONFIG_FILE"
        device="${CONFIG_DEVICE:-$device}"
        baud="${CONFIG_BAUD:-$baud}"
        log_dir="${CONFIG_LOG_DIR:-$log_dir}"
    fi

    # Validate all inputs
    validate_device "$device" || exit 1
    validate_baud "$baud" || exit 1
    validate_log_dir "$log_dir" || exit 1

    # Check device exists before starting
    if [[ ! -c "$device" ]]; then
        log_error "Device not found or not a character device: $device"
        exit 1
    fi

    # Create log file safely
    local today logfile
    today=$(date +%Y-%m-%d)
    logfile=$(create_log_file "$log_dir" "$today") || exit 1

    log_info "Logging $device ($baud baud) to $logfile"

    # Start logging with socat - using validated inputs only
    exec socat -u "$device,b${baud},raw,echo=0,crtscts=0,clocal=1" STDOUT \
        | ts '%b %d %H:%M:%S' >> "$logfile"
}

main "$@"
