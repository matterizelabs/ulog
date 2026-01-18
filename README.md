# ulog

USB serial port logger with automatic session management for Linux.

## Features

- Logs serial data from USB devices with syslog-style timestamps
- Automatic daily log rotation (new folder per day)
- New log file on service restart
- Auto-start on device hotplug
- Config file changes auto-applied (no manual reload needed)

## Installation

### Arch Linux (AUR)

```bash
yay -S ulog
```

Or manually:

```bash
git clone https://github.com/matterizelabs/ulog.git
cd ulog
makepkg -si
```

### Debian/Ubuntu

```bash
sudo dpkg -i ulog_1.0.0_all.deb
```

### Manual (root-only systems)

```bash
./install.sh
```

## Configuration

Edit `/etc/ulog.conf`:

```bash
# Serial device
DEVICE=/dev/ttyUSB0

# Baud rate
BAUD=115200

# Log directory
LOG_DIR=/var/log/ttyUSB0
```

Changes are auto-applied when the file is saved.

## Usage

Enable and start:

```bash
systemctl enable --now ulog.service ulog-rollover.timer ulog-genconfig.path
```

View logs:

```bash
tail -f /var/log/ttyUSB0/$(date +%Y-%m-%d)/*.log
```

Check status:

```bash
systemctl status ulog.service
```

## Log Format

Logs use syslog-style timestamps:

```
Jan 18 14:30:00 sensor reading: 42.5
Jan 18 14:30:01 sensor reading: 43.1
```

## Directory Structure

```
/var/log/ttyUSB0/
  2026-01-18/
    2026-01-18_14-30-00.log
    2026-01-18_15-45-30.log
  2026-01-19/
    2026-01-19_00-00-01.log
```

## Dependencies

- socat
- moreutils (provides `ts`)

## License

MIT
