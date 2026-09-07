/*
 * mem2axi_bridge.v
 *
 * mpeg2video memory-controller interface <-> AXI4 master bridge (Fase 6a).
 *
 * mpeg2video's external memory interface (mem_req_rd_ and mem_res_wr_, see
 * framestore.v/framestore_request.v/mem_codes.v) is not AXI: it is a single
 * combined read+write command queue -- {cmd[1:0], addr[21:0], dta[63:0]}
 * popped one 64-bit word at a time -- with read responses returned, in
 * request order, on a second, data-only queue. mem_req_rd_addr is a 22-bit
 * *word* address (64-bit words) inside mpeg2video's private ~32 MB window
 * (see mem_codes.v); it carries no notion of a wider physical address space.
 *
 * This module plays the role of mpeg2video's memory controller (compare
 * bench/iverilog/mem_ctl.v, the behavioral stand-in used in simulation): it
 * pops one request at a time -- fully serialized, a single AXI4 transaction
 * outstanding, fixed id 0 -- translates the word address to a byte address
 * inside a fixed, caller-supplied DDR_BASE window of the real DDR4
 * (axi_addr = DDR_BASE + addr*8), and issues single-beat (len=0) 64-bit
 * AXI4 reads/writes on the fabric-master side of the MSS's FIC_1_AXI4_TARGET
 * port (Fase 6b: FIC_1 was chosen over FIC_0 because FIC_0's fabric-master
 * path is already in use by DMA_CONTROLLER/DMA_INITIATOR in the base
 * reference-design MSS config we reuse, while FIC_1_AXI4_TARGET is
 * explicitly marked unused there -- a free resource, same reasoning as
 * reusing the free FIC_3 APB slot in Fase 5b). Fully serialized (rather
 * than pipelined) is a deliberate first cut for correctness; if the real
 * FIC_1/DDR4 round-trip latency turns out to starve the decoder, pipelining
 * multiple outstanding requests (distinct AXI ids) is the next lever,
 * without changing this module's interface. AWID/ARID are 4 bits wide to
 * match FIC_1_AXI4_TARGET's actual ID width (see MSS_WRAPPER.tcl) -- this
 * bridge only ever drives id 0, so any width would technically work, but
 * matching avoids relying on Libero's bus-width auto-connect behavior.
 *
 * CMD_REFRESH/CMD_NOOP are acknowledged without any AXI transaction:
 * mpeg2fpga is built with REFRESH_EN=1'b0 (see framestore_request.v), so
 * DRAM refresh is left entirely to the MSS's own DDR4 controller and
 * CMD_REFRESH is never actually issued in practice.
 *
 * clk MUST be mpeg2video's own internal mem_clk (exposed as mem_clk_out,
 * see mpeg2video.v) -- not a second, independently generated PLL/CCC output
 * (e.g. CLOCKS_AND_RESETS's FIC_1_CLK). mem_req_rd_ and mem_res_wr_ are
 * documented "clocked with mem_clk" directly against mpeg2video's own
 * internal mem_clk domain (framestore.v's dual-clock FIFOs only cross
 * clk<->mem_clk, nothing further) -- feeding this bridge, and therefore
 * MSS_WRAPPER's FIC_1_ACLK, from any other clock would silently reintroduce
 * an unsynchronized-clock bug of exactly the kind Fase 5b/5d hit (see
 * docs/bringup/06_mss_integration_fase5b.md,
 * docs/bringup/09_fase5d_hardware_hang_investigation.md).
 *
 * DDR_BASE must be 32 MiB aligned (addr<<3 spans 25 bits) so the address
 * translation never carries into bits the firmware side doesn't expect to
 * move.
 *
 * Read pipelining (2026-09-06, Fase 8a -- optimizing decode rate, see
 * decode_rate_bottleneck memory / this module's own comment above naming
 * "multiple outstanding transactions" as the next lever): reads no longer
 * block the state machine until RDATA returns. Once an AR is accepted,
 * `state` goes straight back to S_IDLE so the next request can be popped
 * from mem_req_rd immediately -- up to RESP_DEPTH reads can now be
 * in-flight-or-buffered at once. This needed neither distinct AXI ids nor
 * touching mem_tag_fifo/framestore.v as originally guessed: every read still
 * uses id 0, and AXI4 guarantees transactions sharing an id complete in
 * issue order, so RDATA always arrives in the same order the reads were
 * requested -- exactly the order mem_res_wr must reproduce -- with no
 * per-transaction bookkeeping needed on this end. rd_outstanding counts
 * ARs issued but not yet answered; resp_buf is a small local FIFO (separate
 * from mem_response_fifo downstream) holding RDATA that has arrived but not
 * yet been pushed into mem_res_wr, absorbing mem_res_wr_almost_full without
 * stalling the AXI R channel for the whole backpressure window.
 *
 * Writes stay exactly as serialized as before -- deliberately not pipelined.
 * Two commands to the same address, program-order READ-then-WRITE or
 * WRITE-then-READ, need that order preserved against the real DDR4 access,
 * and AXI4 makes no ordering promise between a read and a write even sharing
 * an id (only among transactions of the same *type* and id). So a WRITE may
 * only start once rd_outstanding is back to 0 -- i.e. every earlier read has
 * actually been answered by the memory, not merely issued -- and, as before,
 * nothing else is issued while a write's AW/W/BRESP is outstanding. Two
 * reads never have this problem: neither mutates memory, so returning their
 * data out of *request* order relative to each other cannot happen (same id
 * forbids it) and would not matter if it somehow did.
 *
 * Graceful-abort fix (2026-08-26, same investigation as stream_dma.v's --
 * see its header comment for the full mechanism and docs/bringup/
 * 24_fase7a_fwft_fix_and_axi4_interconnect_wedge.md): `rst` used to be
 * mem_rst_internal (rst pin OR watchdog expiry). This module's own AXI4
 * master has the identical vulnerability stream_dma.v's had: FIC_1 and the
 * DDR controller are not in mpeg2video's watchdog reset domain, so
 * resetting `state` instantly while an AW/W/B or AR/R transaction is
 * outstanding (S_WRITE, S_BRESP, S_ARADDR, S_RDATA) abandons it -- confirmed
 * on real hardware (dbg_last_write_awaddr_issued reading back an
 * arithmetically-impossible 0 mid-stall, only explainable by this module's
 * `rst` firing again with the AXI4 side never having drained) and
 * reproduced in bench/mem_axi_bridge/testbench_wedge.v.
 *
 * `rst` is now the raw external hard reset only (mem_hard_rst_internal --
 * safe to apply instantly, since a real external reset also resets FIC_1/
 * the DDR controller). watchdog_rst is new -- a mem_clk-domain, watchdog-
 * only pulse (reset.v's mem_watchdog_rst; mpeg2video's own watchdog_rst
 * output lives in the *clk* domain, so it cannot be used directly here,
 * unlike stream_dma.v which shares clk with the watchdog). Unlike
 * stream_dma.v's abort_pending, which had to redirect several always
 * blocks, this module's AW/W/AR-channel registers and aw_done/w_done are
 * already driven purely by `case (state)` -- so deferring *only* `state`'s
 * own reset-application until no AXI4 obligation is outstanding is enough:
 * every other register just keeps following state's (now-safe)
 * transitions. See the `abort_pending`/`in_axi_obligation` block below.
 */

