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
 * AXI4 reads/writes on the fabric-master FIC_0 port. Fully serialized
 * (rather than pipelined) is a deliberate first cut for correctness; if the
 * real FIC_0/DDR4 round-trip latency turns out to starve the decoder,
 * pipelining multiple outstanding requests (distinct AXI ids) is the next
 * lever, without changing this module's interface.
 *
 * CMD_REFRESH/CMD_NOOP are acknowledged without any AXI transaction:
 * mpeg2fpga is built with REFRESH_EN=1'b0 (see framestore_request.v), so
 * DRAM refresh is left entirely to the MSS's own DDR4 controller and
 * CMD_REFRESH is never actually issued in practice.
 *
 * clk is expected to be the same clock driving the FIC_0 AXI4 initiator
 * port (m_axi_aclk tied to clk externally) -- do not feed this module from
 * a second, independently generated PLL/CCC. See the Fase 5b/5d bring-up
 * notes (docs/bringup/06_mss_integration_fase5b.md,
 * docs/bringup/09_fase5d_hardware_hang_investigation.md) for the class of
 * bug that causes: two nominally-identical but unsynchronized clocks.
 *
 * DDR_BASE must be 32 MiB aligned (addr<<3 spans 25 bits) so the address
 * translation never carries into bits the firmware side doesn't expect to
 * move.
 */

