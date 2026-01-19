#!/bin/bash
# ulog installer (for root-only systems)

set -e

cd "$(dirname "$0")"

echo "Installing dependencies..."
pacman -S --needed --noconfirm socat moreutils

echo "Creating ulog user..."
if ! id -u ulog &>/dev/null; then
    useradd -r -s /sbin/nologin -d /nonexistent -c "ulog service account" ulog
fi
usermod -aG dialout ulog

echo "Installing ulog..."
install -Dm755 src/ulog.sh /usr/bin/ulog
install -Dm755 src/ulog-genconfig /usr/bin/ulog-genconfig

# Config file: root owns, ulog group can read (0640)
install -Dm640 -o root -g ulog src/ulog.conf /etc/ulog.conf

install -Dm644 services/ulog-genconfig.path /usr/lib/systemd/system/ulog-genconfig.path
install -Dm644 services/ulog-genconfig.service /usr/lib/systemd/system/ulog-genconfig.service
install -Dm644 services/ulog-rollover.service /usr/lib/systemd/system/ulog-rollover.service
install -Dm644 services/ulog-rollover.timer /usr/lib/systemd/system/ulog-rollover.timer

echo "Generating initial config..."
/usr/bin/ulog-genconfig

echo "Enabling services..."
systemctl enable ulog.service ulog-rollover.timer ulog-genconfig.path

echo ""
echo "Done. ulog installed."
echo "Config: /etc/ulog.conf (root:ulog 0640)"
echo ""
echo "Start now with: systemctl start ulog.service ulog-genconfig.path"
