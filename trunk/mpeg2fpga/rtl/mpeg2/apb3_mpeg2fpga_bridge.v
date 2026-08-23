/*
 * apb3_mpeg2fpga_bridge.v
 *
 * APB3 slave <-> mpeg2video register-file bridge, with clock-domain crossing.
 *
 * mpeg2video's register interface (reg_addr[3:0], reg_wr_en, reg_rd_en,
 * reg_dta_in[31:0], reg_dta_out[31:0], see doc/mpeg2fpga.txt sec. 1.2.4/1.4)
 * is not APB-compliant: it has no PSEL/PENABLE/PREADY handshake, and reads
 * and writes at the same reg_addr access two independent 16-register banks
 * selected purely by which strobe (reg_rd_en/reg_wr_en) is pulsed.
 *
 * mpeg2video is expected to run on its own PF_CCC_C0-derived "clk" domain
 * (see mpeg2video.v), separate from whatever clock the fabric APB bus (e.g.
 * FIC_3) runs on. Rather than touch the core's existing, already-verified
 * clocking, this bridge crosses the domain boundary itself, using a
 * two-phase (toggle) handshake: safe for any clock ratio, appropriate for a
 * low-frequency control/status interface (not a data path).
 *
 * Read latency note (regfile.v): reg_dta_out is a registered output that
 * updates on the clk edge *after* reg_rd_en is sampled high -- one extra
 * core_clk cycle must be waited before reg_dta_out is valid.
 *
 * Fase 7a: a 17th address, STREAM_PUSH_ADDR (index 0x10, one past the
 * regfile's 16 registers -- PADDR widened by one index bit to fit it),
 * pushes one byte at a time onto mpeg2video's stream_data/stream_valid
 * port pair. That pair is a raw top-level port of mpeg2video (see
 * mpeg2video.v), entirely separate from the reg_addr-based register file
 * that regfile.v implements -- deliberately routed around regfile.v/
 * mpeg2video.v rather than adding a case arm to either, since both are
 * upstream-licensed IP (see rtl/mpeg2/LICENSE-MPEG2) CLAUDE.md asks to
 * keep close to upstream. A write to STREAM_PUSH_ADDR only completes (only
 * asserts PREADY) once mpeg2video's own "busy" output (asserted when the
 * input FIFO risks overflow) is low -- APB's own wait-state mechanism
 * becomes the flow control, no separate polling register needed.
 *
 * Fase 7c adds four more addresses -- DMA_ADDR/DMA_LEN/DMA_CTRL/DMA_STATUS
 * (0x11-0x14) -- that control stream_dma.v (a hardware streamer reading a
 * DDR staging buffer over its own AXI4 master, feeding stream_data/
 * stream_valid autonomously instead of one byte per APB write). Because
 * stream_dma.v already lives in core_clk (see its header comment), these
 * registers need no CDC beyond the toggle-handshake this bridge already
 * runs for every other address: DMA_ADDR/DMA_LEN writes just latch a
 * holding register here on the same edge a regfile write would, DMA_CTRL's
 * start bit pulses stream_dma's `start` input directly (ignored if a
 * transfer is already running -- software is expected to poll DMA_STATUS
 * first, not blocked on it the way STREAM_PUSH_ADDR blocks on `busy`), and
 * DMA_STATUS reads stream_dma's busy/done/bytes_done outputs -- also plain
 * core_clk wires, needing none of STREAM_PUSH_ADDR/regfile's C_READ_WAIT1/
 * C_READ_WAIT2 (those exist only to accommodate regfile.v's output being
 * registered one cycle after reg_rd_en, which doesn't apply here).
 *
 * Fase 7c PWDATA investigation, one more step: a fifth address,
 * PWDATA_STICKY_ADDR (0x15), exposes pwdata_sticky_r (see below) for
 * software readback instead of relying on SmartDebug. Turns out SmartDebug
 * couldn't have shown it anyway: pwdata_sticky_r survives Synplify synthesis
 * fine (confirmed present as a real 32-bit SLE bank in the post-synthesis
 * netlist), but Designer's live-probe database (MPFS_DISCOVERY_KIT_probe.db)
 * never includes it -- unlike apb_wdata_r/dma_addr_r etc., it drives no
 * other logic, and place&route's probe-insertion step appears to silently
 * exclude zero-fanout nets from the live-probe candidate list regardless of
 * syn_keep/syn_noprune (those only protect against Synplify's own pruning,
 * a separate, earlier stage). Wiring it into a register software already
 * reads sidesteps that tool behavior entirely. Synchronized into core_clk
 * with a plain 2-FF stage (pwdata_sticky_meta/pwdata_sticky_sync below) --
 * not bit-exact rigorous for an arbitrary-width bus, but pwdata_sticky_r is
 * monotonic (OR-accumulated, only cleared by reset) and, in practice, long
 * settled by the time software issues a deliberate read after a write, so
 * the only possible artifact is a bit not-yet-visible for one extra read,
 * never a spurious or corrupted one.
 */

