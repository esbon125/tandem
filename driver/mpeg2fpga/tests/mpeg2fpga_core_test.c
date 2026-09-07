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

/* The bridge map runs to word 0x38, well past the decoder's own 16. */
#define FAKE_NR_REGS	64
#define FAKE_LOG_LEN	32

struct mpeg2fpga_fake_regs {
	u32 write_regs[FAKE_NR_REGS];
	u32 read_regs[FAKE_NR_REGS];
	/* Order matters for the DMA engine -- address and length must be
	 * latched before the start bit -- so the writes are logged, not just
	 * their final values.
	 */
	struct {
		unsigned int reg;
		u32 val;
	} log[FAKE_LOG_LEN];
	unsigned int log_len;
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
	if (fake->log_len < FAKE_LOG_LEN) {
		fake->log[fake->log_len].reg = reg;
		fake->log[fake->log_len].val = val;
		fake->log_len++;
	}
}

/* index of the first logged write to @reg after @from, or -1 */
static int fake_write_index(struct mpeg2fpga_fake_regs *fake, unsigned int reg,
			    unsigned int from)
{
	unsigned int i;

	for (i = from; i < fake->log_len; i++)
		if (fake->log[i].reg == reg)
			return (int)i;
	return -1;
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


/*
 * Core enable, the DMA engine and the decoded geometry. All three were only
 * ever driven by ad-hoc Python under webserver/, with the register offsets
 * open-coded in every script; these are the behaviours that had to be pinned
 * down before that could move into the driver.
 */

static void mpeg2fpga_core_test_core_enable(struct kunit *test)
{
	struct mpeg2fpga_core_test_ctx *ctx = test->priv;

	mpeg2fpga_core_set_enable(&ctx->core, true);
	KUNIT_EXPECT_EQ(test, ctx->fake.write_regs[MPEG2FPGA_B_CORE_ENABLE],
			MPEG2FPGA_CORE_ENABLE);

	mpeg2fpga_core_set_enable(&ctx->core, false);
	KUNIT_EXPECT_EQ(test, ctx->fake.write_regs[MPEG2FPGA_B_CORE_ENABLE], 0u);

	ctx->fake.read_regs[MPEG2FPGA_B_CORE_ENABLE] = MPEG2FPGA_CORE_ENABLE;
	KUNIT_EXPECT_TRUE(test, mpeg2fpga_core_is_enabled(&ctx->core));
	ctx->fake.read_regs[MPEG2FPGA_B_CORE_ENABLE] = 0;
	KUNIT_EXPECT_FALSE(test, mpeg2fpga_core_is_enabled(&ctx->core));
}

static void mpeg2fpga_core_test_dma_start_latches_before_trigger(struct kunit *test)
{
	struct mpeg2fpga_core_test_ctx *ctx = test->priv;
	int addr_at, len_at, ctrl_at;

	ctx->fake.log_len = 0;

	mpeg2fpga_core_dma_start(&ctx->core, 0x1000000, 262144);

	KUNIT_EXPECT_EQ(test, ctx->fake.write_regs[MPEG2FPGA_B_DMA_ADDR],
			0x1000000u);
	KUNIT_EXPECT_EQ(test, ctx->fake.write_regs[MPEG2FPGA_B_DMA_LEN],
			262144u);
	KUNIT_EXPECT_EQ(test, ctx->fake.write_regs[MPEG2FPGA_B_DMA_CTRL],
			MPEG2FPGA_DMA_CTRL_START);

	/* stream_dma latches address and length on the start pulse, so a
	 * driver that writes DMA_CTRL first transfers whatever was there
	 * before -- which is how a push once ran with a length of zero.
	 */
	addr_at = fake_write_index(&ctx->fake, MPEG2FPGA_B_DMA_ADDR, 0);
	len_at = fake_write_index(&ctx->fake, MPEG2FPGA_B_DMA_LEN, 0);
	ctrl_at = fake_write_index(&ctx->fake, MPEG2FPGA_B_DMA_CTRL, 0);

	KUNIT_ASSERT_GE(test, addr_at, 0);
	KUNIT_ASSERT_GE(test, len_at, 0);
	KUNIT_ASSERT_GE(test, ctrl_at, 0);
	KUNIT_EXPECT_LT(test, addr_at, ctrl_at);
	KUNIT_EXPECT_LT(test, len_at, ctrl_at);
}

static void mpeg2fpga_core_test_dma_status_unpacks(struct kunit *test)
{
	struct mpeg2fpga_core_test_ctx *ctx = test->priv;
	struct mpeg2fpga_dma_status status;

	/* {bytes_done[23:0], 6'b0, done, busy} */
	ctx->fake.read_regs[MPEG2FPGA_B_DMA_STATUS] =
		(263123u << MPEG2FPGA_DMA_STATUS_BYTES_SHIFT) |
		MPEG2FPGA_DMA_STATUS_DONE;

	mpeg2fpga_core_dma_get_status(&ctx->core, &status);

	KUNIT_EXPECT_FALSE(test, status.busy);
	KUNIT_EXPECT_TRUE(test, status.done);
	KUNIT_EXPECT_EQ(test, status.bytes_done, 263123u);

	ctx->fake.read_regs[MPEG2FPGA_B_DMA_STATUS] = MPEG2FPGA_DMA_STATUS_BUSY;
	mpeg2fpga_core_dma_get_status(&ctx->core, &status);
	KUNIT_EXPECT_TRUE(test, status.busy);
	KUNIT_EXPECT_FALSE(test, status.done);
	KUNIT_EXPECT_EQ(test, status.bytes_done, 0u);
}

static void mpeg2fpga_core_test_geometry(struct kunit *test)
{
	struct mpeg2fpga_core_test_ctx *ctx = test->priv;
	struct mpeg2fpga_geometry geom;

	ctx->fake.read_regs[MPEG2FPGA_R_SIZE] =
		(704u << MPEG2FPGA_SIZE_HORIZONTAL_SHIFT) | 480u;
	/* sony-ct1 really does declare a 120x120 display size; a stream with
	 * no sequence_display_extension reads back 0x0. Neither is an error.
	 */
	ctx->fake.read_regs[MPEG2FPGA_R_DISPLAY_SIZE] =
		(120u << MPEG2FPGA_DISPLAY_SIZE_HORIZONTAL_SHIFT) | 120u;
	ctx->fake.read_regs[MPEG2FPGA_R_FRAME_RATE] = 4;	/* 30000/1001 */

	mpeg2fpga_core_get_geometry(&ctx->core, &geom);

	KUNIT_EXPECT_EQ(test, geom.width, 704);
	KUNIT_EXPECT_EQ(test, geom.height, 480);
	KUNIT_EXPECT_EQ(test, geom.display_width, 120);
	KUNIT_EXPECT_EQ(test, geom.display_height, 120);
	KUNIT_EXPECT_EQ(test, geom.frame_rate_code, 4);
	KUNIT_EXPECT_EQ(test, geom.frame_rate_millihz, 29970);
	KUNIT_EXPECT_EQ(test, geom.macroblocks_wide, 44);
	KUNIT_EXPECT_EQ(test, geom.macroblocks_high, 30);
}

static void mpeg2fpga_core_test_perf_counters(struct kunit *test)
{
	struct mpeg2fpga_core_test_ctx *ctx = test->priv;
	struct mpeg2fpga_perf_counters perf;

	ctx->fake.read_regs[MPEG2FPGA_B_DISP_SERVICE_CNT] = 111;
	ctx->fake.read_regs[MPEG2FPGA_B_VBR_SERVICE_CNT] = 222;
	ctx->fake.read_regs[MPEG2FPGA_B_VBR_STARVED_CNT] = 333;
	ctx->fake.read_regs[MPEG2FPGA_B_MEM_RES_VALID_CNT] = 444;
	ctx->fake.read_regs[MPEG2FPGA_B_WRITE_SERVICE_CNT] = 555;

	mpeg2fpga_core_get_perf_counters(&ctx->core, &perf);

	KUNIT_EXPECT_EQ(test, perf.disp_service_cnt, 111u);
	KUNIT_EXPECT_EQ(test, perf.vbr_service_cnt, 222u);
	KUNIT_EXPECT_EQ(test, perf.vbr_starved_cnt, 333u);
	KUNIT_EXPECT_EQ(test, perf.mem_res_valid_cnt, 444u);
	KUNIT_EXPECT_EQ(test, perf.write_service_cnt, 555u);
}

static void mpeg2fpga_core_test_frame_rate_table(struct kunit *test)
{
	static const u32 expect[] = {
		0, 23976, 24000, 25000, 29970, 30000, 50000, 59940, 60000,
	};
	unsigned int code;

	for (code = 0; code < ARRAY_SIZE(expect); code++)
		KUNIT_EXPECT_EQ(test,
			mpeg2fpga_core_frame_rate_millihz(code, 0, 0),
			expect[code]);

	/* a reserved code has no rate rather than a wrong one */
	KUNIT_EXPECT_EQ(test, mpeg2fpga_core_frame_rate_millihz(9, 0, 0), 0u);

	/* frame_rate_extension_n/_d scale it: rate * (n+1) / (d+1) */
	KUNIT_EXPECT_EQ(test, mpeg2fpga_core_frame_rate_millihz(5, 1, 0), 60000u);
	KUNIT_EXPECT_EQ(test, mpeg2fpga_core_frame_rate_millihz(5, 0, 1), 15000u);
}

static void mpeg2fpga_core_test_status_sticky_accumulates(struct kunit *test)
{
	struct mpeg2fpga_core_test_ctx *ctx = test->priv;
	struct mpeg2fpga_status status;

	/* The status register is read-to-clear, so a caller polling it sees
	 * each event exactly once and only if it happens to look at the right
	 * moment. Every Python diagnostic ended up ORing reads together by
	 * hand; the core does it once, correctly.
	 */
	ctx->fake.read_regs[MPEG2FPGA_R_STATUS] = MPEG2FPGA_STATUS_PICTURE_HDR;
	mpeg2fpga_core_poll_status(&ctx->core, &status);
	ctx->fake.read_regs[MPEG2FPGA_R_STATUS] = MPEG2FPGA_STATUS_FRAME_END;
	mpeg2fpga_core_poll_status(&ctx->core, &status);
	ctx->fake.read_regs[MPEG2FPGA_R_STATUS] = 0;
	mpeg2fpga_core_poll_status(&ctx->core, &status);

	KUNIT_EXPECT_FALSE(test, status.picture_hdr);	/* this read saw nothing */
	KUNIT_EXPECT_EQ(test, mpeg2fpga_core_get_sticky(&ctx->core),
			MPEG2FPGA_STATUS_PICTURE_HDR | MPEG2FPGA_STATUS_FRAME_END);

	mpeg2fpga_core_clear_sticky(&ctx->core);
	KUNIT_EXPECT_EQ(test, mpeg2fpga_core_get_sticky(&ctx->core), 0u);
}


/*
 * Trick mode -- what turns the decoder from "one stream per reset" into
 * something that can be driven continuously. Measured on hardware: pushing a
 * second stream after flush_vbuf works with no core reset (704x480 to 720x576,
 * video_ch raised, error 0), and repeat_frame=31 takes framestore writes from
 * 130/s to 0/s and back without tripping the watchdog.
 */

static u32 trick_repeat_field(u32 trick)
{
	return (trick & MPEG2FPGA_TRICK_MODE_REPEAT_FRAME_MASK) >>
		MPEG2FPGA_TRICK_MODE_REPEAT_FRAME_SHIFT;
}

static void mpeg2fpga_core_test_init_keeps_persistence(struct kunit *test)
{
	struct mpeg2fpga_core_test_ctx *ctx = test->priv;
	u32 trick = ctx->fake.write_regs[MPEG2FPGA_W_TRICK_MODE];

	/* persistence is 1 at reset; losing it turns "hold the last picture"
	 * into "go black" the moment the decoder is starved.
	 */
	KUNIT_EXPECT_TRUE(test, trick & MPEG2FPGA_TRICK_MODE_PERSISTENCE);
	KUNIT_EXPECT_EQ(test, trick_repeat_field(trick), 0);
	KUNIT_EXPECT_EQ(test, mpeg2fpga_core_get_source_select(&ctx->core), 0);
	KUNIT_EXPECT_FALSE(test, mpeg2fpga_core_is_frozen(&ctx->core));
}

static void mpeg2fpga_core_test_freeze_round_trip(struct kunit *test)
{
	struct mpeg2fpga_core_test_ctx *ctx = test->priv;

	mpeg2fpga_core_set_freeze(&ctx->core, true);
	KUNIT_EXPECT_EQ(test,
		trick_repeat_field(ctx->fake.write_regs[MPEG2FPGA_W_TRICK_MODE]),
		MPEG2FPGA_TRICK_REPEAT_FRAME_FREEZE);
	KUNIT_EXPECT_TRUE(test, mpeg2fpga_core_is_frozen(&ctx->core));
	/* freezing must not cost persistence */
	KUNIT_EXPECT_TRUE(test, ctx->fake.write_regs[MPEG2FPGA_W_TRICK_MODE] &
			  MPEG2FPGA_TRICK_MODE_PERSISTENCE);

	mpeg2fpga_core_set_freeze(&ctx->core, false);
	KUNIT_EXPECT_EQ(test,
		trick_repeat_field(ctx->fake.write_regs[MPEG2FPGA_W_TRICK_MODE]), 0);
	KUNIT_EXPECT_FALSE(test, mpeg2fpga_core_is_frozen(&ctx->core));
}

static void mpeg2fpga_core_test_flush_vbuf_is_a_strobe(struct kunit *test)
{
	struct mpeg2fpga_core_test_ctx *ctx = test->priv;
	int first, second;

	mpeg2fpga_core_set_freeze(&ctx->core, true);
	ctx->fake.log_len = 0;

	mpeg2fpga_core_flush_vbuf(&ctx->core);

	/* raised once, then dropped -- otherwise the shadow carries a
	 * permanent flush into the next unrelated read-modify-write
	 */
	first = fake_write_index(&ctx->fake, MPEG2FPGA_W_TRICK_MODE, 0);
	KUNIT_ASSERT_GE(test, first, 0);
	second = fake_write_index(&ctx->fake, MPEG2FPGA_W_TRICK_MODE, first + 1);
	KUNIT_ASSERT_GE(test, second, 0);

	KUNIT_EXPECT_TRUE(test, ctx->fake.log[first].val &
			  MPEG2FPGA_TRICK_MODE_FLUSH_VBUF);
	KUNIT_EXPECT_FALSE(test, ctx->fake.log[second].val &
			   MPEG2FPGA_TRICK_MODE_FLUSH_VBUF);

	/* and everything else survives the strobe */
	KUNIT_EXPECT_TRUE(test, mpeg2fpga_core_is_frozen(&ctx->core));
	KUNIT_EXPECT_TRUE(test, ctx->fake.log[second].val &
			  MPEG2FPGA_TRICK_MODE_PERSISTENCE);
}

static void mpeg2fpga_core_test_source_select_preserves_freeze(struct kunit *test)
{
	struct mpeg2fpga_core_test_ctx *ctx = test->priv;
	u32 trick;

	mpeg2fpga_core_set_freeze(&ctx->core, true);
	mpeg2fpga_core_set_source_select(&ctx->core, MPEG2FPGA_SOURCE_BLANK);

	trick = ctx->fake.write_regs[MPEG2FPGA_W_TRICK_MODE];
	KUNIT_EXPECT_EQ(test, mpeg2fpga_core_get_source_select(&ctx->core),
			MPEG2FPGA_SOURCE_BLANK);
	KUNIT_EXPECT_EQ(test, trick_repeat_field(trick),
			MPEG2FPGA_TRICK_REPEAT_FRAME_FREEZE);
	KUNIT_EXPECT_TRUE(test, trick & MPEG2FPGA_TRICK_MODE_PERSISTENCE);

	/* framestore frame 2 is source_select 6 */
	mpeg2fpga_core_set_source_select(&ctx->core, MPEG2FPGA_SOURCE_FRAME_0 + 2);
	KUNIT_EXPECT_EQ(test, mpeg2fpga_core_get_source_select(&ctx->core), 6);

	mpeg2fpga_core_set_persistence(&ctx->core, false);
	trick = ctx->fake.write_regs[MPEG2FPGA_W_TRICK_MODE];
	KUNIT_EXPECT_FALSE(test, trick & MPEG2FPGA_TRICK_MODE_PERSISTENCE);
	KUNIT_EXPECT_EQ(test, mpeg2fpga_core_get_source_select(&ctx->core), 6);
}

static struct kunit_case mpeg2fpga_core_test_cases[] = {
	KUNIT_CASE(mpeg2fpga_core_test_init_sets_default_watchdog),
	KUNIT_CASE(mpeg2fpga_core_test_get_version),
	KUNIT_CASE(mpeg2fpga_core_test_read_status_parses_all_fields),
	KUNIT_CASE(mpeg2fpga_core_test_set_irq_mask_preserves_watchdog),
	KUNIT_CASE(mpeg2fpga_core_test_set_watchdog_preserves_irq_mask),
	KUNIT_CASE(mpeg2fpga_core_test_set_osd_enable_preserves_other_bits),
	KUNIT_CASE(mpeg2fpga_core_test_watchdog_disable),
	KUNIT_CASE(mpeg2fpga_core_test_core_enable),
	KUNIT_CASE(mpeg2fpga_core_test_dma_start_latches_before_trigger),
	KUNIT_CASE(mpeg2fpga_core_test_dma_status_unpacks),
	KUNIT_CASE(mpeg2fpga_core_test_geometry),
	KUNIT_CASE(mpeg2fpga_core_test_perf_counters),
	KUNIT_CASE(mpeg2fpga_core_test_frame_rate_table),
	KUNIT_CASE(mpeg2fpga_core_test_status_sticky_accumulates),
	KUNIT_CASE(mpeg2fpga_core_test_init_keeps_persistence),
	KUNIT_CASE(mpeg2fpga_core_test_freeze_round_trip),
	KUNIT_CASE(mpeg2fpga_core_test_flush_vbuf_is_a_strobe),
	KUNIT_CASE(mpeg2fpga_core_test_source_select_preserves_freeze),
	{}
};

static struct kunit_suite mpeg2fpga_core_test_suite = {
	.name = "mpeg2fpga_core",
	.init = mpeg2fpga_core_test_init,
	.test_cases = mpeg2fpga_core_test_cases,
};

kunit_test_suite(mpeg2fpga_core_test_suite);

MODULE_LICENSE("GPL");
