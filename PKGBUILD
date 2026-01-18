# Maintainer: Your Name <your@email.com>
pkgname=ulog
pkgver=1.0.0
pkgrel=1
pkgdesc="USB serial port logger with automatic session management"
arch=('any')
license=('MIT')
depends=('socat' 'moreutils')
backup=('etc/ulog.conf')
install=ulog.install

source=(
    'ulog.sh'
    'ulog.conf'
    'ulog-genconfig'
    'ulog-genconfig.path'
    'ulog-genconfig.service'
    'ulog-rollover.service'
    'ulog-rollover.timer'
)

sha256sums=('SKIP' 'SKIP' 'SKIP' 'SKIP' 'SKIP' 'SKIP' 'SKIP')

package() {
    install -Dm755 ulog.sh "$pkgdir/usr/bin/ulog"
    install -Dm755 ulog-genconfig "$pkgdir/usr/bin/ulog-genconfig"
    install -Dm644 ulog.conf "$pkgdir/etc/ulog.conf"
    install -Dm644 ulog-genconfig.path "$pkgdir/usr/lib/systemd/system/ulog-genconfig.path"
    install -Dm644 ulog-genconfig.service "$pkgdir/usr/lib/systemd/system/ulog-genconfig.service"
    install -Dm644 ulog-rollover.service "$pkgdir/usr/lib/systemd/system/ulog-rollover.service"
    install -Dm644 ulog-rollover.timer "$pkgdir/usr/lib/systemd/system/ulog-rollover.timer"
}
