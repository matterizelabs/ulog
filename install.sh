#!/bin/bash
set -euo pipefail

ULOG_BIN_DIR="${ULOG_BIN_DIR:-/usr/bin}"
ULOG_LIB_DIR="${ULOG_LIB_DIR:-/usr/lib/ulog}"
ULOG_ETC_DIR="${ULOG_ETC_DIR:-/etc}"
ULOG_CHECKSUMS="${ULOG_CHECKSUMS:-}"

red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
info()   { printf '\033[0;34m%s\033[0m\n' "$*"; }
die()    { red "Error: $1"; exit 1; }

_ulog_sha256() {
    if command -v sha256sum &>/dev/null; then sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum &>/dev/null; then shasum -a 256 "$1" | cut -d' ' -f1
    elif command -v openssl &>/dev/null; then openssl dgst -sha256 "$1" | awk '{print $NF}'
    else echo ""
    fi
}

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ $EUID -eq 0 ]] || die "this script must be run as root (use sudo)"
command -v systemctl &>/dev/null || die "systemd is required"
for c in socat ts realpath; do
    command -v "$c" &>/dev/null || die "$c is required (install socat and moreutils)"
done

if [[ -n "$ULOG_CHECKSUMS" ]]; then
    sha256sum -c "$ULOG_CHECKSUMS" || die "checksum verification failed"
    green "checksum verification passed"
fi

info "Installing ulog..."

if ! id -u ulog &>/dev/null; then
    useradd -r -s /sbin/nologin -d /nonexistent -c "ulog service account" ulog
fi
for group in uucp dialout tty; do
    if getent group "$group" &>/dev/null; then
        usermod -aG "$group" ulog
    fi
done

install -Dm755 "$SRC_DIR/src/ulog.sh" "$ULOG_BIN_DIR/ulog"
install -Dm755 "$SRC_DIR/src/ulog-genconfig" "$ULOG_BIN_DIR/ulog-genconfig"
install -Dm755 "$SRC_DIR/src/ulog-export" "$ULOG_BIN_DIR/ulog-export"
install -Dm644 "$SRC_DIR/src/ulog-common.sh" "$ULOG_LIB_DIR/ulog-common.sh"

install -Dm640 -o root -g ulog "$SRC_DIR/src/ulog.conf" "$ULOG_ETC_DIR/ulog.conf"
install -dm750 -o root -g ulog "$ULOG_ETC_DIR/ulog.d"

if [[ ! -f "$ULOG_ETC_DIR/ulog.d/ttyUSB0.conf" ]]; then
    cat > "$ULOG_ETC_DIR/ulog.d/ttyUSB0.conf" <<EOF
# Device configuration for ttyUSB0
DEVICE=/dev/ttyUSB0
BAUD=115200
# LOG_DIR=/var/log/ulog/ttyUSB0  # Optional, auto-generated if not set
EOF
    chown root:ulog "$ULOG_ETC_DIR/ulog.d/ttyUSB0.conf"
    chmod 0640 "$ULOG_ETC_DIR/ulog.d/ttyUSB0.conf"
fi

install -Dm644 "$SRC_DIR/services/ulog-genconfig.path" /usr/lib/systemd/system/ulog-genconfig.path
install -Dm644 "$SRC_DIR/services/ulog-genconfig.service" /usr/lib/systemd/system/ulog-genconfig.service
install -Dm644 "$SRC_DIR/services/ulog-rollover.service" /usr/lib/systemd/system/ulog-rollover.service
install -Dm644 "$SRC_DIR/services/ulog-rollover.timer" /usr/lib/systemd/system/ulog-rollover.timer

install -dm750 -o ulog -g ulog /var/log/ulog
install -dm750 -o ulog -g ulog /var/lib/ulog
install -dm750 -o ulog -g ulog /var/lib/ulog/sessions

info "Generating systemd service and udev rules..."
ULOG_ETC_DIR="$ULOG_ETC_DIR" "$ULOG_BIN_DIR/ulog-genconfig"

systemctl daemon-reload
udevadm control --reload-rules

systemctl enable ulog.service ulog-rollover.timer ulog-genconfig.path

echo
green "ulog installed."
echo
info "Config: /etc/ulog.conf or /etc/ulog.d/*.conf (root:ulog 0640)"
info "Start:   systemctl start ulog.service ulog-genconfig.path"
