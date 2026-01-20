# ulog

USB serial port logger with automatic session management for Linux.

## Features

- Logs serial data from USB devices with syslog-style timestamps
- **Multi-device support** - single service handles multiple USB devices
- **Session tracking** - each session gets a unique ID (format: `MMDD-HHMM-xxxx`)
- **USB device identity** - tracks vendor:product:serial to detect device swaps
- **Export tool** - list and export sessions by device, session ID, or USB identity
- Automatic daily log rotation (new folder per day)
- New log file on service restart
- Auto-start on device hotplug
- Config file changes auto-applied (no manual reload needed)
- Security hardened (dedicated user, systemd sandboxing, input validation)

## Supported Systems

Linux distributions with systemd:

| Distribution | Package |
|--------------|---------|
| Arch Linux / Manjaro | AUR |
| Debian 11+ / Ubuntu 20.04+ | `.deb` |
| Fedora / RHEL / CentOS | Manual |
| Other systemd-based | Manual |

**Requirements:** Linux kernel 4.x+, systemd, bash 4.4+

**Not supported:** macOS, Windows, BSD, non-systemd Linux (OpenRC, runit, etc.)

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
sudo dpkg -i ulog_1.1.1_all.deb
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

## Session Management

Each logging session is assigned a unique ID in the format `MMDD-HHMM-xxxx` (e.g., `0120-1830-a1b2`). Sessions are tracked in a `session.index` file per device with start/end times and USB device identity.

### USB Device Identity

ulog tracks the USB vendor ID, product ID, and serial number for each device. This allows:
- Detecting when a different physical device is connected to the same port
- Filtering exports by specific hardware (useful with multiple identical adapters)

Identity format: `vendor:product:serial` (e.g., `10c4:ea60:0001a2b3`)

### List Sessions

```bash
# List all sessions for a device
ulog-export --list --device ttyUSB0

# List sessions from all devices
ulog-export --list --all
```

Output:
```
SESSION            START                  END                       IDENTITY             FILES
====================================================================================================
0120-1830-a1b2     2026-01-20 18:30:00    2026-01-20 19:45:00       10c4:ea60:0001a2b3   2 file(s)
0120-2000-c3d4     2026-01-20 20:00:00    ongoing                   10c4:ea60:0001a2b3   1 file(s)
```

### Export Sessions

```bash
# Export specific session
ulog-export --session 0120-1830-a1b2 --device ttyUSB0 --output session.log

# Export latest/current session
ulog-export --device ttyUSB0 --output latest.log

# Export multiple sessions combined
ulog-export --session 0120-1830-a1b2,0120-2000-c3d4 --device ttyUSB0 --output combined.log
```

### Filter by USB Identity

```bash
# Export all sessions from Silicon Labs adapters (vendor 10c4)
ulog-export --vendor 10c4 --output silabs.log

# Export from specific vendor and product (CP210x)
ulog-export --vendor 10c4 --product ea60 --output cp210x.log

# Export from specific physical device (by serial, prefix match)
ulog-export --vendor 10c4 --product ea60 --serial 0001a2b3 --output device1.log
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
    session.index         # Session tracking database
    2026-01-18/
      2026-01-18_14-30-00.log
    2026-01-19/
      2026-01-19_00-00-01.log
  ttyUSB1/
    session.index
    2026-01-18/
      2026-01-18_14-30-00.log
  ttyACM0/
    ...

/var/lib/ulog/
  sessions/               # Runtime state
    ttyUSB0.session       # Current session ID
    ttyUSB0.identity      # Last known USB identity
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
    ulog-export           # Session export/list tool
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
