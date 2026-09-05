/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Register map for the mpeg2fpga MPEG-2 decoder core.
 *
 * Source: trunk/mpeg2fpga/doc/mpeg2fpga.txt, chapter 1 (hardware_development
 * branch). The processor interface is two independent banks of 16 32-bit
 * registers sharing the same 4-bit address bus, selected by reg_wr_en vs.
 * reg_rd_en: reading address N and writing address N access unrelated
 * registers. The write-mode bank has no readback path, so software must
 * shadow what it last wrote (see mpeg2fpga_core.c).
 */

#ifndef MPEG2FPGA_REGS_H
#define MPEG2FPGA_REGS_H

/* Read-mode register addresses (doc table 1.4) */
#define MPEG2FPGA_R_VERSION		0x0
#define MPEG2FPGA_R_STATUS		0x1
#define MPEG2FPGA_R_SIZE		0x2
#define MPEG2FPGA_R_DISPLAY_SIZE	0x3
#define MPEG2FPGA_R_FRAME_RATE		0x4
#define MPEG2FPGA_R_TESTPOINT		0xf

/* status (reg 1, read-mode): bits 15-8 matrix_coefficients, 7 watchdog_status,
 * 6 osd_wr_en, 5 osd_wr_ack, 4 osd_wr_full, 3 picture_hdr, 2 frame_end,
 * 1 video_ch, 0 error. All bits below matrix_coefficients are read-to-clear:
 * reading MPEG2FPGA_R_STATUS clears them in hardware.
 */
#define MPEG2FPGA_STATUS_MATRIX_COEFFICIENTS_SHIFT	8
#define MPEG2FPGA_STATUS_MATRIX_COEFFICIENTS_MASK	GENMASK(15, 8)
#define MPEG2FPGA_STATUS_WATCHDOG_STATUS	BIT(7)
#define MPEG2FPGA_STATUS_OSD_WR_EN		BIT(6)
#define MPEG2FPGA_STATUS_OSD_WR_ACK		BIT(5)
#define MPEG2FPGA_STATUS_OSD_WR_FULL		BIT(4)
#define MPEG2FPGA_STATUS_PICTURE_HDR		BIT(3)
#define MPEG2FPGA_STATUS_FRAME_END		BIT(2)
#define MPEG2FPGA_STATUS_VIDEO_CH		BIT(1)
#define MPEG2FPGA_STATUS_ERROR			BIT(0)

/* size (reg 2, read-mode): 29-16 horizontal_size, 13-0 vertical_size */
#define MPEG2FPGA_SIZE_HORIZONTAL_SHIFT	16
#define MPEG2FPGA_SIZE_HORIZONTAL_MASK		GENMASK(29, 16)
#define MPEG2FPGA_SIZE_VERTICAL_MASK		GENMASK(13, 0)

/* display size (reg 3, read-mode): same layout as size */
#define MPEG2FPGA_DISPLAY_SIZE_HORIZONTAL_SHIFT	16
#define MPEG2FPGA_DISPLAY_SIZE_HORIZONTAL_MASK		GENMASK(29, 16)
#define MPEG2FPGA_DISPLAY_SIZE_VERTICAL_MASK		GENMASK(13, 0)

/* frame rate (reg 4, read-mode) */
#define MPEG2FPGA_FRAME_RATE_ASPECT_RATIO_SHIFT	12
#define MPEG2FPGA_FRAME_RATE_ASPECT_RATIO_MASK		GENMASK(15, 12)
#define MPEG2FPGA_FRAME_RATE_PROGRESSIVE_SEQUENCE	BIT(11)
#define MPEG2FPGA_FRAME_RATE_EXTENSION_D_SHIFT		6
#define MPEG2FPGA_FRAME_RATE_EXTENSION_D_MASK		GENMASK(10, 6)
#define MPEG2FPGA_FRAME_RATE_EXTENSION_N_SHIFT		4
#define MPEG2FPGA_FRAME_RATE_EXTENSION_N_MASK		GENMASK(5, 4)
#define MPEG2FPGA_FRAME_RATE_CODE_MASK			GENMASK(3, 0)

/* Write-mode register addresses (doc table 1.5) */
#define MPEG2FPGA_W_STREAM		0x0
#define MPEG2FPGA_W_HORIZONTAL		0x1
#define MPEG2FPGA_W_HORIZONTAL_SYNC	0x2
#define MPEG2FPGA_W_VERTICAL		0x3
#define MPEG2FPGA_W_VERTICAL_SYNC	0x4
#define MPEG2FPGA_W_VIDEO_MODE		0x5
#define MPEG2FPGA_W_OSD_CLT_YUVM	0x6
#define MPEG2FPGA_W_OSD_CLT_ADDR	0x7
#define MPEG2FPGA_W_OSD_DTA_HIGH	0x8
#define MPEG2FPGA_W_OSD_DTA_LOW		0x9
#define MPEG2FPGA_W_OSD_ADDR		0xa
#define MPEG2FPGA_W_TRICK_MODE		0xb
#define MPEG2FPGA_W_TESTPOINT		0xf

/* stream (reg 0, write-mode): 15-8 watchdog_interval, 3 osd_enable,
 * 2 picture_hdr_intr_en, 1 frame_end_intr_en, 0 video_ch_intr_en.
 * Write-only: there is no read-mode register 0 that echoes this bank
 * (read-mode reg 0 is "version"), so software must shadow the last
 * written value to do read-modify-write of individual bits.
 */
