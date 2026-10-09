#!/bin/sh
# Run as root by mpeg2fpgad.service (ExecStartPre=+) right before the daemon
# starts as the unprivileged mpeg2fpgad user: give its group exactly what
# board.py touches, nothing more (api/PROTOCOL-v1.md section 6.3). Done at
# every start because the driver's sysfs files and the device nodes are
# recreated whenever the overlay is (re)applied.
set -eu
GROUP=mpeg2fpgad
grant() { chgrp "$GROUP" "$@" && chmod g+rw "$@"; }

grant /dev/mpeg2fpga /dev/udmabuf-ddr-c0 /dev/udmabuf-ddr-nc0
grant /sys/class/u-dma-buf/udmabuf-ddr-c0/sync_offset \
      /sys/class/u-dma-buf/udmabuf-ddr-c0/sync_size \
      /sys/class/u-dma-buf/udmabuf-ddr-c0/sync_for_device
for dev in /sys/bus/platform/drivers/mpeg2fpga/*.mpeg2fpga; do
    for attr in enable status dma_addr dma_len dma_start freeze source_select flush_vbuf; do
        grant "$dev/$attr"
    done
done
