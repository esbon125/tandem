/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Hardware-independent logic for the mpeg2fpga register interface:
 * status parsing, IRQ enable-mask shadowing, watchdog configuration.
 *
 * Kept free of any platform_device/ioremap dependency so it can be
 * exercised by KUnit on a fake in-memory register backend, and reused
 * as-is by the real platform driver (mpeg2fpga_platform.c).
 */

#ifndef MPEG2FPGA_CORE_H
#define MPEG2FPGA_CORE_H

#include <linux/bitops.h>
#include <linux/types.h>

/**
 * struct mpeg2fpga_regops - register access callbacks
 * @read: read the 32-bit read-mode register at @reg (0x0-0xf)
 * @write: write @val to the 32-bit write-mode register at @reg (0x0-0xf)
 * @ctx: opaque context passed back to @read/@write (e.g. an ioremap'd
 *	base pointer for the real driver, or a fake register array in tests)
 */
struct mpeg2fpga_regops {
	u32 (*read)(void *ctx, unsigned int reg);
	void (*write)(void *ctx, unsigned int reg, u32 val);
	void *ctx;
};

/**
 * struct mpeg2fpga_status - parsed contents of the status register
 *
 * Fields mirror the read-to-clear bits of MPEG2FPGA_R_STATUS; reading the
 * register (via mpeg2fpga_core_read_status()) clears them in hardware.
 */
struct mpeg2fpga_status {
	u8 matrix_coefficients;
	bool watchdog_status;
	bool osd_wr_en;
	bool osd_wr_ack;
	bool osd_wr_full;
	bool picture_hdr;
	bool frame_end;
	bool video_ch;
	bool error;
};

/* IRQ source mask bits, used with mpeg2fpga_core_set_irq_mask()/get_irq_mask() */
#define MPEG2FPGA_IRQ_PICTURE_HDR	BIT(0)
#define MPEG2FPGA_IRQ_FRAME_END	BIT(1)
#define MPEG2FPGA_IRQ_VIDEO_CH		BIT(2)
#define MPEG2FPGA_IRQ_ALL		(MPEG2FPGA_IRQ_PICTURE_HDR | \
					 MPEG2FPGA_IRQ_FRAME_END | \
					 MPEG2FPGA_IRQ_VIDEO_CH)

/**
 * struct mpeg2fpga_core - driver-side state
 * @ops: register access callbacks
 * @stream_shadow: last value written to MPEG2FPGA_W_STREAM (reg 0); the
 *	write-mode bank has no readback, so individual bits (watchdog
 *	interval, osd_enable, the three *_intr_en bits) can only be changed
 *	correctly via read-modify-write against this shadow.
 */
struct mpeg2fpga_core {
	const struct mpeg2fpga_regops *ops;
	u32 stream_shadow;
};

void mpeg2fpga_core_init(struct mpeg2fpga_core *core,
			  const struct mpeg2fpga_regops *ops);

u16 mpeg2fpga_core_get_version(struct mpeg2fpga_core *core);

void mpeg2fpga_core_read_status(struct mpeg2fpga_core *core,
				 struct mpeg2fpga_status *status);

void mpeg2fpga_core_set_irq_mask(struct mpeg2fpga_core *core, u32 mask);
u32 mpeg2fpga_core_get_irq_mask(struct mpeg2fpga_core *core);

void mpeg2fpga_core_set_osd_enable(struct mpeg2fpga_core *core, bool enable);

void mpeg2fpga_core_set_watchdog_interval(struct mpeg2fpga_core *core,
					   u8 interval);
void mpeg2fpga_core_watchdog_disable(struct mpeg2fpga_core *core);

#endif /* MPEG2FPGA_CORE_H */
