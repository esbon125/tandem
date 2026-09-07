// SPDX-License-Identifier: GPL-2.0
/*
 * Hardware-independent logic for the mpeg2fpga register interface.
 * See mpeg2fpga_core.h and mpeg2fpga_regs.h for the register map.
 */

#include <linux/bitops.h>

#include "mpeg2fpga_core.h"
#include "mpeg2fpga_regs.h"

static u32 mpeg2fpga_core_read(struct mpeg2fpga_core *core, unsigned int reg)
{
	return core->ops->read(core->ops->ctx, reg);
}

static void mpeg2fpga_core_write(struct mpeg2fpga_core *core,
				  unsigned int reg, u32 val)
{
	core->ops->write(core->ops->ctx, reg, val);
}

/* Read-modify-write MPEG2FPGA_W_STREAM against the shadow and commit it. */
static void mpeg2fpga_core_write_stream(struct mpeg2fpga_core *core,
					 u32 mask, u32 val)
{
	core->stream_shadow = (core->stream_shadow & ~mask) | (val & mask);
	mpeg2fpga_core_write(core, MPEG2FPGA_W_STREAM, core->stream_shadow);
}

void mpeg2fpga_core_init(struct mpeg2fpga_core *core,
			  const struct mpeg2fpga_regops *ops)
{
	core->ops = ops;
	/* Matches hardware power-up/reset state: all *_intr_en and
	 * osd_enable low, watchdog at its documented default interval.
	 */
	core->sticky = 0;
	core->stream_shadow = MPEG2FPGA_WATCHDOG_DEFAULT_INTERVAL
		<< MPEG2FPGA_STREAM_WATCHDOG_INTERVAL_SHIFT;
	mpeg2fpga_core_write(core, MPEG2FPGA_W_STREAM, core->stream_shadow);

	/* persistence is 1 at reset: when no new picture is ready the last one
	 * is shown again rather than a blank screen. Seed the shadow with it so
	 * the first read-modify-write of any other trick-mode field does not
	 * silently turn it off.
	 */
	core->trick_shadow = MPEG2FPGA_TRICK_MODE_PERSISTENCE;
	mpeg2fpga_core_write(core, MPEG2FPGA_W_TRICK_MODE, core->trick_shadow);
}

u16 mpeg2fpga_core_get_version(struct mpeg2fpga_core *core)
{
	return mpeg2fpga_core_read(core, MPEG2FPGA_R_VERSION) & 0xffff;
}

static void mpeg2fpga_core_unpack_status(u32 val,
					 struct mpeg2fpga_status *status)
{
	status->matrix_coefficients =
		(val & MPEG2FPGA_STATUS_MATRIX_COEFFICIENTS_MASK) >>
		MPEG2FPGA_STATUS_MATRIX_COEFFICIENTS_SHIFT;
	status->watchdog_status = !!(val & MPEG2FPGA_STATUS_WATCHDOG_STATUS);
	status->osd_wr_en = !!(val & MPEG2FPGA_STATUS_OSD_WR_EN);
	status->osd_wr_ack = !!(val & MPEG2FPGA_STATUS_OSD_WR_ACK);
	status->osd_wr_full = !!(val & MPEG2FPGA_STATUS_OSD_WR_FULL);
	status->picture_hdr = !!(val & MPEG2FPGA_STATUS_PICTURE_HDR);
	status->frame_end = !!(val & MPEG2FPGA_STATUS_FRAME_END);
	status->video_ch = !!(val & MPEG2FPGA_STATUS_VIDEO_CH);
	status->error = !!(val & MPEG2FPGA_STATUS_ERROR);
}

void mpeg2fpga_core_read_status(struct mpeg2fpga_core *core,
				 struct mpeg2fpga_status *status)
{
	mpeg2fpga_core_unpack_status(
		mpeg2fpga_core_read(core, MPEG2FPGA_R_STATUS), status);
}

