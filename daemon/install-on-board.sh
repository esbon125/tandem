#!/bin/sh
# Install mpeg2fpgad on the board. Run as root from a copy of daemon/ (and
# api/PROTOCOL-v1.md next to it, optional):
#
#   scp -r daemon api/PROTOCOL-v1.md root@board:/tmp/mpeg2fpgad-src/
#   ssh root@board sh /tmp/mpeg2fpgad-src/daemon/install-on-board.sh [--tls] [--debug]
#
# Needs the driver installed and its overlay unit enabled first
# (driver/mpeg2fpga/tools/install-on-board.sh). Stops the demo webserver,
# which drives the same decoder.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ARGS=""
for a in "$@"; do
    case "$a" in
        --tls)   ARGS="$ARGS --tls" ;;
        --debug) ARGS="$ARGS --enable-debug" ;;
        *) echo "unknown option $a" >&2; exit 1 ;;
    esac
done
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

id mpeg2fpgad >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin mpeg2fpgad
install -d -m 0755 /usr/local/lib/mpeg2fpgad
rm -rf /usr/local/lib/mpeg2fpgad/mpeg2fpgad
cp -r "$HERE/mpeg2fpgad" /usr/local/lib/mpeg2fpgad/
find /usr/local/lib/mpeg2fpgad -name __pycache__ -prune -exec rm -rf {} +
install -m 0755 "$HERE/systemd/mpeg2fpgad-grant-access.sh" /usr/local/lib/mpeg2fpgad/
# C frame conversion (daemon/native, `make` cross-builds it); optional, the
# daemon falls back to Python without it
if [ -r "$HERE/native/riscv64/libm2fconv.so" ]; then
    install -m 0644 "$HERE/native/riscv64/libm2fconv.so" /usr/local/lib/mpeg2fpgad/
else
    echo "note: native/riscv64/libm2fconv.so not built; frame conversion in Python (slower)" >&2
fi
[ -r "$HERE/../PROTOCOL-v1.md" ] && install -m 0644 "$HERE/../PROTOCOL-v1.md" /usr/local/lib/mpeg2fpgad/
install -m 0644 "$HERE/systemd/mpeg2fpgad.service" /etc/systemd/system/
install -d -m 0700 -o mpeg2fpgad -g mpeg2fpgad /etc/mpeg2fpgad
printf 'MPEG2FPGAD_ARGS=%s\n' "$ARGS" > /etc/mpeg2fpgad/mpeg2fpgad.env

# token (and certificate) made now, then handed to the service user (the
# image has no runuser/setpriv to make them as that user directly)
run() { PYTHONPATH=/usr/local/lib/mpeg2fpgad python3 -m mpeg2fpgad "$@"; }
run --show-token >/dev/null
case "$ARGS" in *--tls*) run --show-fingerprint >/dev/null ;; esac
chown -R mpeg2fpgad:mpeg2fpgad /etc/mpeg2fpgad

systemctl disable --now mpeg2fpga-webserver.service 2>/dev/null || true
systemctl daemon-reload
systemctl enable mpeg2fpgad.service
systemctl restart mpeg2fpgad.service
sleep 2
systemctl --no-pager --lines=5 status mpeg2fpgad.service || true
echo
echo "token:       cat /etc/mpeg2fpgad/token"
case "$ARGS" in *--tls*)
    echo "fingerprint: $(run --show-fingerprint)" ;;
esac
