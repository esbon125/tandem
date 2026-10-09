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

  input  [3:0] m_axi_awid;
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

  output reg [3:0] m_axi_bid;
  output reg [1:0] m_axi_bresp;
  output reg       m_axi_bvalid;
  input            m_axi_bready;

  input  [3:0] m_axi_arid;
  input [37:0] m_axi_araddr;
  input  [7:0] m_axi_arlen;
  input  [2:0] m_axi_arsize;
  input  [1:0] m_axi_arburst;
  input        m_axi_arvalid;
  output reg   m_axi_arready;

  output reg [3:0]  m_axi_rid;
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

  /* ---- AW/W channels: accept after AW_LATENCY/W_LATENCY cycles ----
   * AWS_DRAIN/WS_DRAIN exist because AWVALID/WVALID do not drop the same
   * cycle AWREADY/WREADY pulse (the master waits to *sample* READY high
   * before dropping VALID) -- without them, *S_IDLE would see VALID still
   * asserted the very next cycle and spuriously accept the same transfer a
   * second time.
   *
   * 2026-09-07 (Fase 8b write pipelining): decoupled through their own
   * small queues (AWQ_DEPTH/WDQ_DEPTH entries), same reasoning and same
   * mistake-avoided as the Fase 8a AR/R rewrite above -- a slave that only
   * ever has one write outstanding at a time never exercises the scenario
   * write pipelining targets (multiple writes genuinely in flight), so it
   * could pass while that behavior was silently broken. */
  localparam [1:0] AWS_IDLE = 2'd0, AWS_WAIT = 2'd1, AWS_DRAIN = 2'd2;
  reg [1:0] aw_state;
  reg [2:0] aw_cnt;

  localparam AWQ_DEPTH = 4;
  reg [37:0] awq_addr [0:AWQ_DEPTH-1];
  reg  [1:0] awq_wptr, awq_rptr;
  reg  [2:0] awq_count;

  wire awq_push = (aw_state == AWS_WAIT) && (aw_cnt == 0);

  always @(posedge clk)
    if (~rst) begin
      aw_state <= AWS_IDLE;
      m_axi_awready <= 1'b0;
    end else begin
      m_axi_awready <= 1'b0;
      case (aw_state)
        AWS_IDLE: if (m_axi_awvalid && (awq_count < AWQ_DEPTH)) begin
          aw_cnt   <= AW_LATENCY;
          aw_state <= AWS_WAIT;
        end
        AWS_WAIT: if (aw_cnt == 0) begin
          m_axi_awready <= 1'b1;
          aw_state      <= AWS_DRAIN;
        end else aw_cnt <= aw_cnt - 3'd1;
        AWS_DRAIN: if (~m_axi_awvalid) aw_state <= AWS_IDLE;
      endcase
    end

  localparam [1:0] WS_IDLE = 2'd0, WS_WAIT = 2'd1, WS_DRAIN = 2'd2;
  reg [1:0] w_state;
  reg [2:0] w_cnt;

  localparam WDQ_DEPTH = 4;
  reg [63:0] wdq_data [0:WDQ_DEPTH-1];
  reg  [1:0] wdq_wptr, wdq_rptr;
  reg  [2:0] wdq_count;

  wire wdq_push = (w_state == WS_WAIT) && (w_cnt == 0);

  always @(posedge clk)
    if (~rst) begin
      w_state <= WS_IDLE;
      m_axi_wready <= 1'b0;
    end else begin
      m_axi_wready <= 1'b0;
      case (w_state)
        WS_IDLE: if (m_axi_wvalid && (wdq_count < WDQ_DEPTH)) begin
          w_cnt   <= W_LATENCY;
          w_state <= WS_WAIT;
        end
        WS_WAIT: if (w_cnt == 0) begin
          m_axi_wready <= 1'b1;
          w_state      <= WS_DRAIN;
        end else w_cnt <= w_cnt - 3'd1;
        WS_DRAIN: if (~m_axi_wvalid) w_state <= WS_IDLE;
      endcase
    end

  /* ---- combine AW+W once both queues have an entry: commit, then BVALID.
   * Committing (and popping) address and data together keeps them paired
   * even though each queue fills independently -- exactly the AW/W
   * decoupling AXI4 permits and mem2axi_bridge relies on (it raises AWVALID
   * and WVALID together, but this model must not assume every real slave
   * does). ---- */
  localparam WCS_IDLE = 2'd0, WCS_DELAY = 2'd1, WCS_BVALID = 2'd2;
  reg  [1:0] wc_state;
  reg  [2:0] b_cnt;
  reg [37:0] commit_addr_r;
  reg [63:0] commit_data_r;

  wire awq_pop = (wc_state == WCS_IDLE) && (awq_count != 0) && (wdq_count != 0);
  wire wdq_pop = awq_pop;

  always @(posedge clk)
    if (~rst) begin
      awq_wptr <= 2'd0;
      awq_rptr <= 2'd0;
      awq_count <= 3'd0;
    end else begin
      if (awq_push) begin
        awq_addr[awq_wptr] <= m_axi_awaddr;
        awq_wptr <= awq_wptr + 2'd1;
      end
      if (awq_pop) awq_rptr <= awq_rptr + 2'd1;
      awq_count <= awq_count + (awq_push ? 3'd1 : 3'd0) - (awq_pop ? 3'd1 : 3'd0);
    end

  always @(posedge clk)
    if (~rst) begin
      wdq_wptr <= 2'd0;
      wdq_rptr <= 2'd0;
      wdq_count <= 3'd0;
    end else begin
      if (wdq_push) begin
        wdq_data[wdq_wptr] <= m_axi_wdata;
        wdq_wptr <= wdq_wptr + 2'd1;
      end
      if (wdq_pop) wdq_rptr <= wdq_rptr + 2'd1;
      wdq_count <= wdq_count + (wdq_push ? 3'd1 : 3'd0) - (wdq_pop ? 3'd1 : 3'd0);
    end

  always @(posedge clk)
    if (~rst) begin
      wc_state <= WCS_IDLE;
      m_axi_bvalid <= 1'b0;
      m_axi_bid    <= 4'b0;
      m_axi_bresp  <= 2'b00;
      commit_addr_r <= 38'b0;
      commit_data_r <= 64'b0;
    end else case (wc_state)
      WCS_IDLE: if (awq_count != 0 && wdq_count != 0) begin
        commit_addr_r <= awq_addr[awq_rptr];
        commit_data_r <= wdq_data[wdq_rptr];
        b_cnt         <= B_LATENCY;
        wc_state      <= WCS_DELAY;
      end
      WCS_DELAY: if (b_cnt == 0) begin
        mem[commit_addr_r[16:3]] <= commit_data_r;
        m_axi_bvalid <= 1'b1;
        m_axi_bid    <= 4'b0;
        m_axi_bresp  <= 2'b00;
        wc_state     <= WCS_BVALID;
      end else b_cnt <= b_cnt - 3'd1;
      WCS_BVALID: if (m_axi_bvalid && m_axi_bready) begin
        m_axi_bvalid <= 1'b0;
        wc_state     <= WCS_IDLE;
      end
    endcase

  /* ---- AR channel: accept after AR_LATENCY cycles, latch address ----
   * ARS_DRAIN: see the AWS_DRAIN comment above -- same reasoning, ARVALID
   * lags one cycle behind ARREADY.
   *
   * 2026-09-06 (Fase 8a read pipelining): AR acceptance and R generation are
   * now decoupled through a small address queue (AQ_DEPTH entries) instead
   * of AR only being accepted once the *previous* read's R channel is fully
   * idle. A slave modeling genuine single-outstanding behavior never
   * exercises the scenario this bridge change targets -- multiple reads
   * actually in flight in DRAM at once -- so it could pass while that
   * behavior was silently broken. AQ_DEPTH matches mem2axi_bridge's own
   * RESP_DEPTH so a directed test can legitimately fill the pipeline.
   */
  localparam [1:0] ARS_IDLE = 2'd0, ARS_WAIT = 2'd1, ARS_DRAIN = 2'd2;
  reg [1:0] ar_state;
  reg [2:0] ar_cnt;

  localparam AQ_DEPTH = 4;
  reg [37:0] aq_addr [0:AQ_DEPTH-1];
  reg  [1:0] aq_wptr, aq_rptr;
  reg  [2:0] aq_count;

  localparam RS_IDLE = 2'd0, RS_DELAY = 2'd1, RS_RVALID = 2'd2;
  reg [1:0] r_state;
  reg [2:0] r_cnt;
  reg [37:0]r_addr_r;

  wire aq_push = (ar_state == ARS_WAIT) && (ar_cnt == 0);
  wire aq_pop  = (r_state == RS_IDLE) && (aq_count != 0);

  always @(posedge clk)
    if (~rst) begin
      ar_state <= ARS_IDLE;
      m_axi_arready <= 1'b0;
      aq_wptr <= 2'd0;
      aq_rptr <= 2'd0;
      aq_count <= 3'd0;
      r_state <= RS_IDLE;
      r_addr_r <= 38'b0;
      m_axi_rvalid <= 1'b0;
      m_axi_rdata  <= 64'b0;
      m_axi_rresp  <= 2'b00;
      m_axi_rlast  <= 1'b0;
      m_axi_rid    <= 4'b0;
    end else begin
      m_axi_arready <= 1'b0;
      case (ar_state)
        // only start accepting a new AR while the queue has room -- models
        // a slave with AQ_DEPTH outstanding-read capacity, not infinite
        ARS_IDLE: if (m_axi_arvalid && (aq_count < AQ_DEPTH)) begin
          ar_cnt   <= AR_LATENCY;
          ar_state <= ARS_WAIT;
        end
        ARS_WAIT: if (ar_cnt == 0) begin
          m_axi_arready <= 1'b1;
          ar_state      <= ARS_DRAIN;
        end else ar_cnt <= ar_cnt - 3'd1;
        ARS_DRAIN: if (~m_axi_arvalid) ar_state <= ARS_IDLE;
      endcase

      if (aq_push) begin
        aq_addr[aq_wptr] <= m_axi_araddr;
        aq_wptr <= aq_wptr + 2'd1;
      end
      if (aq_pop) aq_rptr <= aq_rptr + 2'd1;
      aq_count <= aq_count + (aq_push ? 3'd1 : 3'd0) - (aq_pop ? 3'd1 : 3'd0);

      case (r_state)
        RS_IDLE: if (aq_count != 0) begin       // independent of AR acceptance -- true overlap
          r_addr_r <= aq_addr[aq_rptr];
          r_cnt    <= R_LATENCY;
          r_state  <= RS_DELAY;
        end
        RS_DELAY: if (r_cnt == 0) begin
          m_axi_rdata  <= mem[r_addr_r[16:3]];
          m_axi_rresp  <= 2'b00;
          m_axi_rlast  <= 1'b1;
          m_axi_rid    <= 4'b0;
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