`include "timescale.v"

module mem2axi_bridge (
    clk, rst,

    /* mpeg2video memory-controller interface (mem_clk domain) */
    mem_req_rd_cmd, mem_req_rd_addr, mem_req_rd_dta, mem_req_rd_en, mem_req_rd_valid,
    mem_res_wr_dta, mem_res_wr_en, mem_res_wr_almost_full,

    /* AXI4 master (FIC_0 fabric-initiator side) */
    m_axi_awid, m_axi_awaddr, m_axi_awlen, m_axi_awsize, m_axi_awburst, m_axi_awvalid, m_axi_awready,
    m_axi_wdata, m_axi_wstrb, m_axi_wlast, m_axi_wvalid, m_axi_wready,
    m_axi_bid, m_axi_bresp, m_axi_bvalid, m_axi_bready,
    m_axi_arid, m_axi_araddr, m_axi_arlen, m_axi_arsize, m_axi_arburst, m_axi_arvalid, m_axi_arready,
    m_axi_rid, m_axi_rdata, m_axi_rresp, m_axi_rlast, m_axi_rvalid, m_axi_rready
);

  parameter [37:0] DDR_BASE = 38'h0;

  input            clk;
  input            rst;               // active low, synchronous -- matches mpeg2video's "rst" convention

  /* mpeg2video memory-controller interface */
  input       [1:0]mem_req_rd_cmd;
  input      [21:0]mem_req_rd_addr;
  input      [63:0]mem_req_rd_dta;
  output reg       mem_req_rd_en;
  input            mem_req_rd_valid;
  output reg [63:0]mem_res_wr_dta;
  output reg       mem_res_wr_en;
  input            mem_res_wr_almost_full;

  /* AXI4 write address channel */
  output      [7:0]m_axi_awid;
  output reg [37:0]m_axi_awaddr;
  output      [7:0]m_axi_awlen;
  output      [2:0]m_axi_awsize;
  output      [1:0]m_axi_awburst;
  output reg       m_axi_awvalid;
  input            m_axi_awready;

  /* AXI4 write data channel */
  output reg [63:0]m_axi_wdata;
  output      [7:0]m_axi_wstrb;
  output           m_axi_wlast;
  output reg       m_axi_wvalid;
  input            m_axi_wready;

  /* AXI4 write response channel */
  input       [7:0]m_axi_bid;
  input       [1:0]m_axi_bresp;
  input            m_axi_bvalid;
  output           m_axi_bready;

  /* AXI4 read address channel */
  output      [7:0]m_axi_arid;
  output reg [37:0]m_axi_araddr;
  output      [7:0]m_axi_arlen;
  output      [2:0]m_axi_arsize;
  output      [1:0]m_axi_arburst;
  output reg       m_axi_arvalid;
  input            m_axi_arready;

  /* AXI4 read data channel */
  input       [7:0]m_axi_rid;
  input      [63:0]m_axi_rdata;
  input       [1:0]m_axi_rresp;
  input            m_axi_rlast;
  input            m_axi_rvalid;
  output           m_axi_rready;

  /* fixed, single-outstanding-transaction attributes: id 0, single 64-bit
   * beat (len=0), 8 bytes/beat, incrementing burst (irrelevant at len=0,
   * INCR is the safe default every AXI4 slave accepts). */
  assign m_axi_awid    = 8'd0;
  assign m_axi_awlen   = 8'd0;
  assign m_axi_awsize  = 3'b011;
  assign m_axi_awburst = 2'b01;
  assign m_axi_wstrb   = 8'hff;
  assign m_axi_wlast   = 1'b1;
  assign m_axi_arid    = 8'd0;
  assign m_axi_arlen   = 8'd0;
  assign m_axi_arsize  = 3'b011;
  assign m_axi_arburst = 2'b01;

`include "mem_codes.v"

  localparam [2:0]
    S_IDLE   = 3'd0,   // popping mem_req_rd; mem_req_rd_en asserted
    S_LATCH  = 3'd1,   // mem_req_rd_valid seen last cycle; cmd_r/addr_r/dta_r valid, decode cmd
    S_WRITE  = 3'd2,   // AW/W outstanding, waiting on awready/wready
    S_BRESP  = 3'd3,   // waiting on bvalid
    S_ARADDR = 3'd4,   // AR outstanding, waiting on arready
    S_RDATA  = 3'd5,   // waiting on rvalid
    S_RESP   = 3'd6;   // pushing mem_res_wr, respecting mem_res_wr_almost_full

  reg [2:0]state;
  reg [2:0]next;

  reg  [1:0]cmd_r;
  reg [21:0]addr_r;
  reg [63:0]dta_r;

  reg       aw_done;   // AWREADY already seen this transaction
  reg       w_done;    // WREADY already seen this transaction

  wire [37:0]axi_addr = DDR_BASE + {addr_r, 3'b000};

  /* next-state logic */
  always @* begin
    case (state)
      S_IDLE:   next = mem_req_rd_valid ? S_LATCH : S_IDLE;
      S_LATCH:  case (cmd_r)
                  CMD_WRITE: next = S_WRITE;
                  CMD_READ:  next = S_ARADDR;
                  default:   next = S_IDLE;      // CMD_NOOP / CMD_REFRESH: no AXI transaction
                endcase
      S_WRITE:  next = ((aw_done || m_axi_awready) && (w_done || m_axi_wready)) ? S_BRESP : S_WRITE;
      S_BRESP:  next = m_axi_bvalid ? S_IDLE : S_BRESP;
      S_ARADDR: next = m_axi_arready ? S_RDATA : S_ARADDR;
      S_RDATA:  next = m_axi_rvalid ? S_RESP : S_RDATA;
      S_RESP:   next = mem_res_wr_almost_full ? S_RESP : S_IDLE;
      default:  next = S_IDLE;
    endcase
  end

  always @(posedge clk)
    if (~rst) state <= S_IDLE;
    else state <= next;

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

  /* pop mem_req_rd fifo: hold rd_en while idle so a request is captured the
   * cycle it becomes valid; drop it as soon as one is latched. */
  always @(posedge clk)
    if (~rst) mem_req_rd_en <= 1'b0;
    else mem_req_rd_en <= (next == S_IDLE);

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

  assign m_axi_bready = (state == S_BRESP);

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

  assign m_axi_rready = (state == S_RDATA);

  /* capture the read result, then push it once the response fifo has room */
  always @(posedge clk)
    if (~rst) mem_res_wr_dta <= 64'b0;
    else if ((state == S_RDATA) && m_axi_rvalid) mem_res_wr_dta <= m_axi_rdata;

  always @(posedge clk)
    if (~rst) mem_res_wr_en <= 1'b0;
    else if (state == S_RESP) mem_res_wr_en <= ~mem_res_wr_almost_full;
    else mem_res_wr_en <= 1'b0;

`undef CHECK
`ifdef __IVERILOG__
`define CHECK 1
`endif

`ifdef CHECK
  always @(posedge clk)
    if ((state == S_BRESP) && m_axi_bvalid && (m_axi_bresp != 2'b00))
      $display("%m\t*** warning: AXI write to %h got BRESP %b (not OKAY) ***", m_axi_awaddr, m_axi_bresp);

  always @(posedge clk)
    if ((state == S_RDATA) && m_axi_rvalid && (m_axi_rresp != 2'b00))
      $display("%m\t*** warning: AXI read from %h got RRESP %b (not OKAY) ***", m_axi_araddr, m_axi_rresp);

  always @(posedge clk)
    if ((state == S_RDATA) && m_axi_rvalid && ~m_axi_rlast)
      begin
        $display("%m\t*** error: single-beat read did not see RLAST ***");
        $stop;
      end
`endif

endmodule
/* not truncated */
