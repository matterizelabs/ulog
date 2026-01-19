# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.1.x   | Yes                |
| 1.0.x   | No (critical vulnerabilities) |

## Reporting a Vulnerability

If you discover a security vulnerability in ulog, please report it responsibly:

1. **Do not** open a public GitHub issue
2. Email: abu@matterize.io
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

We will respond within 48 hours and work with you to understand and address the issue.

## Security Model

### Threat Model

ulog is designed for logging serial data from USB devices in trusted environments. The security model assumes:

- The system administrator controls `/etc/ulog.conf`
- The USB device is trusted
- Local users may be untrusted

### Trust Boundaries

| Component | Trust Level |
|-----------|-------------|
| `/etc/ulog.conf` | Root-only write, ulog group read |
| `/usr/bin/ulog` | Runs as `ulog` user |
| `/usr/bin/ulog-genconfig` | Runs as root |
| `/var/log/ttyUSB0/` | Owned by `ulog` user |
| Serial device | Trusted input |

## Security Measures

### Input Validation

All configuration values are strictly validated:

- **DEVICE**: Must match `^/dev/tty[A-Za-z]+[0-9]*$`
- **BAUD**: Must be numeric and in whitelist (300-921600)
- **LOG_DIR**: Must be under `/var/log/`, no path traversal

### Privilege Separation

- Service runs as dedicated `ulog` user (not root)
- `ulog` user is in `dialout` group for serial access
- Config file owned by root, readable by ulog group

### Systemd Hardening

The generated service includes:

```ini
User=ulog
Group=ulog
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
CapabilityBoundingSet=
PrivateDevices=no
DeviceAllow=/dev/ttyUSB0 rw
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
MemoryDenyWriteExecute=yes
RestrictAddressFamilies=AF_UNIX
LockPersonality=yes
```

### Safe Configuration Parsing

Configuration files are parsed safely without shell execution:

- No `source` or `eval` of config files
- Key-value parsing with strict validation
- Unknown keys are rejected

### File System Protection

- Log files created with `0640` permissions
- Symlink attacks prevented by checking before creation
- Atomic file writes for config generation
- Path traversal blocked

## Known Limitations

1. **Serial data is not encrypted**: Data is logged as-is from the device
2. **No authentication**: Anyone with access to logs can read them
3. **Device trust**: Malicious USB devices could send crafted data

## Security Changelog

### v1.1.0 (Security Release)

- Fixed: Arbitrary code execution via config sourcing (VULN-001)
- Fixed: Command injection via DEVICE parameter (VULN-002)
- Fixed: Command injection via BAUD parameter (VULN-003)
- Fixed: Path traversal via LOG_DIR (VULN-004)
- Fixed: Udev rule injection (VULN-005)
- Fixed: Environment variable config override (VULN-006)
- Added: Comprehensive systemd hardening (VULN-007)
- Fixed: Symlink attacks on log files (VULN-009)
- Fixed: Non-atomic config writes (VULN-010)
- Added: Dedicated service user

### v1.0.0

- Initial release (contains critical vulnerabilities - do not use)

## Security Audit

A full security audit was performed on v1.0.0, identifying 10 vulnerabilities. All critical and high severity issues have been addressed in v1.1.0.

The full vulnerability report is available in `ulog-vuln.md`.