void mpeg2fpga_core_set_irq_mask(struct mpeg2fpga_core *core, u32 mask)
{
	u32 bits = 0;

	if (mask & MPEG2FPGA_IRQ_PICTURE_HDR)
		bits |= MPEG2FPGA_STREAM_PICTURE_HDR_INTR_EN;
	if (mask & MPEG2FPGA_IRQ_FRAME_END)
		bits |= MPEG2FPGA_STREAM_FRAME_END_INTR_EN;
	if (mask & MPEG2FPGA_IRQ_VIDEO_CH)
		bits |= MPEG2FPGA_STREAM_VIDEO_CH_INTR_EN;

	mpeg2fpga_core_write_stream(core,
		MPEG2FPGA_STREAM_PICTURE_HDR_INTR_EN |
		MPEG2FPGA_STREAM_FRAME_END_INTR_EN |
		MPEG2FPGA_STREAM_VIDEO_CH_INTR_EN,
		bits);
}

u32 mpeg2fpga_core_get_irq_mask(struct mpeg2fpga_core *core)
{
	u32 mask = 0;

	if (core->stream_shadow & MPEG2FPGA_STREAM_PICTURE_HDR_INTR_EN)
		mask |= MPEG2FPGA_IRQ_PICTURE_HDR;
	if (core->stream_shadow & MPEG2FPGA_STREAM_FRAME_END_INTR_EN)
		mask |= MPEG2FPGA_IRQ_FRAME_END;
	if (core->stream_shadow & MPEG2FPGA_STREAM_VIDEO_CH_INTR_EN)
		mask |= MPEG2FPGA_IRQ_VIDEO_CH;

	return mask;
}

void mpeg2fpga_core_set_osd_enable(struct mpeg2fpga_core *core, bool enable)
{
	mpeg2fpga_core_write_stream(core, MPEG2FPGA_STREAM_OSD_ENABLE,
		enable ? MPEG2FPGA_STREAM_OSD_ENABLE : 0);
}

void mpeg2fpga_core_set_watchdog_interval(struct mpeg2fpga_core *core,
					   u8 interval)
{
	mpeg2fpga_core_write_stream(core,
		MPEG2FPGA_STREAM_WATCHDOG_INTERVAL_MASK,
		(u32)interval << MPEG2FPGA_STREAM_WATCHDOG_INTERVAL_SHIFT);
}

void mpeg2fpga_core_watchdog_disable(struct mpeg2fpga_core *core)
{
	mpeg2fpga_core_set_watchdog_interval(core, MPEG2FPGA_WATCHDOG_DISABLED);
}

void mpeg2fpga_core_poll_status(struct mpeg2fpga_core *core,
				 struct mpeg2fpga_status *status)
{
	u32 val = mpeg2fpga_core_read(core, MPEG2FPGA_R_STATUS);

	/* Reading clears, so whoever reads is the only one who will ever see
	 * these events -- keep them.
	 */
	core->sticky |= val & (MPEG2FPGA_STATUS_WATCHDOG_STATUS |
			       MPEG2FPGA_STATUS_OSD_WR_EN |
			       MPEG2FPGA_STATUS_OSD_WR_ACK |
			       MPEG2FPGA_STATUS_OSD_WR_FULL |
			       MPEG2FPGA_STATUS_PICTURE_HDR |
			       MPEG2FPGA_STATUS_FRAME_END |
			       MPEG2FPGA_STATUS_VIDEO_CH |
			       MPEG2FPGA_STATUS_ERROR);

	mpeg2fpga_core_unpack_status(val, status);
}

u32 mpeg2fpga_core_get_sticky(struct mpeg2fpga_core *core)
{
	return core->sticky;
}

void mpeg2fpga_core_clear_sticky(struct mpeg2fpga_core *core)
{
	core->sticky = 0;
}

void mpeg2fpga_core_set_enable(struct mpeg2fpga_core *core, bool enable)
{
	mpeg2fpga_core_write(core, MPEG2FPGA_B_CORE_ENABLE,
			     enable ? MPEG2FPGA_CORE_ENABLE : 0);
}

bool mpeg2fpga_core_is_enabled(struct mpeg2fpga_core *core)
{
	return !!(mpeg2fpga_core_read(core, MPEG2FPGA_B_CORE_ENABLE) &
		  MPEG2FPGA_CORE_ENABLE);
}