`include "timescale.v"

module mem2axi_bridge (
    clk, rst, watchdog_rst,

    /* mpeg2video memory-controller interface (mem_clk domain) */
    mem_req_rd_cmd, mem_req_rd_addr, mem_req_rd_dta, mem_req_rd_en, mem_req_rd_valid, mem_req_rd_empty,
    mem_res_wr_dta, mem_res_wr_en, mem_res_wr_almost_full,

    /* AXI4 master (FIC_1 fabric-master side). AWLOCK/AWCACHE/AWPROT/AWQOS/
     * AWREGION/AWUSER (and their AR/W/B/R counterparts) are part of the
     * AMBA4:AXI4:r0p0_0 bus definition's full signal set -- Libero's
     * bus-interface compatibility check requires the complete set to be
     * present to connect to MSS_WRAPPER's FIC_1_AXI4_TARGET, even though
     * this bridge only ever drives them to fixed, unused values. */
    m_axi_awid, m_axi_awaddr, m_axi_awlen, m_axi_awsize, m_axi_awburst, m_axi_awlock, m_axi_awcache, m_axi_awprot, m_axi_awqos, m_axi_awregion, m_axi_awuser, m_axi_awvalid, m_axi_awready,
    m_axi_wdata, m_axi_wstrb, m_axi_wlast, m_axi_wuser, m_axi_wvalid, m_axi_wready,
    m_axi_bid, m_axi_bresp, m_axi_buser, m_axi_bvalid, m_axi_bready,
    m_axi_arid, m_axi_araddr, m_axi_arlen, m_axi_arsize, m_axi_arburst, m_axi_arlock, m_axi_arcache, m_axi_arprot, m_axi_arqos, m_axi_arregion, m_axi_aruser, m_axi_arvalid, m_axi_arready,
    m_axi_rid, m_axi_rdata, m_axi_rresp, m_axi_rlast, m_axi_ruser, m_axi_rvalid, m_axi_rready,

    /* Fase 7a debug (2026-08-23) */
    dbg_last_write_addr_from_fifo, dbg_last_write_awaddr_issued,
    dbg_first_rdata
);

  parameter [37:0] DDR_BASE = 38'h0;

  input            clk;
  input            rst;               // active low, synchronous, raw external hard reset only -- see header comment
  input            watchdog_rst;      // active low, synchronous, mem_clk-domain watchdog-only pulse (reset.v's mem_watchdog_rst)

  /* mpeg2video memory-controller interface */
  input       [1:0]mem_req_rd_cmd;
  input      [21:0]mem_req_rd_addr;
  input      [63:0]mem_req_rd_dta;
  output reg       mem_req_rd_en;
  input            mem_req_rd_valid;
  input            mem_req_rd_empty;
  output reg [63:0]mem_res_wr_dta;
  output reg       mem_res_wr_en;
  input            mem_res_wr_almost_full;

  /* AXI4 write address channel */
  output      [3:0]m_axi_awid;
  output reg [37:0]m_axi_awaddr;
  output      [7:0]m_axi_awlen;
  output      [2:0]m_axi_awsize;
  output      [1:0]m_axi_awburst;
  output           m_axi_awlock;
  output      [3:0]m_axi_awcache;
  output      [2:0]m_axi_awprot;
  output      [3:0]m_axi_awqos;
  output      [3:0]m_axi_awregion;
  output      [0:0]m_axi_awuser;
  output reg       m_axi_awvalid;
  input            m_axi_awready;

  /* AXI4 write data channel */
  output reg [63:0]m_axi_wdata;
  output      [7:0]m_axi_wstrb;
  output           m_axi_wlast;
  output      [0:0]m_axi_wuser;
  output reg       m_axi_wvalid;
  input            m_axi_wready;

  /* AXI4 write response channel */
  input       [3:0]m_axi_bid;
  input       [1:0]m_axi_bresp;
  input       [0:0]m_axi_buser;
  input            m_axi_bvalid;
  output           m_axi_bready;

  /* AXI4 read address channel */
  output      [3:0]m_axi_arid;
  output reg [37:0]m_axi_araddr;
  output      [7:0]m_axi_arlen;
  output      [2:0]m_axi_arsize;
  output      [1:0]m_axi_arburst;
  output           m_axi_arlock;
  output      [3:0]m_axi_arcache;
  output      [2:0]m_axi_arprot;
  output      [3:0]m_axi_arqos;
  output      [3:0]m_axi_arregion;
  output      [0:0]m_axi_aruser;
  output reg       m_axi_arvalid;
  input            m_axi_arready;

  /* AXI4 read data channel */
  input       [3:0]m_axi_rid;
  input      [63:0]m_axi_rdata;
  input       [1:0]m_axi_rresp;
  input            m_axi_rlast;
  input       [0:0]m_axi_ruser;
  input            m_axi_rvalid;
  output           m_axi_rready;

  /* fixed, single-outstanding-transaction attributes: id 0, single 64-bit
   * beat (len=0), 8 bytes/beat, incrementing burst (irrelevant at len=0,
   * INCR is the safe default every AXI4 slave accepts). AWLOCK/AWCACHE/
   * AWPROT/AWQOS/AWREGION/AWUSER (and AR counterparts) are tied to their
   * "normal, non-secure, no special caching" defaults -- this bridge has no
   * use for any of them, they exist only because the AXI4 bus definition
   * requires the full signal set (see the module port list comment). */
  assign m_axi_awid     = 4'd0;
  assign m_axi_awlen    = 8'd0;
  assign m_axi_awsize   = 3'b011;
  assign m_axi_awburst  = 2'b01;
  assign m_axi_awlock   = 1'b0;
  assign m_axi_awcache  = 4'b0000;
  assign m_axi_awprot   = 3'b000;
  assign m_axi_awqos    = 4'b0000;
  assign m_axi_awregion = 4'b0000;
  assign m_axi_awuser   = 1'b0;
  assign m_axi_wstrb    = 8'hff;
  assign m_axi_wlast    = 1'b1;
  assign m_axi_wuser    = 1'b0;
  assign m_axi_arid     = 4'd0;
  assign m_axi_arlen    = 8'd0;
  assign m_axi_arsize   = 3'b011;
  assign m_axi_arburst  = 2'b01;
  assign m_axi_arlock   = 1'b0;
  assign m_axi_arcache  = 4'b0000;
  assign m_axi_arprot   = 3'b000;
  assign m_axi_arqos    = 4'b0000;
  assign m_axi_arregion = 4'b0000;
  assign m_axi_aruser   = 1'b0;

`include "mem_codes.v"

  localparam [2:0]
    S_IDLE   = 3'd0,   // popping mem_req_rd; mem_req_rd_en asserted
    S_LATCH  = 3'd1,   // mem_req_rd_valid seen last cycle; cmd_r/addr_r/dta_r valid, decode cmd
    S_WRITE  = 3'd2,   // AW/W outstanding, waiting on awready/wready
    S_BRESP  = 3'd3,   // waiting on bvalid
    S_ARADDR = 3'd4;   // AR outstanding, waiting on arready -- RDATA itself is no longer
                        // waited on here, see rd_outstanding/resp_buf below

  reg [2:0]state;
  reg [2:0]next;

  reg  [1:0]cmd_r;
  reg [21:0]addr_r;
  reg [63:0]dta_r;

  reg       aw_done;   // AWREADY already seen this transaction
  reg       w_done;    // WREADY already seen this transaction

  wire [37:0]axi_addr = DDR_BASE + {addr_r, 3'b000};

  /* read pipelining -- see header comment. ar_hs/r_hs are the AR/R channel
   * handshakes; RESP_DEPTH bounds both how many reads may be outstanding at
   * once and the local buffer that decouples RDATA arrival from
   * mem_res_wr_almost_full. 4 is a first cut, not a hardware limit -- tune
   * against measured decode rate. */
  localparam [2:0] RESP_DEPTH = 3'd4;

  wire ar_hs = m_axi_arvalid && m_axi_arready;
  wire r_hs  = m_axi_rvalid  && m_axi_rready;

  reg [2:0] rd_outstanding;   // ARs accepted but not yet answered by RDATA

  /* resp_buf: small local FIFO (RESP_DEPTH entries, indices mod RESP_DEPTH)
   * holding RDATA that has arrived but not yet been pushed into mem_res_wr.
   * Pushed by r_hs, popped whenever mem_res_wr has room and the buffer is
   * non-empty -- both can happen the same cycle. Responses are pushed and
   * popped in strict arrival order, which -- because every read shares AXI
   * id 0 -- is also request order (see header comment), matching what
   * mem_res_wr must reproduce. */
  reg [63:0] resp_buf [0:RESP_DEPTH-1];
  reg  [1:0] resp_wptr, resp_rptr;
  reg  [2:0] resp_count;

  wire resp_pop = (resp_count != 3'd0) && !mem_res_wr_almost_full;

  /* next-state logic */
  always @* begin
    case (state)
      S_IDLE:   next = mem_req_rd_valid ? S_LATCH : S_IDLE;
      S_LATCH:  case (cmd_r)
                  // a write must wait for every earlier read to actually be
                  // answered (not merely issued) before touching memory --
                  // see header comment
                  CMD_WRITE: next = (rd_outstanding == 3'd0) ? S_WRITE : S_LATCH;
                  // a further read only needs room in the local pipeline --
                  // it cannot race a write or another read incorrectly
                  CMD_READ:  next = (rd_outstanding < RESP_DEPTH) ? S_ARADDR : S_LATCH;
                  default:   next = S_IDLE;      // CMD_NOOP / CMD_REFRESH: no AXI transaction
                endcase
      S_WRITE:  next = ((aw_done || m_axi_awready) && (w_done || m_axi_wready)) ? S_BRESP : S_WRITE;
      S_BRESP:  next = m_axi_bvalid ? S_IDLE : S_BRESP;
      S_ARADDR: next = m_axi_arready ? S_IDLE : S_ARADDR;   // don't wait for RDATA here anymore
      default:  next = S_IDLE;
    endcase
  end

  /* an AXI4 obligation is outstanding -- AW/W/B issued or accepted-but-
   * unacked (S_WRITE/S_BRESP), AR issued/accepted-but-unacked (S_ARADDR), or
   * any read whose AR was already accepted but whose RDATA has not yet come
   * back (rd_outstanding != 0 -- since Fase 8a's read pipelining, this is no
   * longer reflected in `state` at all, which returns to S_IDLE right after
   * the AR handshake) -- and state must not be clobbered by a deferred
   * watchdog reset until it clears. Data already sitting in resp_buf,
   * waiting only on mem_res_wr_almost_full, carries no such obligation: the
   * AXI4 side of that read is already fully done, same reasoning the old
   * S_RESP state used. See header comment. */
  wire in_axi_obligation = (state == S_WRITE) || (state == S_BRESP) ||
                            (state == S_ARADDR) || (rd_outstanding != 3'd0);

  reg abort_pending;

  always @(posedge clk)
    if (~rst) abort_pending <= 1'b0;
    else if (!watchdog_rst) abort_pending <= 1'b1;
    else if (abort_pending && !in_axi_obligation) abort_pending <= 1'b0;

  always @(posedge clk)
    if (~rst) state <= S_IDLE;
    else if (abort_pending && !in_axi_obligation) state <= S_IDLE;
    else state <= next;

  /* Fase 7a debug (2026-08-23): bisect "mpeg2fpga -> fifo" from "fifo ->
   * memory" -- dbg_last_write_addr_from_fifo mirrors whatever address this
   * bridge actually receives from mem_request_fifo for the last WRITE
   * command popped (free-running, independent of the state machine, same
   * pattern as Fase 7c's pwdata_free_r); dbg_last_write_awaddr_issued
   * mirrors the AXI4 AWADDR that was actually accepted (awready) on the
   * real fabric. If the first reads back wrong, the bug is upstream of this
   * module (mpeg2fpga/wrapper/fifo); if it reads correct but the second
   * doesn't match DDR_BASE+addr*8, the bug is in this module or downstream
   * of it (AXI4 interconnect / DDR4 controller). mem_clk domain -- read out
   * through a real 2-FF synchronizer in apb3_mpeg2fpga_bridge.v. */
  output reg [21:0] dbg_last_write_addr_from_fifo;
  output reg [37:0] dbg_last_write_awaddr_issued;

  /* 2026-09-05: first 64-bit word ever returned by the AXI read channel.
   * The very first word handed to getbits.v is corrupted on a failing push
   * (docs/bringup 34) while DRAM reads back byte-perfect, so the corruption
   * lives somewhere on the read RETURN path. This is that path's first stage:
   * if dbg_first_rdata already differs from the stream's first 8 bytes, the
   * problem is at/below the MSS; if it is correct, the corruption happens
   * downstream in mem_response_fifo or framestore_response. mem_clk domain --
   * the APB bridge synchronises it, same as dbg_last_write_awaddr_issued. */
  output reg [63:0] dbg_first_rdata;
  reg               dbg_first_rdata_seen;

  always @(posedge clk)
    if (~rst) begin
      dbg_last_write_addr_from_fifo <= 22'b0;
      dbg_last_write_awaddr_issued  <= 38'b0;
    end else begin
      if (mem_req_rd_valid && (mem_req_rd_cmd == CMD_WRITE))
        dbg_last_write_addr_from_fifo <= mem_req_rd_addr;
      if (m_axi_awvalid && m_axi_awready)
        dbg_last_write_awaddr_issued <= m_axi_awaddr;
    end

  /* latch the popped request as soon as it is presented */
  always @(posedge clk)
    if (~rst) begin
      cmd_r  <= CMD_NOOP;
      addr_r <= 22'b0;
      dta_r  <= 64'b0;
    end else if ((state == S_IDLE) && mem_req_rd_valid) begin
      cmd_r  <= mem_req_rd_cmd;
      addr_r <= mem_req_rd_addr;
      dta_r  <= mem_req_rd_dta;
    end

  /* pop mem_req_rd fifo: assert rd_en for a single cycle per request, then
   * wait for that request's data to actually be captured before ever
   * asserting it again.
   *
   * 2026-08-26 (mem_req_wr_almost_full investigation, root cause #1): this
   * used to be `mem_req_rd_en <= (next == S_IDLE)` -- holding RE
   * continuously high through the entire idle period regardless of whether
   * the fifo had anything to give, not just for the one cycle a request
   * needs capturing. The real generated CoreFIFO controller for this
   * dual-clock async configuration (corefifo_async.v) breaks under that
   * usage: reproduced in bench/mem_response_corefifo/testbench.v's
   * req_fifo_test2 -- RE held high from an empty fifo through a 60-word
   * fill only ever delivers 3 words before EMPTY sticks high forever,
   * though the fifo genuinely still holds the other 57. Every other
   * fifo_dc consumer in this codebase already gates rd_en on ~empty
   * instead of holding it unconditionally, and none of them show this
   * failure -- matching that working pattern here fixed *that* failure
   * mode. mem_req_rd_empty is framestore.v's mem_request_fifo's own
   * `empty` output (mem_clk domain, same as this module -- no CDC needed),
   * previously left unconnected.
   *
   * Root cause #2, found after #1 stopped reproducing the EMPTY-stuck
   * failure but a *different* one appeared (bench/mem_response_corefifo's
   * e2e_fix_test: real CoreFIFO's rptr correctly reaches 60 -- fifo drains
   * completely, EMPTY behaves -- but only ~31/60 requests actually turn
   * into AXI4 transactions): gating on `!mem_req_rd_empty` alone still
   * lets rd_en re-assert on back-to-back cycles, because `next` keeps
   * reading S_IDLE (mem_req_rd_valid hasn't arrived yet -- CoreFIFO's
   * PIPE:1/READ_DVALID registers it one cycle after RE) right up until the
   * cycle valid finally arrives. That extra cycle's rd_en pulse pops a
   * *second* fifo word while the first one's data is still in flight;
   * when the first word's valid/dout arrive and get captured into cmd_r/
   * addr_r/dta_r, the second word's Q/DVLD arrive one cycle later with
   * state already at S_LATCH -- outside the `state == S_IDLE` capture
   * window -- and are silently dropped. Adding `&& !mem_req_rd_en` makes
   * rd_en a strict one-cycle-then-wait pulse: it can never fire two
   * cycles in a row, so at most one fifo word is ever popped before its
   * result is captured, matching CoreFIFO's one-cycle read latency
   * exactly. Verified in e2e_fix_test: rptr reaches 60 and all 60 turn
   * into completed AXI4 writes (was 31/60 without this). */
  always @(posedge clk)
    if (~rst) mem_req_rd_en <= 1'b0;
    else mem_req_rd_en <= (next == S_IDLE) && !mem_req_rd_empty && !mem_req_rd_en;

  /* AXI write address/data channels */
  always @(posedge clk)
    if (~rst) begin
      m_axi_awvalid <= 1'b0;
      m_axi_awaddr  <= 38'b0;
      m_axi_wvalid  <= 1'b0;
      m_axi_wdata   <= 64'b0;
      aw_done       <= 1'b0;
      w_done        <= 1'b0;
    end else case (state)
      S_LATCH: begin
        aw_done <= 1'b0;
        w_done  <= 1'b0;
        if (next == S_WRITE) begin
          m_axi_awaddr  <= axi_addr;
          m_axi_awvalid <= 1'b1;
          m_axi_wdata   <= dta_r;
          m_axi_wvalid  <= 1'b1;
        end
      end
      S_WRITE: begin
        if (m_axi_awvalid && m_axi_awready) begin
          m_axi_awvalid <= 1'b0;
          aw_done       <= 1'b1;
        end
        if (m_axi_wvalid && m_axi_wready) begin
          m_axi_wvalid <= 1'b0;
          w_done       <= 1'b1;
        end
      end
      default: begin
        m_axi_awvalid <= 1'b0;
        m_axi_wvalid  <= 1'b0;
      end
    endcase

  /* 2026-08-27: was (state == S_BRESP) -- state only reaches S_BRESP one
   * cycle after AW/W actually complete (next decides S_BRESP combinationally
   * off aw_done/w_done/awready/wready, state registers it the following
   * edge), so BREADY used to trail the AW/W handshake by a cycle. Confirmed
   * on real hardware (SmartDebug Active Probes): the FSM sits in S_BRESP
   * forever, AWVALID/WVALID both already low (accepted), BVALID never
   * arrives. AXI4 requires a slave to hold VALID until READY is seen, so a
   * spec-compliant slave shouldn't be affected either way -- but this
   * bridge is single-outstanding and has no other use for the cycle BREADY
   * would otherwise withhold, so there is no reason to gate it on state at
   * all. Holding it unconditionally high removes any chance of a real
   * slave's BVALID window being missed by one cycle, at zero cost. */
  assign m_axi_bready = 1'b1;

  /* AXI read address channel */
  always @(posedge clk)
    if (~rst) begin
      m_axi_arvalid <= 1'b0;
      m_axi_araddr  <= 38'b0;
    end else case (state)
      S_LATCH: if (next == S_ARADDR) begin
        m_axi_araddr  <= axi_addr;
        m_axi_arvalid <= 1'b1;
      end
      S_ARADDR: if (m_axi_arvalid && m_axi_arready) m_axi_arvalid <= 1'b0;
      default:  m_axi_arvalid <= 1'b0;
    endcase

  /* RREADY now genuinely gates on buffer room -- unlike the old
   * single-outstanding design, RDATA can arrive while this bridge still has
   * an earlier result parked in resp_buf waiting on mem_res_wr_almost_full,
   * so it is no longer always safe to accept the next beat immediately.
   * Deasserting RREADY simply makes the AXI4 slave hold RVALID, which is
   * spec-legal backpressure, not a hang. */
  assign m_axi_rready = (resp_count < RESP_DEPTH);

  always @(posedge clk)
    if (~rst)
      begin
        dbg_first_rdata      <= 64'b0;
        dbg_first_rdata_seen <= 1'b0;
      end
    else if (r_hs && ~dbg_first_rdata_seen)
      begin
        dbg_first_rdata      <= m_axi_rdata;
        dbg_first_rdata_seen <= 1'b1;
      end

  /* rd_outstanding: +1 per AR accepted, -1 per RDATA accepted into resp_buf.
   * Bounded to [0, RESP_DEPTH] by the S_LATCH/CMD_READ gate above. */
  always @(posedge clk)
    if (~rst) rd_outstanding <= 3'd0;
    else rd_outstanding <= rd_outstanding + (ar_hs ? 3'd1 : 3'd0) - (r_hs ? 3'd1 : 3'd0);

  always @(posedge clk)
    if (~rst) begin
      resp_wptr  <= 2'd0;
      resp_rptr  <= 2'd0;
      resp_count <= 3'd0;
    end else begin
      if (r_hs) begin
        resp_buf[resp_wptr] <= m_axi_rdata;
        resp_wptr <= resp_wptr + 2'd1;
      end
      if (resp_pop) resp_rptr <= resp_rptr + 2'd1;
      resp_count <= resp_count + (r_hs ? 3'd1 : 3'd0) - (resp_pop ? 3'd1 : 3'd0);
    end

  always @(posedge clk)
    if (~rst) begin
      mem_res_wr_dta <= 64'b0;
      mem_res_wr_en  <= 1'b0;
    end else begin
      mem_res_wr_en <= resp_pop;
      if (resp_pop) mem_res_wr_dta <= resp_buf[resp_rptr];
    end

`undef CHECK
`ifdef __IVERILOG__
`define CHECK 1
`endif

`ifdef CHECK
  always @(posedge clk)
    if ((state == S_BRESP) && m_axi_bvalid && (m_axi_bresp != 2'b00))
      $display("%m\t*** warning: AXI write to %h got BRESP %b (not OKAY) ***", m_axi_awaddr, m_axi_bresp);

  always @(posedge clk)
    if (r_hs && (m_axi_rresp != 2'b00))
      // m_axi_araddr no longer identifies this specific transaction under
      // read pipelining (the AR channel may already be issuing a later
      // read), so it is deliberately omitted here.
      $display("%m\t*** warning: AXI read got RRESP %b (not OKAY) ***", m_axi_rresp);

  always @(posedge clk)
    if (r_hs && ~m_axi_rlast)
      begin
        $display("%m\t*** error: single-beat read did not see RLAST ***");
        $stop;
      end
`endif

endmodule
/* not truncated */
