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
 */

`include "timescale.v"

module apb3_mpeg2fpga_bridge (
    /* APB3 side: PCLK domain */
    PCLK, PRESETn,
    PSEL, PENABLE, PWRITE, PADDR, PWDATA, PRDATA, PREADY,

    /* mpeg2video side: core_clk domain */
    core_clk, core_rst_n,
    reg_addr, reg_wr_en, reg_dta_in, reg_rd_en, reg_dta_out,
    busy, stream_data, stream_valid,

    /* stream_dma.v side: core_clk domain, no CDC needed (see header) */
    dma_start, dma_addr, dma_len,
    dma_busy, dma_done, dma_bytes_done
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

  /*
   * APB3 domain: latch the transfer on entering the Access phase
   * (PSEL && PENABLE, first cycle after Setup), then wait for the
   * synchronized ack_toggle to come back before asserting PREADY.
   */

  localparam A_IDLE = 1'b0, A_WAIT_ACK = 1'b1;
  localparam [2:0] C_IDLE = 3'd0, C_READ_WAIT1 = 3'd1, C_READ_WAIT2 = 3'd2, C_DONE = 3'd3, C_STREAM_WAIT = 3'd4;
  localparam [4:0] STREAM_PUSH_ADDR = 5'h10;
  localparam [4:0] DMA_ADDR_ADDR = 5'h11, DMA_LEN_ADDR = 5'h12, DMA_CTRL_ADDR = 5'h13, DMA_STATUS_ADDR = 5'h14;

  reg [31:0] dma_addr_r;
  reg [31:0] dma_len_r;
  reg        dma_done_sticky;

  assign dma_addr = dma_addr_r;
  assign dma_len  = dma_len_r;

  reg        apb_state;
  reg  [4:0] apb_addr_r;
  reg [31:0] apb_wdata_r;
  reg        apb_write_r;
  reg        req_toggle;
  reg        ack_toggle_meta, ack_toggle_sync;

  reg  [2:0] core_state;
  reg        req_toggle_meta, req_toggle_sync, req_toggle_seen;
  reg        reg_wr_en_r, reg_rd_en_r;
  reg [31:0] rdata_hold;
  reg        ack_toggle;

  wire       apb_access_start = PSEL && PENABLE && (apb_state == A_IDLE);
  wire       apb_ack_matched  = (apb_state == A_WAIT_ACK) && (ack_toggle_sync == req_toggle);

  assign PREADY = apb_ack_matched;

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
      req_toggle  <= 1'b0;
      apb_addr_r  <= 5'b0;
      apb_wdata_r <= 32'b0;
      apb_write_r <= 1'b0;
    end else begin
      /* 2-FF synchronizer for the core-domain ack_toggle */
      ack_toggle_meta <= ack_toggle;
      ack_toggle_sync <= ack_toggle_meta;

      case (apb_state)
        A_IDLE: begin
          if (apb_access_start) begin
            apb_addr_r  <= PADDR[6:2];
            apb_wdata_r <= PWDATA;
            apb_write_r <= PWRITE;
            req_toggle  <= ~req_toggle;
            apb_state   <= A_WAIT_ACK;
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
    end else begin
      /* 2-FF synchronizer for the APB-domain req_toggle */
      req_toggle_meta <= req_toggle;
      req_toggle_sync <= req_toggle_meta;

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
              if (apb_write_r) dma_addr_r <= apb_wdata_r;
              else rdata_hold <= dma_addr_r;   /* Fase 7c debug: DMA_LEN=0 bug investigation */
              core_state <= C_DONE;
            end else if (is_dma_len) begin
              if (apb_write_r) dma_len_r <= apb_wdata_r;
              else rdata_hold <= dma_len_r;    /* Fase 7c debug: DMA_LEN=0 bug investigation */
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
