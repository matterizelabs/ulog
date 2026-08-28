#!/bin/bash
set -uo pipefail

readonly CONFIG_FILE="/etc/ulog.conf"
readonly CONFIG_DIR="/etc/ulog.d"
readonly STATE_DIR="/var/lib/ulog/sessions"

_ulog_common="/usr/lib/ulog/ulog-common.sh"
[[ -f "$_ulog_common" ]] || _ulog_common="$(dirname "${BASH_SOURCE[0]}")/ulog-common.sh"
# shellcheck source=/dev/null
source "$_ulog_common"

declare -a CHILD_PIDS=()
declare -a DEV_NAMES=() DEVICES=() BAUDS=() LOG_DIRS=()
declare -a FAIL_COUNT=() WORKER_START=()
readonly RESPAWN_BASE=5 RESPAWN_MAX=300 RESPAWN_RESET=60

log_error() { echo "ulog: ERROR: $*" >&2; }
log_info() { echo "ulog: $*"; }
log_device() { echo "ulog[$1]: $2"; }
log_device_error() { echo "ulog[$1]: ERROR: $2" >&2; }

get_device_identity() {
    local device="$1"
    local dev_name
    dev_name=$(basename "$device")

    local vendor_id="unknown"
    local product_id="unknown"
    local serial="unknown"

    local tty_device="/sys/class/tty/$dev_name/device"
    if [[ -e "$tty_device" ]]; then
        local search_path
        search_path=$(readlink -f "$tty_device")

        while [[ "$search_path" != "/" && "$search_path" != "/sys/devices" ]]; do
            if [[ -f "$search_path/idVendor" ]]; then
                vendor_id=$(cat "$search_path/idVendor" 2>/dev/null | tr -d '[:space:]')
                product_id=$(cat "$search_path/idProduct" 2>/dev/null | tr -d '[:space:]')
                serial=$(cat "$search_path/serial" 2>/dev/null | tr -d '[:space:]')
                [[ -z "$vendor_id" ]] && vendor_id="unknown"
                [[ -z "$product_id" ]] && product_id="unknown"
                [[ -z "$serial" ]] && serial="unknown"
                break
            fi
            search_path="${search_path%/*}"
        done
    fi

    echo "${vendor_id}:${product_id}:${serial}"
}

device_identity_changed() {
    local dev_name="$1"
    local current_identity="$2"
    local identity_file="$STATE_DIR/${dev_name}.identity"

    if [[ ! -f "$identity_file" ]]; then
        return 0
    fi

    local stored_identity
    stored_identity=$(cat "$identity_file" 2>/dev/null || echo "")

    if [[ "$current_identity" != "$stored_identity" ]]; then
        return 0
    fi

    return 1
}

store_device_identity() {
    local dev_name="$1"
    local identity="$2"
    local identity_file="$STATE_DIR/${dev_name}.identity"

    mkdir -p "$STATE_DIR"
    echo "$identity" > "$identity_file"
}


generate_session_id() {
    local rand
    rand=$(od -An -N2 -tx1 /dev/urandom | tr -d '[:space:]')
    echo "$(date +%m%d-%H%M)-${rand}"
}

