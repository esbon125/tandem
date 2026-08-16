/*
 * fake_axi_ddr.v - test double for a DDR4-backed AXI4 slave (FIC_0 side)
 *
 * Minimal AXI4 slave backed by a plain memory array. Each channel accepts
 * its handshake only after a fixed, non-zero latency (AW_LATENCY etc.,
 * deliberately different per channel) instead of asserting *READY the same
 * cycle *VALID appears -- a bridge that silently assumes an always-ready
 * slave (the real FIC_0/DDR4 path never is) would hang or misbehave against
 * this model instead of accidentally passing.
 *
 * AW and W are accepted independently (their own latency, their own
 * "captured" flag) and only combined -- performing the actual memory write
 * and, after a further latency, asserting BVALID -- once both have landed,
 * so the test does not assume the master raises AWVALID/WVALID in lockstep.
 */

`include "timescale.v"

module fake_axi_ddr (
    clk, rst,
    m_axi_awid, m_axi_awaddr, m_axi_awlen, m_axi_awsize, m_axi_awburst, m_axi_awvalid, m_axi_awready,
    m_axi_wdata, m_axi_wstrb, m_axi_wlast, m_axi_wvalid, m_axi_wready,
    m_axi_bid, m_axi_bresp, m_axi_bvalid, m_axi_bready,
    m_axi_arid, m_axi_araddr, m_axi_arlen, m_axi_arsize, m_axi_arburst, m_axi_arvalid, m_axi_arready,
    m_axi_rid, m_axi_rdata, m_axi_rresp, m_axi_rlast, m_axi_rvalid, m_axi_rready
);

  input        clk;
  input        rst;

  input  [7:0] m_axi_awid;
  input [37:0] m_axi_awaddr;
  input  [7:0] m_axi_awlen;
  input  [2:0] m_axi_awsize;
  input  [1:0] m_axi_awburst;
  input        m_axi_awvalid;
  output reg   m_axi_awready;

  input [63:0] m_axi_wdata;
  input  [7:0] m_axi_wstrb;
  input        m_axi_wlast;
  input        m_axi_wvalid;
  output reg   m_axi_wready;

  output reg [7:0] m_axi_bid;
  output reg [1:0] m_axi_bresp;
  output reg       m_axi_bvalid;
  input            m_axi_bready;

  input  [7:0] m_axi_arid;
  input [37:0] m_axi_araddr;
  input  [7:0] m_axi_arlen;
  input  [2:0] m_axi_arsize;
  input  [1:0] m_axi_arburst;
  input        m_axi_arvalid;
  output reg   m_axi_arready;

  output reg [7:0]  m_axi_rid;
  output reg [63:0] m_axi_rdata;
  output reg [1:0]  m_axi_rresp;
  output reg        m_axi_rlast;
  output reg        m_axi_rvalid;
  input             m_axi_rready;

  /* backing store: word-addressed (8 bytes/word), 14 bits -- 128 KB, plenty for a directed test */
  reg [63:0] mem [0:16383];

  localparam [2:0] AW_LATENCY = 3'd2;
  localparam [2:0] W_LATENCY  = 3'd3;
  localparam [2:0] B_LATENCY  = 3'd2;
  localparam [2:0] AR_LATENCY = 3'd4;
  localparam [2:0] R_LATENCY  = 3'd3;

  /* ---- AW channel: accept after AW_LATENCY cycles, latch address ----
   * AWS_DRAIN exists because AWVALID does not drop the same cycle AWREADY
   * pulses (the master waits to *sample* AWREADY high before dropping
   * AWVALID) -- without it, AWS_IDLE would see AWVALID still asserted the
   * very next cycle and spuriously accept the same transfer a second time.
   */
  localparam [1:0] AWS_IDLE = 2'd0, AWS_WAIT = 2'd1, AWS_DRAIN = 2'd2;
  reg [1:0] aw_state;
  reg [2:0] aw_cnt;
  reg       aw_captured;
  reg [37:0]aw_addr_r;

  always @(posedge clk)
    if (~rst) begin
      aw_state <= AWS_IDLE;
      m_axi_awready <= 1'b0;
      aw_captured <= 1'b0;
      aw_addr_r <= 38'b0;
    end else begin
      m_axi_awready <= 1'b0;
      if (aw_captured) aw_captured <= 1'b0;   // one-cycle pulse, consumed by the combiner below
      case (aw_state)
        AWS_IDLE: if (m_axi_awvalid) begin
          aw_cnt   <= AW_LATENCY;
          aw_state <= AWS_WAIT;
        end
        AWS_WAIT: if (aw_cnt == 0) begin
          m_axi_awready <= 1'b1;
          aw_addr_r     <= m_axi_awaddr;
          aw_captured   <= 1'b1;
          aw_state      <= AWS_DRAIN;
        end else aw_cnt <= aw_cnt - 3'd1;
        AWS_DRAIN: if (~m_axi_awvalid) aw_state <= AWS_IDLE;
      endcase
    end

  /* ---- W channel: accept after W_LATENCY cycles, latch data ---- */
  localparam [1:0] WS_IDLE = 2'd0, WS_WAIT = 2'd1, WS_DRAIN = 2'd2;
  reg [1:0] w_state;
  reg [2:0] w_cnt;
  reg       w_captured;
  reg [63:0]w_data_r;

  always @(posedge clk)
    if (~rst) begin
      w_state <= WS_IDLE;
      m_axi_wready <= 1'b0;
      w_captured <= 1'b0;
      w_data_r <= 64'b0;
    end else begin
      m_axi_wready <= 1'b0;
      if (w_captured) w_captured <= 1'b0;
      case (w_state)
        WS_IDLE: if (m_axi_wvalid) begin
          w_cnt   <= W_LATENCY;
          w_state <= WS_WAIT;
        end
        WS_WAIT: if (w_cnt == 0) begin
          m_axi_wready <= 1'b1;
          w_data_r     <= m_axi_wdata;
          w_captured   <= 1'b1;
          w_state      <= WS_DRAIN;
        end else w_cnt <= w_cnt - 3'd1;
        WS_DRAIN: if (~m_axi_wvalid) w_state <= WS_IDLE;
      endcase
    end

  /* ---- combine AW+W once both captured: perform the write, then BVALID ---- */
  localparam CS_WAIT_BOTH = 2'd0, CS_DELAY = 2'd1, CS_BVALID = 2'd2;
  reg [1:0] combine_state;
  reg       have_aw, have_w;
  reg [37:0]write_addr_r;
  reg [2:0] b_cnt;

  always @(posedge clk)
    if (~rst) begin
      combine_state <= CS_WAIT_BOTH;
      have_aw <= 1'b0;
      have_w  <= 1'b0;
      m_axi_bvalid <= 1'b0;
      m_axi_bid    <= 8'b0;
      m_axi_bresp  <= 2'b00;
      write_addr_r <= 38'b0;
    end else begin
      if (aw_captured) have_aw <= 1'b1;
      if (w_captured)  have_w  <= 1'b1;
      case (combine_state)
        CS_WAIT_BOTH: if ((have_aw || aw_captured) && (have_w || w_captured)) begin
          write_addr_r  <= aw_addr_r; // captured together with aw_captured -- already valid here
          b_cnt         <= B_LATENCY;
          combine_state <= CS_DELAY;
        end
        CS_DELAY: if (b_cnt == 0) begin
          mem[write_addr_r[16:3]] <= w_data_r;
          m_axi_bvalid <= 1'b1;
          m_axi_bid    <= 8'b0;
          m_axi_bresp  <= 2'b00;
          combine_state <= CS_BVALID;
        end else b_cnt <= b_cnt - 3'd1;
        CS_BVALID: if (m_axi_bvalid && m_axi_bready) begin
          m_axi_bvalid  <= 1'b0;
          have_aw       <= 1'b0;
          have_w        <= 1'b0;
          combine_state <= CS_WAIT_BOTH;
        end
      endcase
    end

  /* ---- AR channel: accept after AR_LATENCY cycles, latch address ----
   * ARS_DRAIN: see the AWS_DRAIN comment above -- same reasoning, ARVALID
   * lags one cycle behind ARREADY.
   */
  localparam [1:0] ARS_IDLE = 2'd0, ARS_WAIT = 2'd1, ARS_DRAIN = 2'd2;
  reg [1:0] ar_state;
  reg [2:0] ar_cnt;
  reg [37:0]ar_addr_r;

  localparam RS_IDLE = 2'd0, RS_DELAY = 2'd1, RS_RVALID = 2'd2;
  reg [1:0] r_state;
  reg [2:0] r_cnt;

  always @(posedge clk)
    if (~rst) begin
      ar_state <= ARS_IDLE;
      m_axi_arready <= 1'b0;
      ar_addr_r <= 38'b0;
      r_state <= RS_IDLE;
      m_axi_rvalid <= 1'b0;
      m_axi_rdata  <= 64'b0;
      m_axi_rresp  <= 2'b00;
      m_axi_rlast  <= 1'b0;
      m_axi_rid    <= 8'b0;
    end else begin
      m_axi_arready <= 1'b0;
      case (ar_state)
        ARS_IDLE: if (m_axi_arvalid && (r_state == RS_IDLE)) begin
          ar_cnt   <= AR_LATENCY;
          ar_state <= ARS_WAIT;
        end
        ARS_WAIT: if (ar_cnt == 0) begin
          m_axi_arready <= 1'b1;
          ar_addr_r     <= m_axi_araddr;
          ar_state      <= ARS_DRAIN;
        end else ar_cnt <= ar_cnt - 3'd1;
        ARS_DRAIN: if (~m_axi_arvalid) ar_state <= ARS_IDLE;
      endcase

      case (r_state)
        RS_IDLE: if (m_axi_arready) begin       // arready pulses the same cycle ar_addr_r becomes valid
          r_cnt   <= R_LATENCY;
          r_state <= RS_DELAY;
        end
        RS_DELAY: if (r_cnt == 0) begin
          m_axi_rdata  <= mem[ar_addr_r[16:3]];
          m_axi_rresp  <= 2'b00;
          m_axi_rlast  <= 1'b1;
          m_axi_rid    <= 8'b0;
          m_axi_rvalid <= 1'b1;
          r_state      <= RS_RVALID;
        end else r_cnt <= r_cnt - 3'd1;
        RS_RVALID: if (m_axi_rvalid && m_axi_rready) begin
          m_axi_rvalid <= 1'b0;
          r_state      <= RS_IDLE;
        end
      endcase
    end

endmodule
/* not truncated */
