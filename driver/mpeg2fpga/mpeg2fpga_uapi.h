/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
/*
 * Userspace interface of /dev/mpeg2fpga: the picture-ready event stream.
 *
 * read() returns whole struct mpeg2fpga_event records, one per finished
 * picture, in display order -- the order the decoder hands pictures to its
 * display path. The buffer must hold at least one record; read() blocks until
 * one is available (or returns -EAGAIN with O_NONBLOCK), and poll() reports
 * POLLIN while any are queued.
 *
 * Opening the device enables the picture interrupt and closing it disables it
 * again, so the hardware only interrupts while someone is listening. One
 * opener at a time (-EBUSY otherwise): there is one decoder.
 *
 * The layout is fixed, little-endian, 16 bytes; Python reads it with
 * struct.unpack("<QIHBB", ...).
 */
#ifndef MPEG2FPGA_UAPI_H
#define MPEG2FPGA_UAPI_H

#include <linux/types.h>

/* more pictures finished than were reported: the hardware coalesced them
 * (overrun) or the driver's queue was full (lost). Either way the gap shows
 * in @hw_count.
 */
#define MPEG2FPGA_EVENT_OVERRUN	(1 << 0)
#define MPEG2FPGA_EVENT_LOST	(1 << 1)

/**
 * struct mpeg2fpga_event - one finished picture
 * @timestamp_ns: CLOCK_MONOTONIC when the interrupt was handled
 * @seq: driver-side event number since open, starting at 0
 * @hw_count: the hardware's 16-bit picture counter, wraps
 * @frame: frame store buffer (0..3) that holds the picture
 * @flags: MPEG2FPGA_EVENT_*
 */
struct mpeg2fpga_event {
	__u64 timestamp_ns;
	__u32 seq;
	__u16 hw_count;
	__u8 frame;
	__u8 flags;
};

#endif /* MPEG2FPGA_UAPI_H */