get_session_id() {
    local key="$1"
    local force_new="${2:-false}"
    local session_file="$STATE_DIR/${key}.session"

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

store_log_dir() {
    local key="$1"
    local log_dir="$2"
    mkdir -p "$STATE_DIR"
    echo "$log_dir" > "$STATE_DIR/${key}.logdir"
}

end_session() {
    local key="$1"
    local session_file="$STATE_DIR/${key}.session"
    local logdir_file="$STATE_DIR/${key}.logdir"

    [[ -f "$session_file" ]] || return 0
    [[ -f "$logdir_file" ]] || return 0

    local session_id log_dir index_file end_time
    session_id=$(cat "$session_file")
    log_dir=$(cat "$logdir_file")
    index_file="$log_dir/session.index"
    end_time=$(date -Iseconds)

    [[ -f "$index_file" ]] || return 0

    local tmp_file
    tmp_file=$(mktemp)
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^# ]]; then
            echo "$line" >> "$tmp_file"
            continue
        fi
        IFS='|' read -r sid stime etime ident files <<< "$line"
        if [[ "$sid" == "$session_id" ]]; then
            echo "${sid}|${stime}|${end_time}|${ident}|${files}" >> "$tmp_file"
        else
            echo "$line" >> "$tmp_file"
        fi
    done < "$index_file"
    mv "$tmp_file" "$index_file"
    chmod 0640 "$index_file"

    rm -f "$session_file" "$logdir_file"
}

update_session_index() {
    local log_dir="$1"
    local session_id="$2"
    local start_time="$3"
    local identity="$4"
    local log_file="$5"
    local index_file="$log_dir/session.index"
    local rel_path="${log_file#$log_dir/}"

    if [[ -f "$index_file" ]] && grep -q "^${session_id}|" "$index_file"; then
        local tmp_file
        tmp_file=$(mktemp)
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^# ]]; then
                echo "$line" >> "$tmp_file"
                continue
            fi
            IFS='|' read -r sid stime etime ident files <<< "$line"
            if [[ "$sid" == "$session_id" ]]; then
                echo "${sid}|${stime}|ongoing|${ident}|${rel_path}" >> "$tmp_file"
            else
                echo "$line" >> "$tmp_file"
            fi
        done < "$index_file"
        mv "$tmp_file" "$index_file"
    else
        [[ ! -f "$index_file" ]] && echo "# session_id|start_time|end_time|device_identity|files" > "$index_file"
        echo "${session_id}|${start_time}|ongoing|${identity}|${rel_path}" >> "$index_file"
    fi

    chmod 0640 "$index_file"
}

write_session_header() {
    local log_file="$1"
    local session_id="$2"
    local session_start="$3"
    local device="$4"
    local identity="$5"

    local vendor_id product_id serial
    IFS=':' read -r vendor_id product_id serial <<< "$identity"

    {
        echo "#ULOG:SESSION_ID=$session_id"
        echo "#ULOG:SESSION_START=$session_start"
        echo "#ULOG:DEVICE=$device"
        echo "#ULOG:VENDOR_ID=$vendor_id"
        echo "#ULOG:PRODUCT_ID=$product_id"
        echo "#ULOG:SERIAL=$serial"
    } >> "$log_file"
}


wait_for_device() {
    local device="$1"
    local waited=0
    while true; do
        if [[ -c "$device" ]] && stty -F "$device" &>/dev/null; then
            return 0
        fi
        (( waited % 30 == 0 )) && log_info "Waiting for device $device..."
        sleep 1
        (( waited++ ))
    done
}

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

log_device_worker() {
    local name="$1"
    local device="$2"
    local baud="$3"
    local log_dir="$4"

    log_device "$name" "Starting logger for $device at $baud baud"

    if ! validate_device "$device"; then
        log_device_error "$name" "Invalid device: $device"
        return 1
    fi
    if ! validate_baud "$baud"; then
        log_device_error "$name" "Invalid baud rate: $baud"
        return 1
    fi

    log_device "$name" "Waiting for device..."
    if ! wait_for_device "$device"; then
        log_device_error "$name" "Device not ready: $device"
        return 1
    fi

    local dev_name identity session_id session_start force_new_session key final_log_dir
    dev_name=$(basename "$device")
    identity=$(get_device_identity "$device")
    session_start=$(date -Iseconds)
    force_new_session="false"

    key=$(identity_slug "$identity" "$dev_name")
    final_log_dir="$log_dir"
    if [[ -z "$final_log_dir" ]]; then
        final_log_dir="/var/log/ulog/$key"
    fi
    if ! validate_log_dir "$final_log_dir"; then
        log_device_error "$name" "Invalid log directory: $final_log_dir"
        return 1
    fi

    log_device "$name" "Device identity: $(format_identity "$identity")"

    if device_identity_changed "$dev_name" "$identity"; then
        local old_identity_file="$STATE_DIR/${dev_name}.identity"
        if [[ -f "$old_identity_file" ]]; then
            local old_identity
            old_identity=$(cat "$old_identity_file" 2>/dev/null || echo "unknown")
            log_device "$name" "WARNING: Device identity changed: was $(format_identity "$old_identity"), now $(format_identity "$identity")"
            logger -t ulog -p daemon.warning "Device identity changed on $device: was $(format_identity "$old_identity"), now $(format_identity "$identity")"
        fi
        store_device_identity "$dev_name" "$identity"
        force_new_session="true"
    fi

    session_id=$(get_session_id "$key" "$force_new_session")
    log_device "$name" "Session ID: $session_id"

    local today logfile
    today=$(date +%Y-%m-%d)
    logfile=$(create_log_file "$final_log_dir" "$today")
    if [[ -z "$logfile" ]]; then
        log_device_error "$name" "Failed to create log file"
        return 1
    fi

    write_session_header "$logfile" "$session_id" "$session_start" "$device" "$identity"

    update_session_index "$final_log_dir" "$session_id" "$session_start" "$identity" "$logfile"
    store_log_dir "$key" "$final_log_dir"

    log_device "$name" "Logging to $logfile"

    socat -u "$device,b${baud},raw,echo=0,crtscts=0,clocal=1" STDOUT \
        > >(stdbuf -oL ts '%b %d %H:%M:%S' >> "$logfile") &
    local socat_pid=$!

    trap 'kill "$socat_pid" 2>/dev/null' SIGTERM SIGINT

    wait "$socat_pid"
    local rc=$?

    end_session "$key"
    return $rc
}

launch_worker() {
    local name="$1" device="$2" baud="$3" log_dir="$4"
    log_device_worker "$name" "$device" "$baud" "$log_dir" &
    local pid=$!
    CHILD_PIDS+=("$pid")
    DEV_NAMES+=("$name")
    DEVICES+=("$device")
    BAUDS+=("$baud")
    LOG_DIRS+=("$log_dir")
    FAIL_COUNT+=(0)
    WORKER_START+=("$(date +%s)")
    log_info "Started logger for $device (PID: $pid)"
}

cleanup() {
    log_info "Shutting down..."
    for pid in "${CHILD_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
    done
    wait

    for session_file in "$STATE_DIR"/*.session; do
        [[ -f "$session_file" ]] || continue
        local dev_name
        dev_name=$(basename "$session_file" .session)
        end_session "$dev_name"
        log_info "Ended session for $dev_name"
    done

    log_info "All loggers stopped"
    exit 0
}

main() {
    trap cleanup SIGTERM SIGINT SIGHUP

    local default_baud="115200"

    if [[ -f "$CONFIG_FILE" ]]; then
        parse_config "$CONFIG_FILE" || true
        [[ -n "$PARSED_BAUD" ]] && default_baud="$PARSED_BAUD"
    fi

    local device_count=0

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

            local name
            name=$(basename "$config" .conf)

            launch_worker "$name" "$device" "$baud" "$log_dir"
            ((device_count++))
        done
    fi

    if [[ $device_count -eq 0 ]]; then
        if [[ -f "$CONFIG_FILE" ]]; then
            parse_config "$CONFIG_FILE" || true

            local device="$PARSED_DEVICE"
            local baud="${PARSED_BAUD:-$default_baud}"
            local log_dir="$PARSED_LOG_DIR"

            if [[ -n "$device" ]]; then
                launch_worker "default" "$device" "$baud" "$log_dir"
                ((device_count++))
            fi
        fi
    fi

    if [[ $device_count -eq 0 ]]; then
        log_error "No devices configured. Add configs to $CONFIG_DIR/"
        exit 1
    fi

    log_info "Started $device_count device logger(s)"

    while true; do
        for i in "${!CHILD_PIDS[@]}"; do
            pid="${CHILD_PIDS[$i]}"
            if ! kill -0 "$pid" 2>/dev/null; then
                local now elapsed fc backoff
                now=$(date +%s)
                elapsed=$(( now - ${WORKER_START[$i]:-0} ))
                fc=${FAIL_COUNT[$i]:-0}
                (( elapsed >= RESPAWN_RESET )) && fc=0
                fc=$(( fc + 1 ))
                backoff=$(( RESPAWN_BASE * 2 ** (fc - 1) ))
                (( backoff > RESPAWN_MAX )) && backoff=$RESPAWN_MAX
                log_info "Logger for ${DEVICES[$i]} exited (attempt $fc), restarting in ${backoff}s"
                sleep "$backoff"
                log_device_worker "${DEV_NAMES[$i]}" "${DEVICES[$i]}" \
                    "${BAUDS[$i]}" "${LOG_DIRS[$i]}" &
                CHILD_PIDS[$i]=$!
                WORKER_START[$i]=$(date +%s)
                FAIL_COUNT[$i]=0
            fi
        done
        sleep 5
    done
}

main "$@"