`include "timescale.v"

module apb3_mpeg2fpga_bridge (
    /* APB3 side: PCLK domain */
    PCLK, PRESETn,
    PSEL, PENABLE, PWRITE, PADDR, PWDATA, PRDATA, PREADY,
    PSTRB,

    /* mpeg2video side: core_clk domain */
    core_clk, core_rst_n,
    reg_addr, reg_wr_en, reg_dta_in, reg_rd_en, reg_dta_out,
    busy, stream_data, stream_valid,

    /* stream_dma.v side: core_clk domain, no CDC needed (see header) */
    dma_start, dma_addr, dma_len,
    dma_busy, dma_done, dma_bytes_done,

    /* Fase 7a debug (2026-08-21): mpeg2video's circular video buffer
     * addresses, core_clk domain like dma_addr/dma_len above -- read
     * directly in C_IDLE below, no extra synchronizer needed since the
     * req_toggle/ack_toggle handshake already is the CDC boundary. */
    vbuf_wr_addr, vbuf_rd_addr,

    /* Fase 7a debug (2026-08-22): framestore_request.v's fixed-priority
     * memory arbiter starvation counters, same core_clk-domain treatment. */
    disp_service_cnt, vbr_service_cnt, vbr_starved_cnt,
    arbiter_flags, mem_res_valid_cnt,

    /* Fase 7a debug (2026-08-23): mem2axi_bridge.v's own view of the last
     * write address, genuinely in the mem_clk domain (unlike every other
     * debug signal above, which all happened to already be core_clk) --
     * needs a real 2-FF synchronizer here, see the always block below. */
    dbg_last_write_addr_from_fifo, dbg_last_write_awaddr_issued,

    /* Fase 7a debug (2026-08-23): framestore_request.v's own view of the
     * address it hands to mem_request_fifo's write port -- core_clk
     * domain, same as vbuf_wr_addr, no extra CDC needed. */
    dbg_last_mem_req_wr_addr
);

  input             PCLK;
  input             PRESETn;         /* active low, per APB3 convention */
  input             PSEL;
  input             PENABLE;
  input             PWRITE;
  input       [6:0] PADDR;           /* [6:2] register index (0-15: regfile, 16: stream push), [1:0] byte offset (must be 2'b00) */
  input      [31:0] PWDATA;
  output     [31:0] PRDATA;
  output            PREADY;
  /* Root-cause fix (Fase 7c PWDATA investigation): the MSS FIC_3 AXI-to-APB
   * conversion presents a 32-bit software store as multiple single-byte APB
   * write beats, each with that byte replicated across all 4 PWDATA lanes,
   * using PSTRB to mark which lane is the real one on each beat -- see
   * mpeg2fpga_apb_peripheral.v's header comment for the full story. Latched
   * alongside apb_wdata_r below and used to do a byte-lane-selective merge
   * into dma_addr_r/dma_len_r instead of a blind 32-bit overwrite. */
  input       [3:0] PSTRB;

  input             core_clk;
  input             core_rst_n;      /* active low, matches mpeg2video's "rst" */
  output      [3:0] reg_addr;
  output            reg_wr_en;
  output     [31:0] reg_dta_in;
  output            reg_rd_en;
  input      [31:0] reg_dta_out;

  input             busy;            /* mpeg2video's busy output, core_clk domain -- gates STREAM_PUSH_ADDR completion */
  output      [7:0] stream_data;
  output reg        stream_valid;

  output reg        dma_start;       /* 1-cycle pulse */
  output      [31:0]dma_addr;
  output      [31:0]dma_len;
  input             dma_busy;
  input             dma_done;        /* 1-cycle pulse */
  input       [31:0]dma_bytes_done;

  input       [21:0]vbuf_wr_addr;    /* mpeg2video's vbuf write pointer, core_clk domain */
  input       [21:0]vbuf_rd_addr;    /* mpeg2video's vbuf read pointer, core_clk domain */

  input       [31:0]disp_service_cnt; /* cycles state==STATE_DISP, core_clk domain, free-running */
  input       [31:0]vbr_service_cnt;  /* cycles state==STATE_VBR, core_clk domain, free-running */
  input       [31:0]vbr_starved_cnt;  /* cycles do_vbr true but arbiter picked something else */

  /* Fase 7a debug (2026-08-22): live snapshot -- bits[10:0]=state (one-hot),
   * [11]=do_vbr, [12]=do_disp, [13]=vbuf_empty, [14]=vbr_rd_almost_empty,
   * [15]=mem_req_wr_almost_full, [16]=tag_wr_almost_full, [17]=vbuf_holdoff,
   * [18]=vbw_rd_empty, [31:19]=0. See framestore_request.v's comment. */
  input       [31:0]arbiter_flags;

  input       [31:0]mem_res_valid_cnt; /* cycles mem_res_rd_valid true, core_clk domain, free-running */

  input       [21:0]dbg_last_write_addr_from_fifo; /* mem_clk domain -- genuine CDC needed */
  input       [37:0]dbg_last_write_awaddr_issued;  /* mem_clk domain -- genuine CDC needed */
  input       [21:0]dbg_last_mem_req_wr_addr;       /* core_clk domain, no CDC needed */

  /*
   * APB3 domain: latch the transfer on entering the Access phase
   * (PSEL && PENABLE, first cycle after Setup), then wait for the
   * synchronized ack_toggle to come back before asserting PREADY.
   */

  localparam [1:0] A_IDLE = 2'd0, A_SETTLE = 2'd1, A_WAIT_ACK = 2'd2;
  localparam [2:0] C_IDLE = 3'd0, C_READ_WAIT1 = 3'd1, C_READ_WAIT2 = 3'd2, C_DONE = 3'd3, C_STREAM_WAIT = 3'd4;
  localparam [4:0] STREAM_PUSH_ADDR = 5'h10;
  localparam [4:0] DMA_ADDR_ADDR = 5'h11, DMA_LEN_ADDR = 5'h12, DMA_CTRL_ADDR = 5'h13, DMA_STATUS_ADDR = 5'h14;
  localparam [4:0] PWDATA_STICKY_ADDR = 5'h15;
  localparam [4:0] VBUF_WR_ADDR_ADDR = 5'h16, VBUF_RD_ADDR_ADDR = 5'h17;
  localparam [4:0] DISP_SERVICE_CNT_ADDR = 5'h18, VBR_SERVICE_CNT_ADDR = 5'h19, VBR_STARVED_CNT_ADDR = 5'h1a;
  localparam [4:0] ARBITER_FLAGS_ADDR = 5'h1b;
  localparam [4:0] MEM_RES_VALID_CNT_ADDR = 5'h1c;
  localparam [4:0] DBG_LAST_WRITE_ADDR_FROM_FIFO_ADDR = 5'h1d;
  localparam [4:0] DBG_LAST_WRITE_AWADDR_ISSUED_ADDR = 5'h1e;
  localparam [4:0] DBG_LAST_MEM_REQ_WR_ADDR_ADDR = 5'h1f;

  /* Fase 7c PWDATA investigation: hold the Access phase open for this many
   * extra PCLK cycles, continuously re-latching PADDR/PWDATA/PWRITE every
   * one of them, instead of committing on the very first PSEL&&PENABLE
   * cycle -- a real-hardware SmartDebug capture found PADDR/PWRITE correct
   * at that timing but PWDATA consistently 0, and a first attempt at
   * latching across the *whole* PSEL-high window (not just Setup+PENABLE)
   * didn't change anything either (see docs/bringup Fase 7c). This is a
   * more direct test: does PWDATA ever settle to the real value if given
   * many more PCLK cycles before we commit? Legal either way -- the
   * master already has to tolerate PREADY arriving many cycles late (this
   * bridge's own core_clk CDC round trip already does that on every
   * ordinary register access), so holding it here a while longer changes
   * nothing about protocol correctness, only how long we wait before
   * trusting apb_wdata_r. */
  localparam [7:0] SETTLE_CYCLES = 8'd64;

  reg [31:0] dma_addr_r;
  reg [31:0] dma_len_r;
  reg        dma_done_sticky;

  assign dma_addr = dma_addr_r;
  assign dma_len  = dma_len_r;

  reg  [1:0] apb_state;
  reg  [7:0] settle_cnt;
  reg  [4:0] apb_addr_r;
  reg [31:0] apb_wdata_r;
  reg        apb_write_r;
  reg  [3:0] apb_pstrb_r;
  reg        req_toggle;
  reg        ack_toggle_meta, ack_toggle_sync;

  reg  [2:0] core_state;
  reg        req_toggle_meta, req_toggle_sync, req_toggle_seen;
  reg        reg_wr_en_r, reg_rd_en_r;
  reg [31:0] rdata_hold;
  reg        ack_toggle;

  /* 2-FF synchronizer bringing pwdata_sticky_r (PCLK domain) into core_clk
   * for PWDATA_STICKY_ADDR reads -- see header comment for why this is
   * safe despite being a full 32-bit bus, not a single toggle bit. */
  reg [31:0] pwdata_sticky_meta, pwdata_sticky_sync;

  /* Fase 7a debug (2026-08-23): 2-FF synchronizer bringing mem2axi_bridge's
   * mem_clk-domain debug registers into core_clk, same reasoning as
   * pwdata_sticky_meta/sync above (quasi-static once a write happens, only
   * possible artifact is a one-read staleness, never a torn/corrupted
   * value in practice for a debug-only signal read well after the write
   * that set it). */
  reg [21:0] dbg_last_write_addr_from_fifo_meta, dbg_last_write_addr_from_fifo_sync;
  reg [37:0] dbg_last_write_awaddr_issued_meta, dbg_last_write_awaddr_issued_sync;

  wire       apb_ack_matched  = (apb_state == A_WAIT_ACK) && (ack_toggle_sync == req_toggle);

  assign PREADY = apb_ack_matched;

  /* Fase 7c PWDATA investigation, next step: a completely free-running probe,
   * with NO protocol gating at all (no PSEL/PENABLE condition), to check
   * whether PWDATA ever shows anything but 0 at any point in time -- the two
   * prior settle-cycle experiments above ruled out every "sampled at the
   * wrong moment" theory, but both still only latched *while* PSEL&&PENABLE
   * or PSEL was asserted; this removes that qualifier entirely.
   * pwdata_free_r mirrors PWDATA every single PCLK cycle; pwdata_sticky_r
   * OR-accumulates it and is cleared only by reset, so even a single-cycle
   * glitch on the shared bus (invisible to a snapshot read) leaves a mark.
   * Purely additive -- neither drives any other logic in this always block.
   * pwdata_free_r is watched directly via SmartDebug Active Probes, the same
   * way apb_wdata_r itself was probed; pwdata_sticky_r additionally gets a
   * software-readable path via PWDATA_STICKY_ADDR (0x15, see header comment)
   * since SmartDebug's probe database turned out to exclude it anyway.
   *
   * Neither register has any fanout (nothing in this module or elsewhere
   * reads them) -- without an explicit keep attribute, synthesis dead-code
   * elimination strips them out entirely, since from its point of view they
   * do nothing. Same syn_keep/syn_preserve/syn_noprune pattern already used
   * for the probe-only clock counters in mpeg2video.v -- confirmed by
   * grepping the post-synthesis netlist that the attribute must sit on each
   * register's *own* declaration line: mpeg2video.v's cnt_clk (attribute on
   * its own line) survives synthesis, but cnt_mem/cnt_dot (declared on
   * their own subsequent lines, without repeating the attribute) don't --
   * and neither did pwdata_free_r/pwdata_sticky_r the first time they were
   * combined into one comma-separated `reg` statement under a single
   * attribute block. */
  (* syn_keep = 1, syn_preserve = 1, syn_noprune = 1 *)
  reg [31:0] pwdata_free_r;
  (* syn_keep = 1, syn_preserve = 1, syn_noprune = 1 *)
  reg [31:0] pwdata_sticky_r;

  always @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn) begin
      pwdata_free_r   <= 32'b0;
      pwdata_sticky_r <= 32'b0;
    end else begin
      pwdata_free_r   <= PWDATA;
      pwdata_sticky_r <= pwdata_sticky_r | PWDATA;
    end
  end

  /* Driven continuously (not registered) from the core-domain rdata_hold:
   * it must be valid in the *same* cycle PREADY first asserts (APB3
   * requires PRDATA and PREADY together), and rdata_hold is guaranteed
   * stable well before that point (set in C_READ_WAIT, before ack_toggle
   * even starts crossing back) -- see the domain-crossing note below.
   */
  assign PRDATA = rdata_hold;

  always @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn) begin
      apb_state   <= A_IDLE;
      settle_cnt  <= 8'b0;
      req_toggle  <= 1'b0;
      apb_addr_r  <= 5'b0;
      apb_wdata_r <= 32'b0;
      apb_write_r <= 1'b0;
      apb_pstrb_r <= 4'hF;
    end else begin
      /* 2-FF synchronizer for the core-domain ack_toggle */
      ack_toggle_meta <= ack_toggle;
      ack_toggle_sync <= ack_toggle_meta;

      case (apb_state)
        A_IDLE: begin
          if (PSEL && PENABLE) begin
            apb_addr_r  <= PADDR[6:2];
            apb_wdata_r <= PWDATA;
            apb_write_r <= PWRITE;
            apb_pstrb_r <= PSTRB;
            settle_cnt  <= SETTLE_CYCLES;
            apb_state   <= A_SETTLE;
          end
        end
        A_SETTLE: begin
          /* Re-sample every cycle: the master must still hold PSEL/
           * PENABLE/PADDR/PWDATA/PWRITE/PSTRB stable here, since PREADY
           * hasn't asserted yet -- same requirement as any other extended
           * APB wait state. */
          apb_addr_r  <= PADDR[6:2];
          apb_wdata_r <= PWDATA;
          apb_write_r <= PWRITE;
          apb_pstrb_r <= PSTRB;
          if (settle_cnt == 8'd0) begin
            req_toggle <= ~req_toggle;
            apb_state  <= A_WAIT_ACK;
          end else begin
            settle_cnt <= settle_cnt - 8'd1;
          end
        end
        A_WAIT_ACK: begin
          if (apb_ack_matched)
            apb_state <= A_IDLE;
        end
      endcase
    end
  end

  /*
   * core_clk domain: synchronize req_toggle, then drive a single
   * reg_wr_en/reg_rd_en pulse. Reads need two extra core_clk cycles before
   * reg_dta_out can be captured: regfile.v samples reg_rd_en as an input
   * and registers reg_dta_out on the *next* edge after that (C_READ_WAIT1),
   * so reg_dta_out itself is only valid from the edge *after that* onward
   * (C_READ_WAIT2) -- capturing it one cycle too early silently reads the
   * previous transaction's data instead (caught by the back-to-back test
   * in bench/apb_bridge/testbench.v).
   *
   * apb_addr_r/apb_wdata_r/apb_write_r (PCLK-domain registers) are read
   * directly below, without their own synchronizer: they are set one cycle
   * before req_toggle changes and held constant until this side has
   * acknowledged (the APB side cannot start a new transfer until PREADY),
   * so by the time the synchronized req_toggle_sync edge is observed here
   * they have long since settled -- only the single-bit toggle needs CDC
   * synchronization, not the bus riding alongside it. Same reasoning
   * applies in reverse to rdata_hold, sampled directly on the APB side.
   */

  assign reg_addr   = apb_addr_r[3:0];
  assign reg_dta_in = apb_wdata_r;
  assign reg_wr_en  = reg_wr_en_r;
  assign reg_rd_en  = reg_rd_en_r;
  assign stream_data = apb_wdata_r[7:0];

  wire is_stream_push = (apb_addr_r == STREAM_PUSH_ADDR);
  wire is_dma_addr    = (apb_addr_r == DMA_ADDR_ADDR);
  wire is_dma_len      = (apb_addr_r == DMA_LEN_ADDR);
  wire is_dma_ctrl     = (apb_addr_r == DMA_CTRL_ADDR);
  wire is_dma_status   = (apb_addr_r == DMA_STATUS_ADDR);
  wire is_pwdata_sticky = (apb_addr_r == PWDATA_STICKY_ADDR);
  wire is_vbuf_wr_addr  = (apb_addr_r == VBUF_WR_ADDR_ADDR);
  wire is_vbuf_rd_addr  = (apb_addr_r == VBUF_RD_ADDR_ADDR);
  wire is_disp_service_cnt = (apb_addr_r == DISP_SERVICE_CNT_ADDR);
  wire is_vbr_service_cnt  = (apb_addr_r == VBR_SERVICE_CNT_ADDR);
  wire is_vbr_starved_cnt  = (apb_addr_r == VBR_STARVED_CNT_ADDR);
  wire is_arbiter_flags    = (apb_addr_r == ARBITER_FLAGS_ADDR);
  wire is_mem_res_valid_cnt = (apb_addr_r == MEM_RES_VALID_CNT_ADDR);
  wire is_dbg_last_write_addr_from_fifo = (apb_addr_r == DBG_LAST_WRITE_ADDR_FROM_FIFO_ADDR);
  wire is_dbg_last_write_awaddr_issued  = (apb_addr_r == DBG_LAST_WRITE_AWADDR_ISSUED_ADDR);
  wire is_dbg_last_mem_req_wr_addr = (apb_addr_r == DBG_LAST_MEM_REQ_WR_ADDR_ADDR);

  always @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      core_state      <= C_IDLE;
      req_toggle_meta <= 1'b0;
      req_toggle_sync <= 1'b0;
      req_toggle_seen <= 1'b0;
      reg_wr_en_r     <= 1'b0;
      reg_rd_en_r     <= 1'b0;
      stream_valid    <= 1'b0;
      rdata_hold      <= 32'b0;
      ack_toggle      <= 1'b0;
      dma_addr_r      <= 32'b0;
      dma_len_r       <= 32'b0;
      dma_start       <= 1'b0;
      dma_done_sticky <= 1'b0;
      pwdata_sticky_meta <= 32'b0;
      pwdata_sticky_sync <= 32'b0;
      dbg_last_write_addr_from_fifo_meta <= 22'b0;
      dbg_last_write_addr_from_fifo_sync <= 22'b0;
      dbg_last_write_awaddr_issued_meta  <= 38'b0;
      dbg_last_write_awaddr_issued_sync  <= 38'b0;
    end else begin
      /* 2-FF synchronizer for the APB-domain req_toggle */
      req_toggle_meta <= req_toggle;
      req_toggle_sync <= req_toggle_meta;

      /* 2-FF synchronizer for mem2axi_bridge's mem_clk-domain debug regs */
      dbg_last_write_addr_from_fifo_meta <= dbg_last_write_addr_from_fifo;
      dbg_last_write_addr_from_fifo_sync <= dbg_last_write_addr_from_fifo_meta;
      dbg_last_write_awaddr_issued_meta  <= dbg_last_write_awaddr_issued;
      dbg_last_write_awaddr_issued_sync  <= dbg_last_write_awaddr_issued_meta;

      /* 2-FF synchronizer for pwdata_sticky_r, see declaration comment */
      pwdata_sticky_meta <= pwdata_sticky_r;
      pwdata_sticky_sync <= pwdata_sticky_meta;

      reg_wr_en_r  <= 1'b0;
      reg_rd_en_r  <= 1'b0;
      stream_valid <= 1'b0;
      dma_start    <= 1'b0;

      if (dma_done) dma_done_sticky <= 1'b1;   /* independent of APB activity */

      case (core_state)
        C_IDLE: begin
          if (req_toggle_sync != req_toggle_seen) begin
            req_toggle_seen <= req_toggle_sync;
            if (is_dma_addr) begin
              /* Byte-lane-selective merge, not a blind 32-bit overwrite --
               * see mpeg2fpga_apb_peripheral.v's header comment for why:
               * the MSS presents a 32-bit store as multiple single-byte APB
               * beats (each replicated across all 4 PWDATA lanes), and only
               * PSTRB says which lane is real on any given beat. apb_pstrb_r
               * is a PCLK-domain register read directly here with no extra
               * synchronizer, same as apb_addr_r/apb_wdata_r/apb_write_r
               * above -- it's held stable across the same window they are. */
              if (apb_write_r) begin
                if (apb_pstrb_r[0]) dma_addr_r[7:0]   <= apb_wdata_r[7:0];
                if (apb_pstrb_r[1]) dma_addr_r[15:8]  <= apb_wdata_r[15:8];
                if (apb_pstrb_r[2]) dma_addr_r[23:16] <= apb_wdata_r[23:16];
                if (apb_pstrb_r[3]) dma_addr_r[31:24] <= apb_wdata_r[31:24];
              end else rdata_hold <= dma_addr_r;
              core_state <= C_DONE;
            end else if (is_dma_len) begin
              if (apb_write_r) begin
                if (apb_pstrb_r[0]) dma_len_r[7:0]   <= apb_wdata_r[7:0];
                if (apb_pstrb_r[1]) dma_len_r[15:8]  <= apb_wdata_r[15:8];
                if (apb_pstrb_r[2]) dma_len_r[23:16] <= apb_wdata_r[23:16];
                if (apb_pstrb_r[3]) dma_len_r[31:24] <= apb_wdata_r[31:24];
              end else rdata_hold <= dma_len_r;
              core_state <= C_DONE;
            end else if (is_dma_ctrl) begin
              if (apb_write_r && apb_wdata_r[0] && !dma_busy) begin
                dma_start       <= 1'b1;
                dma_done_sticky <= 1'b0;
              end
              core_state <= C_DONE;
            end else if (is_dma_status) begin
              if (!apb_write_r)
                rdata_hold <= {dma_bytes_done[23:0], 6'b0, dma_done_sticky, dma_busy};
              core_state <= C_DONE;
            end else if (is_pwdata_sticky) begin
              if (!apb_write_r)
                rdata_hold <= pwdata_sticky_sync;
              core_state <= C_DONE;
            end else if (is_vbuf_wr_addr) begin
              if (!apb_write_r)
                rdata_hold <= {10'b0, vbuf_wr_addr};
              core_state <= C_DONE;
            end else if (is_vbuf_rd_addr) begin
              if (!apb_write_r)
                rdata_hold <= {10'b0, vbuf_rd_addr};
              core_state <= C_DONE;
            end else if (is_disp_service_cnt) begin
              if (!apb_write_r)
                rdata_hold <= disp_service_cnt;
              core_state <= C_DONE;
            end else if (is_vbr_service_cnt) begin
              if (!apb_write_r)
                rdata_hold <= vbr_service_cnt;
              core_state <= C_DONE;
            end else if (is_vbr_starved_cnt) begin
              if (!apb_write_r)
                rdata_hold <= vbr_starved_cnt;
              core_state <= C_DONE;
            end else if (is_arbiter_flags) begin
              if (!apb_write_r)
                rdata_hold <= arbiter_flags;
              core_state <= C_DONE;
            end else if (is_mem_res_valid_cnt) begin
              if (!apb_write_r)
                rdata_hold <= mem_res_valid_cnt;
              core_state <= C_DONE;
            end else if (is_dbg_last_write_addr_from_fifo) begin
              if (!apb_write_r)
                rdata_hold <= {10'b0, dbg_last_write_addr_from_fifo_sync};
              core_state <= C_DONE;
            end else if (is_dbg_last_write_awaddr_issued) begin
              if (!apb_write_r)
                rdata_hold <= dbg_last_write_awaddr_issued_sync[31:0];
              core_state <= C_DONE;
            end else if (is_dbg_last_mem_req_wr_addr) begin
              if (!apb_write_r)
                rdata_hold <= {10'b0, dbg_last_mem_req_wr_addr};
              core_state <= C_DONE;
            end else if (is_stream_push) begin
              if (apb_write_r) begin
                if (busy) core_state <= C_STREAM_WAIT;   /* hold PREADY off until mpeg2video has room */
                else begin
                  stream_valid <= 1'b1;
                  core_state   <= C_DONE;
                end
              end else begin
                core_state <= C_DONE;   /* reads of STREAM_PUSH_ADDR are a harmless no-op, rdata_hold unchanged */
              end
            end else if (apb_write_r) begin
              reg_wr_en_r <= 1'b1;   /* write completes on this same edge in regfile.v */
              core_state  <= C_DONE;
            end else begin
              reg_rd_en_r <= 1'b1;
              core_state  <= C_READ_WAIT1;
            end
          end
        end
        C_STREAM_WAIT: begin
          if (~busy) begin
            stream_valid <= 1'b1;
            core_state   <= C_DONE;
          end
        end
        C_READ_WAIT1: begin
          core_state <= C_READ_WAIT2;   /* wait for regfile.v to register reg_dta_out */
        end
        C_READ_WAIT2: begin
          rdata_hold <= reg_dta_out;    /* now valid */
          core_state <= C_DONE;
        end
        C_DONE: begin
          ack_toggle <= ~ack_toggle;
          core_state <= C_IDLE;
        end
      endcase
    end
  end

endmodule
/* not truncated */
