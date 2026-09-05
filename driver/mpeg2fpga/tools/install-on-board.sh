#!/bin/sh
# Install the UIO overlay (and optionally the webserver) as systemd units on
# the board, so a reboot comes back with everything in place.
#
# Run this ON the board, from a checkout of driver/mpeg2fpga/tools:
#
#     ./install-on-board.sh              # overlay only
#     ./install-on-board.sh --webserver  # overlay + the demo webserver
#
# Idempotent.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
WEBSERVER=${WEBSERVER:-0}
[ "${1:-}" = "--webserver" ] && WEBSERVER=1

[ "$(id -u)" = "0" ] || { echo "run as root" >&2; exit 1; }

install -d /etc/mpeg2fpga /usr/local/sbin /etc/systemd/system

# The overlay blob: prefer a prebuilt .dtbo next to this script, otherwise
# compile the .dts if dtc is available.
if [ -r "$HERE/mpeg2fpga-uio.dtbo" ]; then
	install -m 0644 "$HERE/mpeg2fpga-uio.dtbo" /etc/mpeg2fpga/
elif command -v dtc >/dev/null 2>&1; then
	dtc -@ -I dts -O dtb -o /etc/mpeg2fpga/mpeg2fpga-uio.dtbo \
		"$HERE/mpeg2fpga-uio.dts"
else
	echo "no mpeg2fpga-uio.dtbo and no dtc to build one from the .dts" >&2
	exit 1
fi

install -m 0755 "$HERE/mpeg2fpga-overlay.sh" /usr/local/sbin/
install -m 0644 "$HERE/mpeg2fpga-overlay.service" /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now mpeg2fpga-overlay.service
echo "overlay unit enabled; status:"
systemctl --no-pager --lines=5 status mpeg2fpga-overlay.service || true

if [ "$WEBSERVER" = "1" ]; then
	install -m 0644 "$HERE/mpeg2fpga-webserver.service" /etc/systemd/system/
	systemctl daemon-reload
	systemctl enable --now mpeg2fpga-webserver.service
	echo "webserver unit enabled; status:"
	systemctl --no-pager --lines=5 status mpeg2fpga-webserver.service || true
fi