#define MPEG2FPGA_STREAM_WATCHDOG_INTERVAL_SHIFT	8
#define MPEG2FPGA_STREAM_WATCHDOG_INTERVAL_MASK	GENMASK(15, 8)
#define MPEG2FPGA_STREAM_OSD_ENABLE		BIT(3)
#define MPEG2FPGA_STREAM_PICTURE_HDR_INTR_EN	BIT(2)
#define MPEG2FPGA_STREAM_FRAME_END_INTR_EN	BIT(1)
#define MPEG2FPGA_STREAM_VIDEO_CH_INTR_EN	BIT(0)

/* watchdog_interval semantics (doc sec. 1.10) */
#define MPEG2FPGA_WATCHDOG_EXPIRE_IMMEDIATELY	0
#define MPEG2FPGA_WATCHDOG_DEFAULT_INTERVAL	127
#define MPEG2FPGA_WATCHDOG_DISABLED		255

/* trick mode (reg b, write-mode): bit 9-5 repeat_frame, used together with
 * watchdog_interval to compute the watchdog timeout:
 *   timeout = (watchdog_interval + 1) * (repeat_frame + 1) * 2^18 clk cycles
 */
#define MPEG2FPGA_TRICK_MODE_DEINTERLACE	BIT(10)
#define MPEG2FPGA_TRICK_MODE_REPEAT_FRAME_SHIFT	5
#define MPEG2FPGA_TRICK_MODE_REPEAT_FRAME_MASK		GENMASK(9, 5)
#define MPEG2FPGA_TRICK_MODE_PERSISTENCE	BIT(4)
#define MPEG2FPGA_TRICK_MODE_SOURCE_SELECT_SHIFT	1
#define MPEG2FPGA_TRICK_MODE_SOURCE_SELECT_MASK	GENMASK(3, 1)
#define MPEG2FPGA_TRICK_MODE_FLUSH_VBUF	BIT(0)

/*
 * Bridge-owned registers, word addresses 0x10 and up.
 *
 * Source: trunk/mpeg2fpga/rtl/mpeg2/apb3_mpeg2fpga_bridge.v (localparams
 * around line 248). These are NOT part of the decoder's two-bank read/write
 * split above -- they are a flat map added by the APB bridge for this port,
 * and each one is either read-only or write-only as noted.
 *
 * Everything here was previously known only to the ad-hoc Python under
 * webserver/, which is why the same magic offsets were open-coded in a dozen
 * scripts. The driver owns them now.
 */
#define MPEG2FPGA_B_STREAM_PUSH		0x10	/* wo: one stream byte per write */
#define MPEG2FPGA_B_DMA_ADDR		0x11	/* wo: byte offset into staging */
#define MPEG2FPGA_B_DMA_LEN		0x12	/* wo: length in bytes */
#define MPEG2FPGA_B_DMA_CTRL		0x13	/* wo: bit 0 starts a transfer */
#define MPEG2FPGA_B_DMA_STATUS		0x14	/* ro */
#define MPEG2FPGA_B_PWDATA_STICKY	0x15	/* ro */
#define MPEG2FPGA_B_VBUF_WR_ADDR	0x16	/* ro */
#define MPEG2FPGA_B_VBUF_RD_ADDR	0x17	/* ro */
#define MPEG2FPGA_B_DISP_SERVICE_CNT	0x18	/* ro: cycles arbiter served display */
#define MPEG2FPGA_B_VBR_SERVICE_CNT	0x19	/* ro: cycles serving the video buffer */
#define MPEG2FPGA_B_VBR_STARVED_CNT	0x1a	/* ro: cycles the VLD wanted data and lost */
#define MPEG2FPGA_B_ARBITER_FLAGS	0x1b	/* ro */
#define MPEG2FPGA_B_MEM_RES_VALID_CNT	0x1c	/* ro: memory responses returned */
#define MPEG2FPGA_B_CORE_ENABLE		0x20	/* rw: bit 0 releases the core from reset */

/* dma ctrl (0x13, write-only) */
#define MPEG2FPGA_DMA_CTRL_START	BIT(0)

/* dma status (0x14, read-only), packed as
 * {bytes_done[23:0], 6'b0, done_sticky, busy} -- see the bridge's
 * DMA_STATUS_ADDR read case. done is sticky and is cleared by starting the
 * next transfer, not by reading.
 */
#define MPEG2FPGA_DMA_STATUS_BUSY	BIT(0)
#define MPEG2FPGA_DMA_STATUS_DONE	BIT(1)
#define MPEG2FPGA_DMA_STATUS_BYTES_SHIFT	8
#define MPEG2FPGA_DMA_STATUS_BYTES_MASK		GENMASK(31, 8)

/* core enable (0x20) */
#define MPEG2FPGA_CORE_ENABLE		BIT(0)

/* frame_rate_code values, ISO/IEC 13818-2 table 6-4, in milli-Hz so the
 * 1000/1001 rates stay exact in integer arithmetic.
 */
#define MPEG2FPGA_FRAME_RATE_CODE_MIN	1
#define MPEG2FPGA_FRAME_RATE_CODE_MAX	8

#endif /* MPEG2FPGA_REGS_H */