void mpeg2fpga_core_dma_start(struct mpeg2fpga_core *core, u32 addr, u32 len)
{
	/* Order is load-bearing: stream_dma.v latches address and length on
	 * the start pulse, so writing DMA_CTRL first transfers whatever the
	 * previous transfer left behind.
	 */
	mpeg2fpga_core_write(core, MPEG2FPGA_B_DMA_ADDR, addr);
	mpeg2fpga_core_write(core, MPEG2FPGA_B_DMA_LEN, len);
	mpeg2fpga_core_write(core, MPEG2FPGA_B_DMA_CTRL,
			     MPEG2FPGA_DMA_CTRL_START);
}

void mpeg2fpga_core_dma_get_status(struct mpeg2fpga_core *core,
				    struct mpeg2fpga_dma_status *status)
{
	u32 val = mpeg2fpga_core_read(core, MPEG2FPGA_B_DMA_STATUS);

	status->busy = !!(val & MPEG2FPGA_DMA_STATUS_BUSY);
	status->done = !!(val & MPEG2FPGA_DMA_STATUS_DONE);
	status->bytes_done = (val & MPEG2FPGA_DMA_STATUS_BYTES_MASK) >>
			     MPEG2FPGA_DMA_STATUS_BYTES_SHIFT;
}

u32 mpeg2fpga_core_frame_rate_millihz(u8 code, u8 extension_n, u8 extension_d)
{
	/* ISO/IEC 13818-2 table 6-4, in milli-Hz so 1000/1001 stays exact. */
	static const u32 rates[] = {
		[1] = 23976,	/* 24000/1001 */
		[2] = 24000,
		[3] = 25000,
		[4] = 29970,	/* 30000/1001 */
		[5] = 30000,
		[6] = 50000,
		[7] = 59940,	/* 60000/1001 */
		[8] = 60000,
	};

	if (code < MPEG2FPGA_FRAME_RATE_CODE_MIN ||
	    code > MPEG2FPGA_FRAME_RATE_CODE_MAX)
		return 0;	/* reserved: no rate is better than a wrong one */

	return rates[code] * (extension_n + 1U) / (extension_d + 1U);
}

void mpeg2fpga_core_get_geometry(struct mpeg2fpga_core *core,
				  struct mpeg2fpga_geometry *geom)
{
	u32 size = mpeg2fpga_core_read(core, MPEG2FPGA_R_SIZE);
	u32 disp = mpeg2fpga_core_read(core, MPEG2FPGA_R_DISPLAY_SIZE);
	u32 rate = mpeg2fpga_core_read(core, MPEG2FPGA_R_FRAME_RATE);

	geom->width = (size & MPEG2FPGA_SIZE_HORIZONTAL_MASK) >>
		      MPEG2FPGA_SIZE_HORIZONTAL_SHIFT;
	geom->height = size & MPEG2FPGA_SIZE_VERTICAL_MASK;
	geom->display_width = (disp & MPEG2FPGA_DISPLAY_SIZE_HORIZONTAL_MASK) >>
			      MPEG2FPGA_DISPLAY_SIZE_HORIZONTAL_SHIFT;
	geom->display_height = disp & MPEG2FPGA_DISPLAY_SIZE_VERTICAL_MASK;

	geom->frame_rate_code = rate & MPEG2FPGA_FRAME_RATE_CODE_MASK;
	geom->frame_rate_millihz = mpeg2fpga_core_frame_rate_millihz(
		geom->frame_rate_code,
		(rate & MPEG2FPGA_FRAME_RATE_EXTENSION_N_MASK) >>
			MPEG2FPGA_FRAME_RATE_EXTENSION_N_SHIFT,
		(rate & MPEG2FPGA_FRAME_RATE_EXTENSION_D_MASK) >>
			MPEG2FPGA_FRAME_RATE_EXTENSION_D_SHIFT);

	/* The frame store is addressed in whole macroblocks, so a picture
	 * whose size is not a multiple of 16 still occupies a padded plane.
	 */
	geom->macroblocks_wide = (geom->width + 15) / 16;
	geom->macroblocks_high = (geom->height + 15) / 16;
}

