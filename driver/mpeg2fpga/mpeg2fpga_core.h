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
	/* @trick_shadow: the same problem for MPEG2FPGA_W_TRICK_MODE. Seeded
	 * with the hardware's reset value, which has persistence set --
	 * clobbering that turns "hold the last picture when starved" into
	 * "go black".
	 */
	u32 trick_shadow;
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

/**
 * struct mpeg2fpga_perf_counters - free-running cycle counters, core_clk domain
 *
 * All five wrap silently and never reset on their own (framestore_request.v's
 * arbiter -- see its header comment); only deltas between two reads mean
 * anything, e.g. bracketing one decode with two reads of this attribute.
 * Meant to answer "where did the cycles go", the same question a slower
 * decode rate raises: sum @disp_service_cnt + @vbr_service_cnt over an
 * interval and compare against the core_clk cycles that interval took
 * (elapsed wall time * the known 108 MHz core clock, since there is no
 * software-readable free-running cycle counter -- mpeg2video.v's cnt_clk is
 * SmartDebug-probe-only, not wired to the APB map) to see how much of the
 * core was actually busy versus idle, and @vbr_starved_cnt to see whether
 * the VLD went hungry waiting on the video buffer while it did.
 *
 * @disp_service_cnt: cycles the framestore arbiter spent servicing the
 *	display (resample/OSD) path
 * @vbr_service_cnt: cycles spent servicing vbuf_read_fifo (feeding the VLD)
 * @vbr_starved_cnt: cycles the VLD wanted a vbuf read serviced but the
 *	arbiter picked something else instead
 * @mem_res_valid_cnt: cycles mem2axi_bridge (or mem_ctl.v in simulation)
 *	presented a valid memory response -- the read-side occupancy of the
 *	single external memory port, across every consumer (vbuf, motion
 *	compensation, display)
 * @write_service_cnt: cycles the framestore arbiter spent servicing a
 *	write -- STATE_VBW (incoming stream bytes), STATE_RECON (reconstructed
 *	macroblock), or STATE_OSD (overlay), combined. Added in Fase 8b
 *	alongside the other three, which cover the read side fairly well
 *	between them and mem_res_valid_cnt above; the write side had no
 *	counter at all before this, sticky or otherwise.
 * @fwd_service_cnt: cycles the arbiter spent servicing a forward
 *	motion-compensation reference read (STATE_FWD). Added once
 *	disp+vbr+write_service+mem_res_valid_cnt left ~75-80% of cycles
 *	unaccounted for even after both read and write pipelining -- the
 *	arbiter's states are one-hot and mutually exclusive, so the remainder
 *	has to be fwd/bwd service time (their read *responses* were already
 *	in mem_res_valid_cnt, but never their own arbiter service time) or
 *	genuine idle time.
 * @bwd_service_cnt: same as @fwd_service_cnt, for STATE_BWD (backward
 *	motion-compensation reference reads).
 * @idle_cnt: cycles the arbiter had nothing ready to service (STATE_IDLE).
 *	Measured directly rather than inferred by subtracting the other
 *	counters from an already-estimated cycle total (wall clock * the
 *	known 108 MHz core clock -- there is still no software-readable
 *	free-running cycle counter), so it settles the fwd/bwd-vs-idle
 *	question without compounding that estimate's own rounding error.
 * @vld_en_cnt: cycles getbits.v's vld_en is asserted, i.e. the VLD is
 *	actually allowed to advance. Added once idle_cnt confirmed the
 *	memory arbiter has plenty of headroom (docs/bringup 43) -- the
 *	bottleneck moved upstream into this module's own compute pipeline,
 *	which vld_en gates: `vld_en = ready && ~wait_state &&
 *	~rld_wr_almost_full && ~mvec_wr_almost_full && ~motcomp_busy`.
 * @vld_stall_rld_cnt: cycles VLD was stalled specifically because
 *	rld_wr_almost_full (the rld/iquant/idct reconstruction chain backed
 *	up) -- one of vld_en's four stall reasons.
 * @vld_stall_motcomp_cnt: cycles VLD was stalled specifically because
 *	motcomp_busy (motcomp's own input fifo full -- its reconstruction,
 *	not memory: fwd/bwd reference reads are already known small).
 *	mvec_wr_almost_full and the getbits/wait_state stall reason are left
 *	to be inferred as whatever remainder these two plus @vld_en_cnt
 *	don't account for.
 * @fwd_addr_empty_cnt: cycles framestore_request.v's do_fwd had nothing to
 *	service because the fwd reference-read address fifo was empty --
 *	i.e. motcomp_addrgen.v/mem_addr.v (upstream of the memory arbiter
 *	entirely) hadn't queued a forward-reference read yet. Added
 *	(Fase 8d) to split @vld_stall_motcomp_cnt's "motcomp busy" finding
 *	into two very different possible causes with two very different
 *	fixes: address generation not keeping up (this counter), versus the
 *	fetch pipeline not draining once addresses are queued
 *	(@fwd_dta_stall_cnt below).
 * @fwd_dta_stall_cnt: cycles a fwd address WAS queued (fifo non-empty) but
 *	the arbiter withheld service anyway because the fwd return-data fifo
 *	was almost full -- i.e. the consumer (motcomp_recon) isn't draining
 *	fetched reference pixels fast enough.
 * @bwd_addr_empty_cnt: same as @fwd_addr_empty_cnt, for STATE_BWD.
 * @bwd_dta_stall_cnt: same as @fwd_dta_stall_cnt, for STATE_BWD.
 * @mem_req_almost_full_cnt: cycles mem_req_wr_almost_full is asserted --
 *	the arbiter's own outgoing queue toward mem2axi_bridge is nearly
 *	full. Added (Fase 8e) after @fwd_addr_empty_cnt/@fwd_dta_stall_cnt
 *	both came back exactly 0 on real hardware: do_fwd's first two AND
 *	terms are essentially always satisfied, yet fwd is serviced only
 *	~1% of the time and the arbiter sits idle ~94% of the time. This
 *	and @tag_almost_full_cnt are the two remaining AND terms do_fwd (and
 *	nearly every other request type) shares -- if either is asserted
 *	almost all the time, it directly explains @idle_cnt and reverses the
 *	Fase 8b reading that idle time meant memory headroom.
 * @tag_almost_full_cnt: cycles tag_wr_almost_full is asserted -- the
 *	arbiter's own tag-routing queue (mem_tag_fifo) is nearly full.
 *	Measured on real hardware at 76.9%% of all cycles during a full
 *	decode, dwarfing @mem_req_almost_full_cnt's 0.8%% -- mem_tag_fifo's
 *	early-warning threshold (not mem_request_fifo's, not any data fifo,
 *	not memory latency) was what actually gated nearly every read.
 *	Fase 9a raised MEMTAG_THRESHOLD in response (fifo_size.v), which cut
 *	this to ~66%% on real hardware but did not change fps or
 *	@vld_stall_rld_cnt/@vld_stall_motcomp_cnt's combined share --
 *	i.e. the arbiter had headroom to spare all along, and relieving it
 *	didn't help; see @predict_err_almost_full_cnt for where that pointed
 *	next.
 * @predict_err_almost_full_cnt: cycles idct_fifo_almost_full is asserted --
 *	predict_err_fifo (idct.v's output, motcomp_recon's input) is nearly
 *	full. Added (Fase 9b) after Fase 9a's fix moved @tag_almost_full_cnt
 *	without moving fps, pointing the investigation downstream of the
 *	memory arbiter entirely, into the reconstruction pipeline. rld.v
 *	already wires idct_fifo_almost_full into its own internal stall
 *	logic (independently of this driver); this just exposes that
 *	existing signal for correlation against @vld_stall_rld_cnt.
 * @rld_stall_predict_err_cnt: cycles ~vld_en && rld_wr_almost_full &&
 *	idct_fifo_almost_full -- the overlap between @vld_stall_rld_cnt (VLD
 *	stalled because rld_fifo is nearly full) and predict_err_fifo also
 *	being nearly full at the same moment. Measured on real hardware at
 *	78.4%% of @vld_stall_rld_cnt's own window -- i.e. rld_wr_almost_full
 *	is itself mostly caused by motcomp_recon not draining
 *	predict_err_fifo fast enough, not by rld/iquant/idct's own
 *	processing throughput. Combined with @vld_stall_motcomp_cnt (motcomp
 *	busy directly), this places the real bottleneck inside
 *	motcomp_recon.v/motcomp.v's own reconstruction rate, not memory --
 *	the memory arbiter's own counters above all show ample headroom.
 */
