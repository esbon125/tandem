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
 */

`include "timescale.v"

module apb3_mpeg2fpga_bridge (
    /* APB3 side: PCLK domain */
    PCLK, PRESETn,
    PSEL, PENABLE, PWRITE, PADDR, PWDATA, PRDATA, PREADY,

    /* mpeg2video side: core_clk domain */
    core_clk, core_rst_n,
    reg_addr, reg_wr_en, reg_dta_in, reg_rd_en, reg_dta_out
);

  input             PCLK;
  input             PRESETn;         /* active low, per APB3 convention */
  input             PSEL;
  input             PENABLE;
  input             PWRITE;
  input       [5:0] PADDR;           /* [5:2] register index, [1:0] byte offset (must be 2'b00) */
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

  /*
   * APB3 domain: latch the transfer on entering the Access phase
   * (PSEL && PENABLE, first cycle after Setup), then wait for the
   * synchronized ack_toggle to come back before asserting PREADY.
   */

  localparam A_IDLE = 1'b0, A_WAIT_ACK = 1'b1;
  localparam C_IDLE = 2'd0, C_READ_WAIT1 = 2'd1, C_READ_WAIT2 = 2'd2, C_DONE = 2'd3;

  reg        apb_state;
  reg  [3:0] apb_addr_r;
  reg [31:0] apb_wdata_r;
  reg        apb_write_r;
  reg        req_toggle;
  reg        ack_toggle_meta, ack_toggle_sync;

  reg  [1:0] core_state;
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
      apb_addr_r  <= 4'b0;
      apb_wdata_r <= 32'b0;
      apb_write_r <= 1'b0;
    end else begin
      /* 2-FF synchronizer for the core-domain ack_toggle */
      ack_toggle_meta <= ack_toggle;
      ack_toggle_sync <= ack_toggle_meta;

      case (apb_state)
        A_IDLE: begin
          if (apb_access_start) begin
            apb_addr_r  <= PADDR[5:2];
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

  assign reg_addr   = apb_addr_r;
  assign reg_dta_in = apb_wdata_r;
  assign reg_wr_en  = reg_wr_en_r;
  assign reg_rd_en  = reg_rd_en_r;

  always @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      core_state      <= C_IDLE;
      req_toggle_meta <= 1'b0;
      req_toggle_sync <= 1'b0;
      req_toggle_seen <= 1'b0;
      reg_wr_en_r     <= 1'b0;
      reg_rd_en_r     <= 1'b0;
      rdata_hold      <= 32'b0;
      ack_toggle      <= 1'b0;
    end else begin
      /* 2-FF synchronizer for the APB-domain req_toggle */
      req_toggle_meta <= req_toggle;
      req_toggle_sync <= req_toggle_meta;

      reg_wr_en_r <= 1'b0;
      reg_rd_en_r <= 1'b0;

      case (core_state)
        C_IDLE: begin
          if (req_toggle_sync != req_toggle_seen) begin
            req_toggle_seen <= req_toggle_sync;
            if (apb_write_r) begin
              reg_wr_en_r <= 1'b1;   /* write completes on this same edge in regfile.v */
              core_state  <= C_DONE;
            end else begin
              reg_rd_en_r <= 1'b1;
              core_state  <= C_READ_WAIT1;
            end
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
