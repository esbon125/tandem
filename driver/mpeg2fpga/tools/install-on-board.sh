#!/bin/sh
# Install the UIO overlay (and optionally the webserver) as systemd units on
# the board, so a reboot comes back with everything in place.
#
# Run this ON the board, from a checkout of driver/mpeg2fpga/tools:
#
#     ./install-on-board.sh                    # driver mode, overlay only
#     ./install-on-board.sh --webserver        # + the demo webserver
#     ./install-on-board.sh --uio              # userspace/UIO mode instead
#
# Idempotent.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
WEBSERVER=${WEBSERVER:-0}
MODE=${MPEG2FPGA_MODE:-driver}
for arg in "$@"; do
	case "$arg" in
		--webserver) WEBSERVER=1 ;;
		--uio)       MODE=uio ;;
		--driver)    MODE=driver ;;
		*) echo "unknown option: $arg" >&2; exit 1 ;;
	esac
done

[ "$(id -u)" = "0" ] || { echo "run as root" >&2; exit 1; }

install -d /etc/mpeg2fpga /usr/local/sbin /etc/systemd/system

# Overlay blobs: prefer a prebuilt .dtbo next to this script, otherwise compile
# the .dts if dtc is available. Install both, so switching modes later is just
# a change of MPEG2FPGA_MODE.
for base in mpeg2fpga mpeg2fpga-uio; do
	if [ -r "$HERE/$base.dtbo" ]; then
		install -m 0644 "$HERE/$base.dtbo" /etc/mpeg2fpga/
	elif command -v dtc >/dev/null 2>&1 && [ -r "$HERE/$base.dts" ]; then
		dtc -@ -I dts -O dtb -o "/etc/mpeg2fpga/$base.dtbo" "$HERE/$base.dts"
	elif [ "$base" = "mpeg2fpga-uio" ]; then
		echo "note: no $base overlay installed; uio mode unavailable" >&2
	else
		echo "no $base.dtbo and no dtc to build one from the .dts" >&2
		exit 1
	fi
done

# driver mode needs the module. Its vermagic has to match the running kernel.
if [ -r "$HERE/mpeg2fpga.ko" ]; then
	install -m 0644 "$HERE/mpeg2fpga.ko" /etc/mpeg2fpga/
elif [ "$MODE" = "driver" ]; then
	echo "driver mode needs mpeg2fpga.ko next to this script" >&2
	exit 1
fi

install -m 0755 "$HERE/mpeg2fpga-overlay.sh" /usr/local/sbin/
install -m 0644 "$HERE/mpeg2fpga-overlay.service" /etc/systemd/system/

# The unit reads the mode from here rather than being edited in place.
printf 'MPEG2FPGA_MODE=%s\n' "$MODE" > /etc/mpeg2fpga/mode.env

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
