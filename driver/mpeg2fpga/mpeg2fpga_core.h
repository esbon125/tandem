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
 * @read: read the 32-bit register at @reg. Below 0x10 this is the decoder's
 *	read-mode bank; 0x10 and up is the APB bridge's own flat map.
 * @write: write @val at @reg. Below 0x10 this is the decoder's write-mode
 *	bank, which is a different set of registers from the read bank at the
 *	same address; 0x10 and up is the bridge's flat map.
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
	/* @sticky: status bits accumulated by mpeg2fpga_core_poll_status().
	 * The status register is read-to-clear, so whoever reads it is the
	 * only one who will ever see those events.
	 */
	u32 sticky;
};

/**
 * struct mpeg2fpga_dma_status - unpacked MPEG2FPGA_B_DMA_STATUS
 * @busy: a transfer is in progress
 * @done: a transfer has completed; sticky, cleared by starting the next one
 * @bytes_done: bytes the engine has handed to the decoder, including the
 *	32-byte sequence_end_code stream_dma appends to every transfer
 */
struct mpeg2fpga_dma_status {
	bool busy;
	bool done;
	u32 bytes_done;
};

/**
 * struct mpeg2fpga_geometry - what the decoder parsed out of the sequence header
 * @width: horizontal_size, in samples
 * @height: vertical_size, in lines
 * @display_width: display_horizontal_size, 0 if the stream has no
 *	sequence_display_extension. It is not required to match @width --
 *	sony-ct1 legitimately declares 120x120 for a 352x224 picture.
 * @display_height: display_vertical_size
 * @frame_rate_code: ISO/IEC 13818-2 table 6-4 code, 0 if none parsed yet
 * @frame_rate_millihz: @frame_rate_code resolved and scaled by the
 *	extension_n/_d fields; 0 for a reserved code
 * @macroblocks_wide: @width rounded up to whole macroblocks
 * @macroblocks_high: @height rounded up to whole macroblocks
 */
struct mpeg2fpga_geometry {
	u16 width;
	u16 height;
	u16 display_width;
	u16 display_height;
	u8 frame_rate_code;
	u32 frame_rate_millihz;
	u16 macroblocks_wide;
	u16 macroblocks_high;
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

/* Read the status register, accumulating its read-to-clear bits into the
 * core's sticky word as well as reporting this read's own contents.
 */
void mpeg2fpga_core_poll_status(struct mpeg2fpga_core *core,
				 struct mpeg2fpga_status *status);
u32 mpeg2fpga_core_get_sticky(struct mpeg2fpga_core *core);
void mpeg2fpga_core_clear_sticky(struct mpeg2fpga_core *core);

/* Core reset gate. The core used to come out of reset on its own, racing the
 * bootloader's MPU configuration; it is now held until software says so.
 */
void mpeg2fpga_core_set_enable(struct mpeg2fpga_core *core, bool enable);
bool mpeg2fpga_core_is_enabled(struct mpeg2fpga_core *core);

/* Stream DMA. Writes address and length before the start bit, which is the
 * order stream_dma.v latches them in.
 */
void mpeg2fpga_core_dma_start(struct mpeg2fpga_core *core, u32 addr, u32 len);
void mpeg2fpga_core_dma_get_status(struct mpeg2fpga_core *core,
				    struct mpeg2fpga_dma_status *status);

void mpeg2fpga_core_get_geometry(struct mpeg2fpga_core *core,
				  struct mpeg2fpga_geometry *geom);
u32 mpeg2fpga_core_frame_rate_millihz(u8 code, u8 extension_n, u8 extension_d);

#endif /* MPEG2FPGA_CORE_H */
