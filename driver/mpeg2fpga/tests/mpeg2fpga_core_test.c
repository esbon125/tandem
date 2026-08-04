// SPDX-License-Identifier: GPL-2.0
/*
 * KUnit tests for mpeg2fpga_core.c against an in-memory fake register
 * backend -- no hardware or platform_device involved. The interesting
 * behaviour under test is the shadow-register read-modify-write logic:
 * MPEG2FPGA_W_STREAM packs watchdog_interval and the three *_intr_en bits
 * into one write-only register, so setting one field must never disturb
 * the others.
 */

#include <kunit/test.h>
#include <linux/module.h>

#include "../mpeg2fpga_core.h"
#include "../mpeg2fpga_regs.h"

struct mpeg2fpga_fake_regs {
	u32 write_regs[16];
	u32 read_regs[16];
};

static u32 fake_read(void *ctx, unsigned int reg)
{
	struct mpeg2fpga_fake_regs *fake = ctx;

	return fake->read_regs[reg];
}

static void fake_write(void *ctx, unsigned int reg, u32 val)
{
	struct mpeg2fpga_fake_regs *fake = ctx;

	fake->write_regs[reg] = val;
}

struct mpeg2fpga_core_test_ctx {
	struct mpeg2fpga_fake_regs fake;
	struct mpeg2fpga_regops ops;
	struct mpeg2fpga_core core;
};

