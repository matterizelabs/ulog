# ulog

USB serial port logger with automatic session management for Linux.

## Features

- Logs serial data from USB devices with syslog-style timestamps
- **Multi-device support** - single service handles multiple USB devices
- Automatic daily log rotation (new folder per day)
- New log file on service restart
- Auto-start on device hotplug
- Config file changes auto-applied (no manual reload needed)
- Security hardened (dedicated user, systemd sandboxing, input validation)

## Installation

### Arch Linux (AUR)

```bash
yay -S ulog
```

Or manually:

```bash
git clone https://github.com/matterizelabs/ulog.git
cd ulog/packaging/arch
makepkg -si
```

### Debian/Ubuntu

Download from [releases](https://github.com/matterizelabs/ulog/releases):

```bash
sudo dpkg -i ulog_1.1.0_all.deb
```

### Manual (root-only systems)

```bash
git clone https://github.com/matterizelabs/ulog.git
cd ulog
./install.sh
```

## Configuration

### Single Device (Simple)

Edit `/etc/ulog.conf`:

```bash
DEVICE=/dev/ttyUSB0
BAUD=115200
LOG_DIR=/var/log/ulog/ttyUSB0
```

### Multiple Devices

Create a config file per device in `/etc/ulog.d/`:

```bash
# /etc/ulog.d/sensor1.conf
DEVICE=/dev/ttyUSB0
BAUD=115200

# /etc/ulog.d/sensor2.conf
DEVICE=/dev/ttyUSB1
BAUD=9600

# /etc/ulog.d/gps.conf
DEVICE=/dev/ttyACM0
BAUD=38400
```

Each device gets its own log directory: `/var/log/ulog/<device_name>/`

Changes are auto-applied when config files are saved.

## Usage

Enable and start:

```bash
systemctl enable --now ulog.service ulog-rollover.timer ulog-genconfig.path
```

View logs:

```bash
# Single device
tail -f /var/log/ulog/ttyUSB0/$(date +%Y-%m-%d)/*.log

# All devices
tail -f /var/log/ulog/*/$(date +%Y-%m-%d)/*.log
```

Check status:

```bash
systemctl status ulog.service
journalctl -u ulog.service -f
```

Add a new device:

```bash
cat > /etc/ulog.d/mydevice.conf << EOF
DEVICE=/dev/ttyUSB2
BAUD=115200
EOF
chown root:ulog /etc/ulog.d/mydevice.conf
chmod 0640 /etc/ulog.d/mydevice.conf
# Service auto-restarts to pick up new device
```

## Log Format

Logs use syslog-style timestamps:

```
Jan 18 14:30:00 sensor reading: 42.5
Jan 18 14:30:01 sensor reading: 43.1
```

## Log Directory Structure

```
/var/log/ulog/
  ttyUSB0/
    2026-01-18/
      2026-01-18_14-30-00.log
    2026-01-19/
      2026-01-19_00-00-01.log
  ttyUSB1/
    2026-01-18/
      2026-01-18_14-30-00.log
  ttyACM0/
    ...
```

## Configuration Reference

| Key | Description | Default |
|-----|-------------|---------|
| `DEVICE` | Serial device path | `/dev/ttyUSB0` |
| `BAUD` | Baud rate (300-921600) | `115200` |
| `LOG_DIR` | Log directory (must be under /var/log/) | `/var/log/ulog/<device>` |

Valid baud rates: 300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600

## Project Structure

```
ulog/
  src/                    # Source files
    ulog.sh               # Main logger script (multi-device)
    ulog-genconfig        # Config generator
    ulog.conf             # Default configuration
  services/               # Systemd units
    ulog-genconfig.path   # Watch config for changes
    ulog-genconfig.service
    ulog-rollover.service
    ulog-rollover.timer
  packaging/              # Distribution packages
    arch/                 # Arch Linux (AUR)
    debian/               # Debian/Ubuntu
```

## Security

- Runs as dedicated `ulog` user (not root)
- Systemd sandboxing (ProtectSystem, PrivateTmp, NoNewPrivileges)
- Input validation on all config values
- Config files must be root-owned (0640)
- Device paths strictly validated
- See [SECURITY.md](SECURITY.md) for details

## Dependencies

- socat
- moreutils (provides `ts`)
- coreutils (provides `realpath`)

## License

MIT
