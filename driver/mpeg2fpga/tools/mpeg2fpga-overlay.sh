#!/bin/sh
# Apply the mpeg2fpga UIO device tree overlay.
#
# The overlay lives in configfs, which does not survive a reboot, so until now
# every session on the board began by reapplying it by hand -- and forgetting
# meant the register window simply was not there, which looks like the decoder
# being dead rather than like a missing overlay.
#
# Idempotent: applying it twice is a no-op, so this is safe to run from a
# systemd unit, from a login shell, or after reprogramming the FPGA.
set -eu

NAME=${MPEG2FPGA_OVERLAY_NAME:-mpeg2fpga}
DTBO=${MPEG2FPGA_DTBO:-/etc/mpeg2fpga/mpeg2fpga-uio.dtbo}
CONFIGFS=/sys/kernel/config
OVERLAYS="$CONFIGFS/device-tree/overlays"
UIO_NAME=mpeg2fpga_diag

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

# The point of the overlay is the UIO node; confirm it actually appeared
# rather than trusting "applied".
for dir in /sys/class/uio/uio*; do
	[ -r "$dir/name" ] || continue
	if [ "$(cat "$dir/name")" = "$UIO_NAME" ]; then
		log "$UIO_NAME is /dev/$(basename "$dir")"
		exit 0
	fi
done
die "overlay applied but no UIO device named $UIO_NAME appeared"
