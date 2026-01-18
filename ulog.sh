#!/bin/bash
# ulog - USB serial logger

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ulog.conf}"

# Load config
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Defaults
DEVICE="${DEVICE:-/dev/ttyUSB0}"
BAUD="${BAUD:-115200}"
LOG_DIR="${LOG_DIR:-/var/log/ttyUSB0}"

# Create today's directory
TODAY=$(date +%Y-%m-%d)
mkdir -p "$LOG_DIR/$TODAY"

# Log file with timestamp
LOGFILE="$LOG_DIR/$TODAY/$(date +%Y-%m-%d_%H-%M-%S).log"

echo "ulog: logging $DEVICE ($BAUD baud) to $LOGFILE"

# Start logging with socat and timestamp prepending
exec socat -u "$DEVICE,b$BAUD,raw,echo=0,crtscts=0,clocal=1" STDOUT | ts '%b %d %H:%M:%S' >> "$LOGFILE"
