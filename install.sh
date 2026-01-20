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

# Add ulog to serial port groups (varies by distro)
# Arch: uucp, Debian/Ubuntu: dialout
for group in uucp dialout tty; do
    if getent group "$group" &>/dev/null; then
        usermod -aG "$group" ulog
        echo "Added ulog to group: $group"
    fi
done

echo "Installing ulog..."
install -Dm755 src/ulog.sh /usr/bin/ulog
install -Dm755 src/ulog-genconfig /usr/bin/ulog-genconfig

# Config file: root owns, ulog group can read (0640)
install -Dm640 -o root -g ulog src/ulog.conf /etc/ulog.conf

# Create config directory for multi-device support
install -dm750 -o root -g ulog /etc/ulog.d

# Install example device config
if [[ ! -f /etc/ulog.d/ttyUSB0.conf ]]; then
    cat > /etc/ulog.d/ttyUSB0.conf << 'EOF'
# Device configuration for ttyUSB0
DEVICE=/dev/ttyUSB0
BAUD=115200
# LOG_DIR=/var/log/ulog/ttyUSB0  # Optional, auto-generated if not set
EOF
    chown root:ulog /etc/ulog.d/ttyUSB0.conf
    chmod 0640 /etc/ulog.d/ttyUSB0.conf
fi

install -Dm644 services/ulog-genconfig.path /usr/lib/systemd/system/ulog-genconfig.path
install -Dm644 services/ulog-genconfig.service /usr/lib/systemd/system/ulog-genconfig.service
install -Dm644 services/ulog-rollover.service /usr/lib/systemd/system/ulog-rollover.service
install -Dm644 services/ulog-rollover.timer /usr/lib/systemd/system/ulog-rollover.timer

# Create base log directory
install -dm750 -o ulog -g ulog /var/log/ulog

echo "Generating initial config..."
/usr/bin/ulog-genconfig

echo "Enabling services..."
systemctl enable ulog.service ulog-rollover.timer ulog-genconfig.path

echo ""
echo "Done. ulog installed."
echo ""
echo "Config:"
echo "  Global defaults: /etc/ulog.conf"
echo "  Device configs:  /etc/ulog.d/*.conf"
echo ""
echo "To add a device, create /etc/ulog.d/<name>.conf with:"
echo "  DEVICE=/dev/ttyUSBx"
echo "  BAUD=115200"
echo ""
echo "Start now with: systemctl start ulog.service ulog-genconfig.path"