struct mpeg2fpga_perf_counters {
	u32 disp_service_cnt;
	u32 vbr_service_cnt;
	u32 vbr_starved_cnt;
	u32 mem_res_valid_cnt;
	u32 write_service_cnt;
	u32 fwd_service_cnt;
	u32 bwd_service_cnt;
	u32 idle_cnt;
	u32 vld_en_cnt;
	u32 vld_stall_rld_cnt;
	u32 vld_stall_motcomp_cnt;
	u32 fwd_addr_empty_cnt;
	u32 fwd_dta_stall_cnt;
	u32 bwd_addr_empty_cnt;
	u32 bwd_dta_stall_cnt;
	u32 mem_req_almost_full_cnt;
	u32 tag_almost_full_cnt;
	u32 predict_err_almost_full_cnt;
	u32 rld_stall_predict_err_cnt;
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

void mpeg2fpga_core_get_perf_counters(struct mpeg2fpga_core *core,
				       struct mpeg2fpga_perf_counters *perf);

/*
 * Trick mode -- what makes the decoder usable continuously rather than one
 * stream per reset. doc/mpeg2fpga.txt sec 1.11.
 */

/* Clear the incoming video buffer. The documentation's own words: "useful
 * when changing channels". Doing this between streams is what replaces
 * resetting the whole core.
 */
void mpeg2fpga_core_flush_vbuf(struct mpeg2fpga_core *core);

/* Freeze on the current picture. repeat_frame=31 halts the decoder, and the
 * watchdog is held off while it is frozen, so a pause cannot trip a reset.
 */
void mpeg2fpga_core_set_freeze(struct mpeg2fpga_core *core, bool freeze);
bool mpeg2fpga_core_is_frozen(struct mpeg2fpga_core *core);

/* 0 shows the last decoded frame, 1 a blank screen, 4-7 framestore frame 0-3. */
void mpeg2fpga_core_set_source_select(struct mpeg2fpga_core *core, u8 source);
u8 mpeg2fpga_core_get_source_select(struct mpeg2fpga_core *core);

/* When starved: hold the last picture (true) or go blank (false). */
void mpeg2fpga_core_set_persistence(struct mpeg2fpga_core *core, bool on);
u32 mpeg2fpga_core_frame_rate_millihz(u8 code, u8 extension_n, u8 extension_d);

#endif /* MPEG2FPGA_CORE_H */
