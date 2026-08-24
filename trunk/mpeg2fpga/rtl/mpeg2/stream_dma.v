/*
 * stream_dma.v
 *
 * Fase 7c: autonomous hardware streamer that reads an elementary stream out
 * of a DDR staging buffer over its own AXI4 read-only master, and pulses
 * mpeg2video's stream_data/stream_valid at core_clk rate -- replacing the
 * one-APB-write-per-byte push of Fase 7a (apb3_mpeg2fpga_bridge.v's
 * STREAM_PUSH_ADDR, ~177 KB/s) for bulk transfers.
 *
 * Control (start/addr/len in, busy/done/bytes_done out) is driven by
 * apb3_mpeg2fpga_bridge.v, extended in this same phase with DMA_ADDR/
 * DMA_LEN/DMA_CTRL/DMA_STATUS registers. That extension already crosses
 * PCLK->core_clk via the bridge's existing toggle-handshake, so this module
 * lives entirely in core_clk -- no clock-domain crossing of its own, same
 * reasoning as mem2axi_bridge.v needing mpeg2video's real mem_clk rather
 * than a second independently-generated one. Unlike mem2axi_bridge, this
 * module's own AXI4 master is a *new* transaction source (not a translation
 * of an existing mem_clk-domain protocol), so core_clk is a free choice here
 * -- made to match stream_data/stream_valid's own domain, avoiding a second
 * CDC entirely (see mpeg2fpga_apb_peripheral.v's clk_out promotion, wired to
 * MSS_WRAPPER's previously-unused FIC_2_AXI4_TARGET/FIC_2_ACLK).
 *
 * addr is a byte offset inside a fixed-base staging region (STAGING_BASE,
 * default 0x88000000 -- "/dev/udmabuf-ddr-c0", the one 32 MiB reserved
 * region the base Discovery Kit design exposes that neither the framestore
 * (Fase 6b, 0xc8000000) nor the Fase 7b test pattern (0xd8000000) already
 * claim), the same DDR_BASE-plus-offset pattern mem2axi_bridge already uses.
 * It is cached from Linux's side, so software must sync_for_device before
 * triggering a transfer -- this module has no visibility into that and
 * trusts the caller.
 *
 * Reads happen in bursts of up to BURST_BEATS 64-bit beats (default 16,
 * 128 bytes/burst); the last burst of a transfer, and the last beat of that
 * burst, may be partial -- bytes_in_beat is recomputed from the *running*
 * bytes_left every beat, not just once per burst, so a non-multiple-of-8 len
 * is handled the same way whether it falls mid-transfer or at the very end.
 *
 * After len bytes are streamed, this module appends the same 32-byte
 * ISO/IEC 13818-2 sequence_end_code padding software already appends in the
 * Fase 7a path (decoder_push.py/push_stream.py's SEQUENCE_END_PADDING) --
 * callers pass the real elementary-stream length, not a pre-padded one.
 *
 * mpeg_busy is mpeg2video's own busy output (input FIFO risks overflow),
 * the exact same backpressure signal the manual STREAM_PUSH_ADDR path
 * already respects -- both sources share it, and mpeg2fpga_apb_peripheral.v
 * muxes stream_data/stream_valid between the two using this module's busy
 * output as the select (high = a DMA transfer owns the port pair). Software
 * is trusted not to write STREAM_PUSH_ADDR while a DMA transfer is running,
 * same as every other cross-register ordering contract in this design
 * (e.g. DMA_ADDR/DMA_LEN must be written before DMA_CTRL).
 *
 * Reset domain fix (2026-08-23, real-hardware stall investigation -- see
 * docs/bringup and fase7a_size_zero_vld_stall on the docs branch): rst_n
 * was previously wired to the module's raw external hard-reset pin only.
 * mpeg2video's own memory-write path (framestore_request.v, mem2axi_
 * bridge.v) resets on rst_n *or* an internal watchdog expiry (mpeg2video.v's
 * sync_rst/mem_rst) -- this module did not, since it only ever saw the raw
 * pin. A watchdog-triggered reset therefore cleanly reset everything else
 * while potentially leaving this module's AXI4 read master mid-transaction
 * (m_axi_arvalid or m_axi_rready still asserted, addr_r/bytes_left/beat_r
 * holding stale state from before the reset) -- a real, reproducible
 * mechanism for wedging the shared FIC_2/DDR-controller fabric port after
 * a watchdog fires mid-DMA-push, confirmed via mem2axi_bridge completing
 * exactly one AXI4 write post-reset and then freezing. Now takes the same
 * watchdog-inclusive reset mem2axi_bridge already does (see rst_n's
 * connection in mpeg2fpga_apb_peripheral.v -- core_rst_out, not the raw
 * external pin).
 */

