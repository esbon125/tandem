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
	core->stream_shadow = MPEG2FPGA_WATCHDOG_DEFAULT_INTERVAL
		<< MPEG2FPGA_STREAM_WATCHDOG_INTERVAL_SHIFT;
	mpeg2fpga_core_write(core, MPEG2FPGA_W_STREAM, core->stream_shadow);
}

u16 mpeg2fpga_core_get_version(struct mpeg2fpga_core *core)
{
	return mpeg2fpga_core_read(core, MPEG2FPGA_R_VERSION) & 0xffff;
}

void mpeg2fpga_core_read_status(struct mpeg2fpga_core *core,
				 struct mpeg2fpga_status *status)
{
	u32 val = mpeg2fpga_core_read(core, MPEG2FPGA_R_STATUS);

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
