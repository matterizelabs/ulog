#!/bin/bash
# ulog - USB serial logger (multi-device support)
set -uo pipefail

readonly CONFIG_FILE="/etc/ulog.conf"
readonly CONFIG_DIR="/etc/ulog.d"
readonly VALID_BAUDS=(300 1200 2400 4800 9600 19200 38400 57600 115200 230400 460800 921600)

# Track child PIDs for cleanup
declare -a CHILD_PIDS=()

# Logging functions
log_error() { echo "ulog: ERROR: $*" >&2; }
log_info() { echo "ulog: $*"; }
log_device() { echo "ulog[$1]: $2"; }
log_device_error() { echo "ulog[$1]: ERROR: $2" >&2; }

# Parse config file safely - sets PARSED_DEVICE, PARSED_BAUD, PARSED_LOG_DIR
parse_config() {
    local config_file="$1"

    # Reset parsed values
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

# Validation functions
validate_device() {
    local device="$1"
    if [[ ! "$device" =~ ^/dev/tty[A-Za-z]+[0-9]*$ ]]; then
        return 1
    fi
    if [[ "$device" =~ [!\"\'\`\$\(\)\{\}\[\]\|\;\&\<\>] ]]; then
        return 1
    fi
    return 0
}

validate_baud() {
    local baud="$1"
    if [[ ! "$baud" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    for valid_baud in "${VALID_BAUDS[@]}"; do
        [[ "$baud" == "$valid_baud" ]] && return 0
    done
    return 1
}

validate_log_dir() {
    local log_dir="$1"
    if [[ ! "$log_dir" =~ ^/ ]] || [[ "$log_dir" =~ \.\. ]]; then
        return 1
    fi
    if [[ ! "$log_dir" =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
        return 1
    fi
    local canonical_dir
    canonical_dir=$(realpath -m "$log_dir")
    [[ "$canonical_dir" =~ ^/var/log/ ]] && return 0
    return 1
}

# Wait for device to be ready
wait_for_device() {
    local device="$1"
    local max_attempts=20
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        if [[ -c "$device" ]] && stty -F "$device" &>/dev/null; then
            return 0
        fi
        sleep 0.5
        ((attempt++))
    done
    return 1
}

# Initialize serial port
init_serial() {
    local device="$1"
    local baud="$2"

    stty -F "$device" "$baud" raw -echo -echoe -echok -echoctl -echonl \
         -icanon -iexten -isig -brkint -icrnl -ignbrk -igncr -inlcr \
         -inpck -istrip -ixon -ixoff -parmrk -opost cs8 cread clocal -crtscts \
         min 1 time 0 2>/dev/null || return 1
    sleep 0.2
    return 0
}

# Create log file safely
create_log_file() {
    local log_dir="$1"
    local today="$2"
    local day_dir="$log_dir/$today"
    local logfile="$day_dir/$(date +%Y-%m-%d_%H-%M-%S).log"

    if [[ ! -d "$day_dir" ]]; then
        mkdir -p "$day_dir"
        chmod 0750 "$day_dir"
    fi

    if [[ -e "$logfile" || -L "$logfile" ]]; then
        return 1
    fi

    touch "$logfile"
    chmod 0640 "$logfile"
    echo "$logfile"
}

# Log a single device (runs as child process)
log_device_worker() {
    local name="$1"
    local device="$2"
    local baud="$3"
    local log_dir="$4"

    log_device "$name" "Starting logger for $device at $baud baud"

    # Validate
    if ! validate_device "$device"; then
        log_device_error "$name" "Invalid device: $device"
        return 1
    fi
    if ! validate_baud "$baud"; then
        log_device_error "$name" "Invalid baud rate: $baud"
        return 1
    fi
    if ! validate_log_dir "$log_dir"; then
        log_device_error "$name" "Invalid log directory: $log_dir"
        return 1
    fi

    # Wait for device
    log_device "$name" "Waiting for device..."
    if ! wait_for_device "$device"; then
        log_device_error "$name" "Device not ready: $device"
        return 1
    fi

    # Initialize serial port
    log_device "$name" "Initializing serial port..."
    if ! init_serial "$device" "$baud"; then
        log_device_error "$name" "Failed to initialize: $device"
        return 1
    fi

    # Create log file
    local today logfile
    today=$(date +%Y-%m-%d)
    logfile=$(create_log_file "$log_dir" "$today")
    if [[ -z "$logfile" ]]; then
        log_device_error "$name" "Failed to create log file"
        return 1
    fi

    log_device "$name" "Logging to $logfile"

    # Start logging
    exec socat -u "$device,b${baud},raw,echo=0,crtscts=0,clocal=1" STDOUT \
        | ts '%b %d %H:%M:%S' >> "$logfile"
}

# Cleanup handler
cleanup() {
    log_info "Shutting down..."
    for pid in "${CHILD_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
    done
    wait
    log_info "All loggers stopped"
    exit 0
}

# Main
main() {
    trap cleanup SIGTERM SIGINT SIGHUP

    # Load global defaults
    local default_baud="115200"

    if [[ -f "$CONFIG_FILE" ]]; then
        parse_config "$CONFIG_FILE" || true
        [[ -n "$PARSED_BAUD" ]] && default_baud="$PARSED_BAUD"
    fi

    local device_count=0

    # Process device configs from /etc/ulog.d/
    if [[ -d "$CONFIG_DIR" ]]; then
        for config in "$CONFIG_DIR"/*.conf; do
            [[ -f "$config" ]] || continue

            parse_config "$config" || continue

            local device="$PARSED_DEVICE"
            local baud="${PARSED_BAUD:-$default_baud}"
            local log_dir="$PARSED_LOG_DIR"

            if [[ -z "$device" ]]; then
                log_error "No DEVICE in $config, skipping"
                continue
            fi

            # Default log_dir based on device name
            if [[ -z "$log_dir" ]]; then
                local dev_name
                dev_name=$(basename "$device")
                log_dir="/var/log/ulog/$dev_name"
            fi

            local name
            name=$(basename "$config" .conf)

            log_device_worker "$name" "$device" "$baud" "$log_dir" &
            CHILD_PIDS+=($!)
            ((device_count++))

            log_info "Started logger for $device (PID: ${CHILD_PIDS[-1]})"
        done
    fi

    # Fallback: if no device configs, use main config (backwards compatible)
    if [[ $device_count -eq 0 ]]; then
        if [[ -f "$CONFIG_FILE" ]]; then
            parse_config "$CONFIG_FILE" || true

            local device="$PARSED_DEVICE"
            local baud="${PARSED_BAUD:-$default_baud}"
            local log_dir="$PARSED_LOG_DIR"

            if [[ -n "$device" ]]; then
                [[ -z "$log_dir" ]] && log_dir="/var/log/ulog/$(basename "$device")"

                log_device_worker "default" "$device" "$baud" "$log_dir" &
                CHILD_PIDS+=($!)
                ((device_count++))

                log_info "Started logger for $device (PID: ${CHILD_PIDS[-1]})"
            fi
        fi
    fi

    if [[ $device_count -eq 0 ]]; then
        log_error "No devices configured. Add configs to $CONFIG_DIR/"
        exit 1
    fi

    log_info "Started $device_count device logger(s)"

    # Wait for any child to exit, then restart it
    while true; do
        for i in "${!CHILD_PIDS[@]}"; do
            pid="${CHILD_PIDS[$i]}"
            if ! kill -0 "$pid" 2>/dev/null; then
                log_info "Logger (PID: $pid) exited, will be restarted by systemd"
                # Let systemd handle restart
                exit 1
            fi
        done
        sleep 5
    done
}

main "$@"
