# Contributing to ulog

## Reporting Issues

- Check existing issues before creating a new one
- Include your OS, systemd version, and device details
- Provide relevant logs from `journalctl -u ulog.service`

## Development Setup

```bash
git clone https://github.com/matterizelabs/ulog.git
cd ulog

# Install dependencies
sudo pacman -S socat moreutils  # Arch
sudo apt install socat moreutils  # Debian/Ubuntu

# Test locally
sudo ./install.sh
```

## Making Changes

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-change`
3. Make your changes
4. Test with a real serial device if possible
5. Commit with a clear message
6. Push and open a pull request

## Code Style

- Use bash for scripts (shellcheck compliant)
- Use tabs for indentation in shell scripts
- Keep systemd units minimal and well-commented

## Testing

Before submitting:

```bash
# Check shell scripts
shellcheck ulog.sh ulog-genconfig install.sh

# Verify systemd units
systemd-analyze verify ulog.service
systemd-analyze verify ulog-genconfig.path
systemd-analyze verify ulog-rollover.timer
```

## Pull Requests

- Keep changes focused and minimal
- Update README.md if adding features
- Update version in PKGBUILD, debian/changelog, and .SRCINFO for releases

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
