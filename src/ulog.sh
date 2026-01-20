#!/bin/bash
# ulog - USB serial logger (multi-device support)
set -uo pipefail

readonly CONFIG_FILE="/etc/ulog.conf"
readonly CONFIG_DIR="/etc/ulog.d"
readonly STATE_DIR="/var/lib/ulog/sessions"
readonly VALID_BAUDS=(300 1200 2400 4800 9600 19200 38400 57600 115200 230400 460800 921600)

# Track child PIDs for cleanup
declare -a CHILD_PIDS=()

# Logging functions
log_error() { echo "ulog: ERROR: $*" >&2; }
log_info() { echo "ulog: $*"; }
log_device() { echo "ulog[$1]: $2"; }
log_device_error() { echo "ulog[$1]: ERROR: $2" >&2; }

# Get USB device identity from sysfs (vendor_id:product_id:serial)
# Returns "unknown" components if not available
get_device_identity() {
    local device="$1"
    local dev_name
    dev_name=$(basename "$device")

    local vendor_id="unknown"
    local product_id="unknown"
    local serial="unknown"

    # Resolve symlink to get real path, then go up to USB device
    local tty_device="/sys/class/tty/$dev_name/device"
    if [[ -L "$tty_device" ]]; then
        local usb_interface usb_device
        usb_interface=$(readlink -f "$tty_device")
        usb_device="${usb_interface%/*}"  # Go up one level to USB device

        if [[ -f "$usb_device/idVendor" ]]; then
            vendor_id=$(cat "$usb_device/idVendor" 2>/dev/null || echo "unknown")
        fi
        if [[ -f "$usb_device/idProduct" ]]; then
            product_id=$(cat "$usb_device/idProduct" 2>/dev/null || echo "unknown")
        fi
        if [[ -f "$usb_device/serial" ]]; then
            serial=$(cat "$usb_device/serial" 2>/dev/null || echo "unknown")
        fi
    fi

    echo "${vendor_id}:${product_id}:${serial}"
}

# Check if device identity has changed
# Returns 0 if changed (or new device), 1 if same
device_identity_changed() {
    local dev_name="$1"
    local current_identity="$2"
    local identity_file="$STATE_DIR/${dev_name}.identity"

    if [[ ! -f "$identity_file" ]]; then
        return 0  # No previous identity, treat as new/changed
    fi

    local stored_identity
    stored_identity=$(cat "$identity_file" 2>/dev/null || echo "")

    if [[ "$current_identity" != "$stored_identity" ]]; then
        return 0  # Identity changed
    fi

    return 1  # Same device
}

# Store device identity
store_device_identity() {
    local dev_name="$1"
    local identity="$2"
    local identity_file="$STATE_DIR/${dev_name}.identity"

    mkdir -p "$STATE_DIR"
    echo "$identity" > "$identity_file"
}

# Generate a new session ID (timestamp_pid format)
generate_session_id() {
    echo "$(date +%Y%m%d_%H%M%S)_$$"
}

# Get current session ID for a device, or generate new one
get_session_id() {
    local dev_name="$1"
    local force_new="${2:-false}"
    local session_file="$STATE_DIR/${dev_name}.session"

    if [[ "$force_new" == "true" ]] || [[ ! -f "$session_file" ]]; then
        local session_id
        session_id=$(generate_session_id)
        mkdir -p "$STATE_DIR"
        echo "$session_id" > "$session_file"
        echo "$session_id"
    else
        cat "$session_file"
    fi
}

# Clear session (called on disconnect)
clear_session() {
    local dev_name="$1"
    local session_file="$STATE_DIR/${dev_name}.session"
    rm -f "$session_file"
}

# Update session index file with new log file entry
update_session_index() {
    local log_dir="$1"
    local session_id="$2"
    local start_time="$3"
    local identity="$4"
    local log_file="$5"
    local index_file="$log_dir/session.index"

    # Calculate relative path from log_dir
    local rel_path="${log_file#$log_dir/}"

    # Check if session already exists in index
    if [[ -f "$index_file" ]] && grep -q "^${session_id}|" "$index_file"; then
        # Append file to existing session entry
        # Format: session_id|start_time|end_time|identity|file1,file2,...
        local tmp_file
        tmp_file=$(mktemp)
        while IFS='|' read -r sid stime etime ident files || [[ -n "$sid" ]]; do
            [[ -z "$sid" || "$sid" =~ ^# ]] && { echo "$sid${stime:+|$stime}${etime:+|$etime}${ident:+|$ident}${files:+|$files}" >> "$tmp_file"; continue; }
            if [[ "$sid" == "$session_id" ]]; then
                # Check if file already in list
                if [[ ! ",$files," == *",$rel_path,"* ]]; then
                    files="${files},${rel_path}"
                fi
                echo "${sid}|${stime}|ongoing|${ident}|${files}" >> "$tmp_file"
            else
                echo "${sid}|${stime}|${etime}|${ident}|${files}" >> "$tmp_file"
            fi
        done < "$index_file"
        mv "$tmp_file" "$index_file"
    else
        # Create new session entry
        if [[ ! -f "$index_file" ]]; then
            echo "# session_id|start_time|end_time|device_identity|files" > "$index_file"
        fi
        echo "${session_id}|${start_time}|ongoing|${identity}|${rel_path}" >> "$index_file"
    fi

    chmod 0640 "$index_file"
}

# Write session header to log file
write_session_header() {
    local log_file="$1"
    local session_id="$2"
    local session_start="$3"
    local device="$4"
    local identity="$5"

    local vendor_id product_id serial
    IFS=':' read -r vendor_id product_id serial <<< "$identity"

    {
        echo "# ULOG_SESSION_ID=$session_id"
        echo "# ULOG_SESSION_START=$session_start"
        echo "# ULOG_DEVICE=$device"
        echo "# ULOG_VENDOR_ID=$vendor_id"
        echo "# ULOG_PRODUCT_ID=$product_id"
        echo "# ULOG_SERIAL=$serial"
        echo "#"
    } >> "$log_file"
}

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

    # Get device identity and check for changes
    local dev_name identity session_id session_start force_new_session
    dev_name=$(basename "$device")
    identity=$(get_device_identity "$device")
    session_start=$(date -Iseconds)
    force_new_session="false"

    log_device "$name" "Device identity: $identity"

    if device_identity_changed "$dev_name" "$identity"; then
        local old_identity_file="$STATE_DIR/${dev_name}.identity"
        if [[ -f "$old_identity_file" ]]; then
            local old_identity
            old_identity=$(cat "$old_identity_file" 2>/dev/null || echo "unknown")
            log_device "$name" "WARNING: Device identity changed on $device: was $old_identity, now $identity"
            # Log to systemd journal as well
            logger -t ulog -p daemon.warning "Device identity changed on $device: was $old_identity, now $identity"
        fi
        store_device_identity "$dev_name" "$identity"
        force_new_session="true"
    fi

    # Get or create session ID
    session_id=$(get_session_id "$dev_name" "$force_new_session")
    log_device "$name" "Session ID: $session_id"

    # Create log file
    local today logfile
    today=$(date +%Y-%m-%d)
    logfile=$(create_log_file "$log_dir" "$today")
    if [[ -z "$logfile" ]]; then
        log_device_error "$name" "Failed to create log file"
        return 1
    fi

    # Write session header to log file
    write_session_header "$logfile" "$session_id" "$session_start" "$device" "$identity"

    # Update session index
    update_session_index "$log_dir" "$session_id" "$session_start" "$identity" "$logfile"

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