void mpeg2fpga_core_get_perf_counters(struct mpeg2fpga_core *core,
				       struct mpeg2fpga_perf_counters *perf)
{
	perf->disp_service_cnt = mpeg2fpga_core_read(core, MPEG2FPGA_B_DISP_SERVICE_CNT);
	perf->vbr_service_cnt = mpeg2fpga_core_read(core, MPEG2FPGA_B_VBR_SERVICE_CNT);
	perf->vbr_starved_cnt = mpeg2fpga_core_read(core, MPEG2FPGA_B_VBR_STARVED_CNT);
	perf->mem_res_valid_cnt = mpeg2fpga_core_read(core, MPEG2FPGA_B_MEM_RES_VALID_CNT);
	perf->write_service_cnt = mpeg2fpga_core_read(core, MPEG2FPGA_B_WRITE_SERVICE_CNT);
	perf->fwd_service_cnt = mpeg2fpga_core_read(core, MPEG2FPGA_B_FWD_SERVICE_CNT);
	perf->bwd_service_cnt = mpeg2fpga_core_read(core, MPEG2FPGA_B_BWD_SERVICE_CNT);
	perf->idle_cnt = mpeg2fpga_core_read(core, MPEG2FPGA_B_IDLE_CNT);
}

/* Read-modify-write MPEG2FPGA_W_TRICK_MODE against its shadow. */
static void mpeg2fpga_core_write_trick(struct mpeg2fpga_core *core,
					u32 mask, u32 val)
{
	core->trick_shadow = (core->trick_shadow & ~mask) | (val & mask);
	mpeg2fpga_core_write(core, MPEG2FPGA_W_TRICK_MODE, core->trick_shadow);
}

void mpeg2fpga_core_flush_vbuf(struct mpeg2fpga_core *core)
{
	/* A strobe, not a mode: raise it for one write and drop it again, so
	 * the shadow does not carry a permanent flush into the next
	 * read-modify-write of some unrelated field.
	 */
	mpeg2fpga_core_write(core, MPEG2FPGA_W_TRICK_MODE,
			     core->trick_shadow |
			     MPEG2FPGA_TRICK_MODE_FLUSH_VBUF);
	mpeg2fpga_core_write(core, MPEG2FPGA_W_TRICK_MODE, core->trick_shadow);
}

void mpeg2fpga_core_set_freeze(struct mpeg2fpga_core *core, bool freeze)
{
	u32 repeat = freeze ? MPEG2FPGA_TRICK_REPEAT_FRAME_FREEZE : 0;

	mpeg2fpga_core_write_trick(core,
		MPEG2FPGA_TRICK_MODE_REPEAT_FRAME_MASK,
		repeat << MPEG2FPGA_TRICK_MODE_REPEAT_FRAME_SHIFT);
}

bool mpeg2fpga_core_is_frozen(struct mpeg2fpga_core *core)
{
	u32 repeat = (core->trick_shadow &
		      MPEG2FPGA_TRICK_MODE_REPEAT_FRAME_MASK) >>
		     MPEG2FPGA_TRICK_MODE_REPEAT_FRAME_SHIFT;

	return repeat == MPEG2FPGA_TRICK_REPEAT_FRAME_FREEZE;
}

void mpeg2fpga_core_set_source_select(struct mpeg2fpga_core *core, u8 source)
{
	mpeg2fpga_core_write_trick(core,
		MPEG2FPGA_TRICK_MODE_SOURCE_SELECT_MASK,
		(u32)source << MPEG2FPGA_TRICK_MODE_SOURCE_SELECT_SHIFT);
}

u8 mpeg2fpga_core_get_source_select(struct mpeg2fpga_core *core)
{
	return (core->trick_shadow &
		MPEG2FPGA_TRICK_MODE_SOURCE_SELECT_MASK) >>
	       MPEG2FPGA_TRICK_MODE_SOURCE_SELECT_SHIFT;
}

void mpeg2fpga_core_set_persistence(struct mpeg2fpga_core *core, bool on)
{
	mpeg2fpga_core_write_trick(core, MPEG2FPGA_TRICK_MODE_PERSISTENCE,
		on ? MPEG2FPGA_TRICK_MODE_PERSISTENCE : 0);
}