`include "timescale.v"

module stream_dma (
    clk, rst_n,

    /* control, core_clk domain (from apb3_mpeg2fpga_bridge.v) */
    start, addr, len,
    busy, done, bytes_done,

    /* mpeg2video side */
    mpeg_busy,
    stream_data, stream_valid,

    /* AXI4 read-only master (FIC_2 fabric-master side). Sideband signals
     * tied to fixed values for the same reason mem2axi_bridge.v's are --
     * Libero's bus-interface check needs the full AXI4 signal set present. */
    m_axi_arid, m_axi_araddr, m_axi_arlen, m_axi_arsize, m_axi_arburst, m_axi_arlock, m_axi_arcache, m_axi_arprot, m_axi_arqos, m_axi_arregion, m_axi_aruser, m_axi_arvalid, m_axi_arready,
    m_axi_rid, m_axi_rdata, m_axi_rresp, m_axi_rlast, m_axi_ruser, m_axi_rvalid, m_axi_rready,

    /* Fase 7a debug (2026-08-23): raw FSM state, packed into
     * apb3_mpeg2fpga_bridge.v's ARBITER_FLAGS readback alongside
     * dma_axi_arvalid/dma_axi_rvalid (already reachable at the
     * mpeg2fpga_apb_peripheral.v level) -- see that module's header
     * comment for why this exists: rst_n here is the raw external hard
     * reset, NOT mpeg2video's watchdog-inclusive sync_rst, so a watchdog-
     * triggered reset can leave this module's AXI4 read master mid-
     * transaction while everything else cleanly resets. This lets that be
     * confirmed directly instead of inferred from mem2axi_bridge's
     * downstream symptoms. */
    dbg_state
);

  parameter [37:0] STAGING_BASE = 38'h88000000;
  parameter [4:0]  BURST_BEATS  = 5'd16;   /* 16 beats * 8 bytes = 128 bytes/burst */

  input             clk;
  input             rst_n;      /* active low, matches mpeg2video's "rst" */

  input             start;      /* 1-cycle pulse; ignored while busy */
  input      [31:0] addr;       /* byte offset inside STAGING_BASE */
  input      [31:0] len;        /* real elementary-stream length, no padding */
  output            busy;
  output reg        done;       /* 1-cycle pulse */
  output reg [31:0] bytes_done; /* running total, incl. padding; latched at done */

  input             mpeg_busy;
  output reg  [7:0] stream_data;
  output reg        stream_valid;

  output       [3:0]m_axi_arid;
  output reg  [37:0]m_axi_araddr;
  output reg   [7:0]m_axi_arlen;
  output       [2:0]m_axi_arsize;
  output       [1:0]m_axi_arburst;
  output            m_axi_arlock;
  output       [3:0]m_axi_arcache;
  output       [2:0]m_axi_arprot;
  output       [3:0]m_axi_arqos;
  output       [3:0]m_axi_arregion;
  output       [0:0]m_axi_aruser;
  output reg        m_axi_arvalid;
  input             m_axi_arready;

  input        [3:0]m_axi_rid;
  input       [63:0]m_axi_rdata;
  input        [1:0]m_axi_rresp;
  input             m_axi_rlast;
  input        [0:0]m_axi_ruser;
  input             m_axi_rvalid;
  output            m_axi_rready;

  output      [2:0] dbg_state;
  assign dbg_state = state;

  /* fixed AXI4 attributes -- id 1 (distinct from mem2axi_bridge's id 0,
   * harmless either way since they sit on independent FIC ports, but keeps
   * waveforms unambiguous), INCR burst, "normal" sideband defaults. */
  assign m_axi_arid     = 4'd1;
  assign m_axi_arsize   = 3'b011;  /* 8 bytes/beat */
  assign m_axi_arburst  = 2'b01;
  assign m_axi_arlock   = 1'b0;
  assign m_axi_arcache  = 4'b0000;
  assign m_axi_arprot   = 3'b000;
  assign m_axi_arqos    = 4'b0000;
  assign m_axi_arregion = 4'b0000;
  assign m_axi_aruser   = 1'b0;

  /* bytes this beat carries, given bytes_left *before* the beat is taken */
  function [3:0] beat_bytes;
    input [31:0] bl;
    beat_bytes = (bl >= 32'd8) ? 4'd8 : bl[3:0];
  endfunction

  /* repeats {0x00, 0x00, 0x01, 0xB7} 8 times -- ISO/IEC 13818-2
   * sequence_end_code padding, same pattern as decoder_push.py */
  function [7:0] pad_byte;
    input [1:0] i;
    case (i)
      2'd2:    pad_byte = 8'h01;
      2'd3:    pad_byte = 8'hB7;
      default: pad_byte = 8'h00;
    endcase
  endfunction

  localparam [2:0]
    S_IDLE  = 3'd0,   /* waiting for start */
    S_AR    = 3'd1,   /* ARVALID outstanding, waiting on ARREADY */
    S_RDATA = 3'd2,   /* RREADY asserted, waiting on RVALID */
    S_DRAIN = 3'd3,   /* emitting the latched beat's bytes, one per cycle */
    S_PAD   = 3'd4,   /* emitting sequence_end_code padding */
    S_DONE  = 3'd5;   /* pulse done, then back to idle */

  reg  [2:0]  state, next;

  reg  [37:0] addr_r;             /* next AXI4 read address */
  reg  [31:0] bytes_left;         /* bytes not yet requested from DDR */
  reg  [4:0]  beats_left_in_burst;

  reg  [63:0] beat_r;
  reg  [3:0]  bytes_in_beat_r;    /* valid bytes in the latched beat, 1-8 */
  reg  [3:0]  byte_idx;           /* next byte of beat_r to emit, 0-7 */

  reg  [4:0]  pad_idx;            /* 0-31 */

  assign busy = (state != S_IDLE);
  assign m_axi_rready = (state == S_RDATA);

  /* addr_r/bytes_left are only updated (elsewhere) the cycle *after*
   * S_IDLE+start; reading them directly here for the S_IDLE->S_AR AR-latch
   * would see their stale pre-transfer values (classic NBA same-cycle
   * read-before-write). eff_* substitute the incoming start-time inputs for
   * that one transition; every other transition (S_DRAIN->S_AR) reads
   * addr_r/bytes_left after they *have* settled, so eff_* just passes them
   * through unchanged there. */
  wire [37:0] eff_addr       = ((state == S_IDLE) && start) ? (STAGING_BASE + {6'b0, addr}) : addr_r;
  wire [31:0] eff_bytes_left = ((state == S_IDLE) && start) ? len : bytes_left;

  /* ceil(eff_bytes_left / 8), capped at BURST_BEATS -- sized so every beat
   * in a full-length burst is guaranteed a full 8 bytes; only ever
   * undersized on the transfer's last (partial) burst. */
  wire [4:0] beats_wanted = (eff_bytes_left >= {27'b0, BURST_BEATS, 3'b0}) ? BURST_BEATS
                                                                            : eff_bytes_left[7:3] + {4'b0, |eff_bytes_left[2:0]};

  always @* begin
    case (state)
      S_IDLE:  next = start ? ((len == 32'd0) ? S_PAD : S_AR) : S_IDLE;
      S_AR:    next = m_axi_arready ? S_RDATA : S_AR;
      S_RDATA: next = m_axi_rvalid  ? S_DRAIN : S_RDATA;
      S_DRAIN: if (mpeg_busy || byte_idx != bytes_in_beat_r) next = S_DRAIN;
               else next = (beats_left_in_burst != 5'd0) ? S_RDATA
                          : (bytes_left != 32'd0)         ? S_AR
                          : S_PAD;
      S_PAD:   next = (mpeg_busy || pad_idx != 5'd31) ? S_PAD : S_DONE;
      S_DONE:  next = S_IDLE;
      default: next = S_IDLE;
    endcase
  end

  always @(posedge clk or negedge rst_n)
    if (!rst_n) state <= S_IDLE;
    else state <= next;

  /* transfer-scope bookkeeping: latched on start, advanced per beat */
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      addr_r     <= 38'b0;
      bytes_left <= 32'b0;
    end else if ((state == S_IDLE) && start) begin
      addr_r     <= STAGING_BASE + {6'b0, addr};
      bytes_left <= len;
    end else if ((state == S_RDATA) && m_axi_rvalid) begin
      addr_r     <= addr_r + 38'd8;
      bytes_left <= bytes_left - {28'b0, beat_bytes(bytes_left)};
    end
  end

  /* burst-scope bookkeeping: (re)latched every time a burst starts, from
   * either S_IDLE or S_DRAIN -- one condition covers both transition
   * sources, rather than duplicating the latch in each predecessor state. */
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_axi_arvalid       <= 1'b0;
      m_axi_araddr        <= 38'b0;
      m_axi_arlen          <= 8'b0;
      beats_left_in_burst <= 5'b0;
    end else if ((state != S_AR) && (next == S_AR)) begin
      m_axi_araddr         <= eff_addr;
      m_axi_arlen          <= {3'b0, beats_wanted} - 8'd1;
      m_axi_arvalid        <= 1'b1;
      beats_left_in_burst  <= beats_wanted;
    end else if ((state == S_AR) && m_axi_arvalid && m_axi_arready) begin
      m_axi_arvalid <= 1'b0;
    end else if ((state == S_RDATA) && m_axi_rvalid) begin
      beats_left_in_burst <= beats_left_in_burst - 5'd1;
    end
  end

  /* latch the beat, compute how many of its bytes are real payload, then
   * drain one byte per cycle while respecting mpeg_busy */
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      beat_r          <= 64'b0;
      bytes_in_beat_r <= 4'b0;
      byte_idx        <= 4'b0;
    end else if ((state == S_RDATA) && m_axi_rvalid) begin
      beat_r          <= m_axi_rdata;
      bytes_in_beat_r <= beat_bytes(bytes_left);
      byte_idx        <= 4'b0;
    end else if ((state == S_DRAIN) && !mpeg_busy && (byte_idx != bytes_in_beat_r)) begin
      byte_idx <= byte_idx + 4'd1;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) pad_idx <= 5'b0;
    else if (state == S_PAD) begin
      if (!mpeg_busy) pad_idx <= pad_idx + 5'd1;
    end else pad_idx <= 5'b0;
  end

  /* stream_data/stream_valid: driven from S_DRAIN (real payload) or S_PAD
   * (padding), respecting mpeg_busy exactly like apb3_mpeg2fpga_bridge's
   * C_STREAM_WAIT does for the manual push. */
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stream_data  <= 8'b0;
      stream_valid <= 1'b0;
    end else begin
      stream_valid <= 1'b0;
      case (state)
        S_DRAIN: if (!mpeg_busy && (byte_idx != bytes_in_beat_r)) begin
          stream_data  <= beat_r[byte_idx*8 +: 8];
          stream_valid <= 1'b1;
        end
        S_PAD: if (!mpeg_busy) begin
          stream_data  <= pad_byte(pad_idx[1:0]);
          stream_valid <= 1'b1;
        end
        default: ;
      endcase
    end
  end

  /* bytes_done: counts every stream_valid pulse (payload + padding),
   * latched for software to read via DMA_STATUS once done pulses. */
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) bytes_done <= 32'b0;
    else if ((state == S_IDLE) && start) bytes_done <= 32'b0;
    else if (stream_valid) bytes_done <= bytes_done + 32'd1;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) done <= 1'b0;
    else done <= (state == S_DONE);
  end

`undef CHECK
`ifdef __IVERILOG__
`define CHECK 1
`endif

`ifdef CHECK
  always @(posedge clk)
    if ((state == S_RDATA) && m_axi_rvalid && (m_axi_rresp != 2'b00))
      $display("%m\t*** warning: AXI read from %h got RRESP %b (not OKAY) ***", m_axi_araddr, m_axi_rresp);

  always @(posedge clk)
    if ((state == S_RDATA) && m_axi_rvalid && (beats_left_in_burst == 5'd1) && !m_axi_rlast)
      begin
        $display("%m\t*** error: last beat of burst did not see RLAST ***");
        $stop;
      end
`endif

endmodule
/* not truncated */
