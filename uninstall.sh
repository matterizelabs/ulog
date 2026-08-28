#!/bin/bash
set -euo pipefail

ULOG_BIN_DIR="${ULOG_BIN_DIR:-/usr/bin}"
ULOG_LIB_DIR="${ULOG_LIB_DIR:-/usr/lib/ulog}"
ULOG_ETC_DIR="${ULOG_ETC_DIR:-/etc}"

red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
info()   { printf '\033[0;34m%s\033[0m\n' "$*"; }
die()    { red "Error: $1"; exit 1; }

[[ $EUID -eq 0 ]] || die "this script must be run as root (use sudo)"

info "Stopping and disabling ulog services..."
systemctl stop ulog.service ulog-rollover.timer ulog-genconfig.path 2>/dev/null || true
systemctl disable ulog.service ulog-rollover.timer ulog-genconfig.path 2>/dev/null || true

info "Removing generated units and udev rules..."
rm -f /usr/lib/systemd/system/ulog.service
rm -f /etc/udev/rules.d/99-ulog.rules
systemctl daemon-reload 2>/dev/null || true
udevadm control --reload-rules 2>/dev/null || true

info "Removing binaries and library..."
rm -f "$ULOG_BIN_DIR/ulog" "$ULOG_BIN_DIR/ulog-genconfig" "$ULOG_BIN_DIR/ulog-export"
rm -f "$ULOG_LIB_DIR/ulog-common.sh"
rmdir "$ULOG_LIB_DIR" 2>/dev/null || true

info "Removing configuration..."
rm -f "$ULOG_ETC_DIR/ulog.conf"
rm -rf "$ULOG_ETC_DIR/ulog.d"

info "Removing runtime state..."
rm -rf /var/lib/ulog

yellow "Log data in /var/log/ulog is preserved. Remove manually if desired:"
yellow "  rm -rf /var/log/ulog"

if id -u ulog &>/dev/null; then
    userdel ulog 2>/dev/null || true
fi

green "ulog uninstalled."