static int mpeg2fpga_core_test_init(struct kunit *test)
{
	struct mpeg2fpga_core_test_ctx *ctx;

	ctx = kunit_kzalloc(test, sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return -ENOMEM;

	ctx->ops.read = fake_read;
	ctx->ops.write = fake_write;
	ctx->ops.ctx = &ctx->fake;

	mpeg2fpga_core_init(&ctx->core, &ctx->ops);

	test->priv = ctx;
	return 0;
}

static u32 stream_watchdog_field(u32 stream_val)
{
	return (stream_val & MPEG2FPGA_STREAM_WATCHDOG_INTERVAL_MASK) >>
		MPEG2FPGA_STREAM_WATCHDOG_INTERVAL_SHIFT;
}

static void mpeg2fpga_core_test_init_sets_default_watchdog(struct kunit *test)
{
	struct mpeg2fpga_core_test_ctx *ctx = test->priv;
	u32 stream = ctx->fake.write_regs[MPEG2FPGA_W_STREAM];

	KUNIT_EXPECT_EQ(test, stream_watchdog_field(stream),
			MPEG2FPGA_WATCHDOG_DEFAULT_INTERVAL);
	KUNIT_EXPECT_EQ(test, mpeg2fpga_core_get_irq_mask(&ctx->core), 0);
}

static void mpeg2fpga_core_test_get_version(struct kunit *test)
{
	struct mpeg2fpga_core_test_ctx *ctx = test->priv;

	ctx->fake.read_regs[MPEG2FPGA_R_VERSION] = 0x0102;

	KUNIT_EXPECT_EQ(test, mpeg2fpga_core_get_version(&ctx->core), 0x0102);
}

static void mpeg2fpga_core_test_read_status_parses_all_fields(struct kunit *test)
{
	struct mpeg2fpga_core_test_ctx *ctx = test->priv;
	struct mpeg2fpga_status status;
	u32 raw = (0xabu << MPEG2FPGA_STATUS_MATRIX_COEFFICIENTS_SHIFT) |
		  MPEG2FPGA_STATUS_WATCHDOG_STATUS |
		  MPEG2FPGA_STATUS_OSD_WR_EN |
		  MPEG2FPGA_STATUS_PICTURE_HDR |
		  MPEG2FPGA_STATUS_VIDEO_CH;

	ctx->fake.read_regs[MPEG2FPGA_R_STATUS] = raw;

	mpeg2fpga_core_read_status(&ctx->core, &status);

	KUNIT_EXPECT_EQ(test, status.matrix_coefficients, 0xab);
	KUNIT_EXPECT_TRUE(test, status.watchdog_status);
	KUNIT_EXPECT_TRUE(test, status.osd_wr_en);
	KUNIT_EXPECT_FALSE(test, status.osd_wr_ack);
	KUNIT_EXPECT_FALSE(test, status.osd_wr_full);
	KUNIT_EXPECT_TRUE(test, status.picture_hdr);
	KUNIT_EXPECT_FALSE(test, status.frame_end);
	KUNIT_EXPECT_TRUE(test, status.video_ch);
	KUNIT_EXPECT_FALSE(test, status.error);
}

static void mpeg2fpga_core_test_set_irq_mask_preserves_watchdog(struct kunit *test)
{
	struct mpeg2fpga_core_test_ctx *ctx = test->priv;
	u32 stream;

	mpeg2fpga_core_set_irq_mask(&ctx->core,
		MPEG2FPGA_IRQ_PICTURE_HDR | MPEG2FPGA_IRQ_VIDEO_CH);

	stream = ctx->fake.write_regs[MPEG2FPGA_W_STREAM];

	KUNIT_EXPECT_EQ(test, stream_watchdog_field(stream),
			MPEG2FPGA_WATCHDOG_DEFAULT_INTERVAL);
	KUNIT_EXPECT_TRUE(test, stream & MPEG2FPGA_STREAM_PICTURE_HDR_INTR_EN);
	KUNIT_EXPECT_TRUE(test, stream & MPEG2FPGA_STREAM_VIDEO_CH_INTR_EN);
	KUNIT_EXPECT_FALSE(test, stream & MPEG2FPGA_STREAM_FRAME_END_INTR_EN);

	KUNIT_EXPECT_EQ(test, mpeg2fpga_core_get_irq_mask(&ctx->core),
			MPEG2FPGA_IRQ_PICTURE_HDR | MPEG2FPGA_IRQ_VIDEO_CH);
}

static void mpeg2fpga_core_test_set_watchdog_preserves_irq_mask(struct kunit *test)
{
	struct mpeg2fpga_core_test_ctx *ctx = test->priv;
	u32 stream;

	mpeg2fpga_core_set_irq_mask(&ctx->core, MPEG2FPGA_IRQ_FRAME_END);
	mpeg2fpga_core_set_watchdog_interval(&ctx->core, 42);

	stream = ctx->fake.write_regs[MPEG2FPGA_W_STREAM];

	KUNIT_EXPECT_EQ(test, stream_watchdog_field(stream), 42);
	KUNIT_EXPECT_TRUE(test, stream & MPEG2FPGA_STREAM_FRAME_END_INTR_EN);
	KUNIT_EXPECT_FALSE(test, stream & MPEG2FPGA_STREAM_PICTURE_HDR_INTR_EN);
	KUNIT_EXPECT_FALSE(test, stream & MPEG2FPGA_STREAM_VIDEO_CH_INTR_EN);
}

static void mpeg2fpga_core_test_set_osd_enable_preserves_other_bits(struct kunit *test)
{
	struct mpeg2fpga_core_test_ctx *ctx = test->priv;
	u32 stream;

	mpeg2fpga_core_set_irq_mask(&ctx->core, MPEG2FPGA_IRQ_ALL);
	mpeg2fpga_core_set_watchdog_interval(&ctx->core, 10);

	mpeg2fpga_core_set_osd_enable(&ctx->core, true);
	stream = ctx->fake.write_regs[MPEG2FPGA_W_STREAM];
	KUNIT_EXPECT_TRUE(test, stream & MPEG2FPGA_STREAM_OSD_ENABLE);
	KUNIT_EXPECT_EQ(test, stream_watchdog_field(stream), 10);
	KUNIT_EXPECT_EQ(test, mpeg2fpga_core_get_irq_mask(&ctx->core),
			MPEG2FPGA_IRQ_ALL);

	mpeg2fpga_core_set_osd_enable(&ctx->core, false);
	stream = ctx->fake.write_regs[MPEG2FPGA_W_STREAM];
	KUNIT_EXPECT_FALSE(test, stream & MPEG2FPGA_STREAM_OSD_ENABLE);
	KUNIT_EXPECT_EQ(test, stream_watchdog_field(stream), 10);
	KUNIT_EXPECT_EQ(test, mpeg2fpga_core_get_irq_mask(&ctx->core),
			MPEG2FPGA_IRQ_ALL);
}

static void mpeg2fpga_core_test_watchdog_disable(struct kunit *test)
{
	struct mpeg2fpga_core_test_ctx *ctx = test->priv;
	u32 stream;

	mpeg2fpga_core_watchdog_disable(&ctx->core);

	stream = ctx->fake.write_regs[MPEG2FPGA_W_STREAM];
	KUNIT_EXPECT_EQ(test, stream_watchdog_field(stream),
			MPEG2FPGA_WATCHDOG_DISABLED);
}

static struct kunit_case mpeg2fpga_core_test_cases[] = {
	KUNIT_CASE(mpeg2fpga_core_test_init_sets_default_watchdog),
	KUNIT_CASE(mpeg2fpga_core_test_get_version),
	KUNIT_CASE(mpeg2fpga_core_test_read_status_parses_all_fields),
	KUNIT_CASE(mpeg2fpga_core_test_set_irq_mask_preserves_watchdog),
	KUNIT_CASE(mpeg2fpga_core_test_set_watchdog_preserves_irq_mask),
	KUNIT_CASE(mpeg2fpga_core_test_set_osd_enable_preserves_other_bits),
	KUNIT_CASE(mpeg2fpga_core_test_watchdog_disable),
	{}
};

static struct kunit_suite mpeg2fpga_core_test_suite = {
	.name = "mpeg2fpga_core",
	.init = mpeg2fpga_core_test_init,
	.test_cases = mpeg2fpga_core_test_cases,
};

kunit_test_suite(mpeg2fpga_core_test_suite);

MODULE_LICENSE("GPL");
