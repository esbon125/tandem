#!/bin/sh
# Apply the mpeg2fpga device tree overlay, and in driver mode load the module.
#
# The overlay lives in configfs, which does not survive a reboot, so until now
# every session on the board began by reapplying it by hand -- and forgetting
# meant the register window simply was not there, which looks like the decoder
# being dead rather than like a missing overlay.
#
# Two modes, because the two overlays are mutually exclusive: both describe the
# register window at 0x40000400, so whichever driver probes second cannot claim
# it.
#
#   driver (default)  the kernel driver owns the decoder; registers and IRQ are
#                     reached through its sysfs attributes under
#                     /sys/bus/platform/devices/*.mpeg2fpga
#   uio               userspace owns it, through /dev/uioN
#
# The webserver prefers the driver and falls back to UIO, so either works.
#
# Idempotent: applying it twice is a no-op, so this is safe to run from a
# systemd unit, from a login shell, or after reprogramming the FPGA.
set -eu

MODE=${MPEG2FPGA_MODE:-driver}
NAME=${MPEG2FPGA_OVERLAY_NAME:-mpeg2fpga}
CONFIGFS=/sys/kernel/config
OVERLAYS="$CONFIGFS/device-tree/overlays"
UIO_NAME=mpeg2fpga_diag
MODULE=${MPEG2FPGA_MODULE:-/etc/mpeg2fpga/mpeg2fpga.ko}

case "$MODE" in
	driver) DTBO=${MPEG2FPGA_DTBO:-/etc/mpeg2fpga/mpeg2fpga.dtbo} ;;
	uio)    DTBO=${MPEG2FPGA_DTBO:-/etc/mpeg2fpga/mpeg2fpga-uio.dtbo} ;;
	*)      echo "MPEG2FPGA_MODE must be driver or uio" >&2; exit 1 ;;
esac

log() { echo "mpeg2fpga-overlay: $*"; }
die() { log "$*" >&2; exit 1; }

[ -r "$DTBO" ] || die "no overlay blob at $DTBO"

# CONFIGFS_FS is usually mounted by systemd already; mount it if not.
if [ ! -d "$OVERLAYS" ]; then
	mountpoint -q "$CONFIGFS" 2>/dev/null || mount -t configfs none "$CONFIGFS" ||
		die "cannot mount configfs at $CONFIGFS"
fi
[ -d "$OVERLAYS" ] || die "no overlay directory at $OVERLAYS -- kernel built without CONFIG_OF_OVERLAY?"

if [ -d "$OVERLAYS/$NAME" ]; then
	log "overlay '$NAME' already present (status: $(cat "$OVERLAYS/$NAME/status" 2>/dev/null || echo unknown))"
else
	mkdir "$OVERLAYS/$NAME"
	# A rejected blob leaves the directory behind with status "unapplied";
	# clean it up so a retry is not blocked by the previous failure.
	if ! cat "$DTBO" > "$OVERLAYS/$NAME/dtbo" 2>/dev/null; then
		rmdir "$OVERLAYS/$NAME" 2>/dev/null || true
		die "kernel rejected $DTBO"
	fi
	status=$(cat "$OVERLAYS/$NAME/status" 2>/dev/null || echo unknown)
	[ "$status" = "applied" ] || die "overlay status is '$status', expected 'applied'"
	log "applied $DTBO as '$NAME'"
fi

# "applied" only means the kernel accepted the blob. Confirm the thing the
# overlay exists for actually showed up.
if [ "$MODE" = "uio" ]; then
	for dir in /sys/class/uio/uio*; do
		[ -r "$dir/name" ] || continue
		if [ "$(cat "$dir/name")" = "$UIO_NAME" ]; then
			log "$UIO_NAME is /dev/$(basename "$dir")"
			exit 0
		fi
	done
	die "overlay applied but no UIO device named $UIO_NAME appeared"
fi

# driver mode: the platform device needs the module bound to it before any
# sysfs attribute exists.
if [ -r "$MODULE" ] && ! lsmod | grep -q '^mpeg2fpga '; then
	insmod "$MODULE" || die "insmod $MODULE failed"
fi

for dir in /sys/bus/platform/devices/*.mpeg2fpga; do
	if [ -r "$dir/version" ]; then
		log "driver bound at $(basename "$dir"), hw version $(cat "$dir/version")"
		exit 0
	fi
done
die "overlay applied but the driver did not bind -- is $MODULE built for $(uname -r)?"
