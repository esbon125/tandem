/*
 * testbench.v - mem2axi_bridge + REAL mem_response_fifo (CoreFIFO) unit test
 *
 * Fase 7a (2026-08-22): reproduces the real hardware read-response path --
 * mem2axi_bridge.v (real) -> fifo_dc/xfifo_dc.v (real) -> the actual
 * fifo_mem_rsp_dc_64x128 CoreFIFO instance Libero generated (real control
 * logic: corefifo_async.v, COREFIFO.v, the gray-code synchronizers -- only
 * the RAM1K20 hard-macro storage cell is replaced with a generic behavioral
 * stand-in, see the ram_wrapper.v replacement's header comment (under
 * corefifo/) for why and how that substitution was verified safe).
 *
 * Unlike bench/mem_axi_bridge/testbench.v (which stubs mem_res_wr_* directly
 * at the testbench level, same clock throughout), this drives mem2axi_bridge
 * on its own mem_clk and drains the response fifo on a genuinely different
 * clk -- matching real usage (framestore.v: wr_clk=mem_clk, rd_clk=clk) --
 * so a real CDC bug in the FIFO has a chance to show up.
 *
 * Real bug under investigation: on real hardware, mem2axi_bridge completes
 * writes (BRESP) and reads (RRESP) fine at the AXI4 protocol level, and
 * `vbuf_wr_addr`/write commands drain the request fifo continuously -- but
 * mem_res_valid_cnt (framestore_response.v's count of mem_res_rd_valid
 * pulses) stays at 0 forever: no read response ever reaches framestore_
 * response.v through mem_response_fifo. This testbench isolates exactly
 * that fifo instance (with real control logic) to see if it reproduces.
 */

`include "timescale.v"

`define MEM_CLK_PERIOD 6.173
`define CLK_PERIOD     9.259

module testbench ();

  reg         mem_clk;
  reg         clk;
  reg         rst;

  reg  [1:0]  mem_req_rd_cmd;
  reg  [21:0] mem_req_rd_addr;
  reg  [63:0] mem_req_rd_dta;
  wire        mem_req_rd_en;
  reg         mem_req_rd_valid;
  wire        mem_req_rd_empty;

  wire [63:0] mem_res_wr_dta;
  wire        mem_res_wr_en;
  wire        mem_res_wr_almost_full;

  wire [63:0] mem_res_rd_dta;
  wire        mem_res_rd_en;
  wire        mem_res_rd_empty;
  wire        mem_res_rd_valid;

  wire  [3:0] m_axi_awid;
  wire [37:0] m_axi_awaddr;
  wire  [7:0] m_axi_awlen;
  wire  [2:0] m_axi_awsize;
  wire  [1:0] m_axi_awburst;
  wire        m_axi_awvalid;
  wire        m_axi_awready;

  wire [63:0] m_axi_wdata;
  wire  [7:0] m_axi_wstrb;
  wire        m_axi_wlast;
  wire        m_axi_wvalid;
  wire        m_axi_wready;

  wire  [3:0] m_axi_bid;
  wire  [1:0] m_axi_bresp;
  wire        m_axi_bvalid;
  wire        m_axi_bready;

  wire  [3:0] m_axi_arid;
  wire [37:0] m_axi_araddr;
  wire  [7:0] m_axi_arlen;
  wire  [2:0] m_axi_arsize;
  wire  [1:0] m_axi_arburst;
  wire        m_axi_arvalid;
  wire        m_axi_arready;

  wire  [3:0] m_axi_rid;
  wire [63:0] m_axi_rdata;
  wire  [1:0] m_axi_rresp;
  wire        m_axi_rlast;
  wire        m_axi_rvalid;
  wire        m_axi_rready;

  integer     errors;
  integer     checks;

  /* dut: real mem2axi_bridge, runs on mem_clk (matches framestore.v: .clk(mem_clk_internal)) */
  mem2axi_bridge #(.DDR_BASE(38'h02000000)) dut (
      .clk(mem_clk), .rst(rst),
      .mem_req_rd_cmd(mem_req_rd_cmd), .mem_req_rd_addr(mem_req_rd_addr),
      .mem_req_rd_dta(mem_req_rd_dta), .mem_req_rd_en(mem_req_rd_en), .mem_req_rd_valid(mem_req_rd_valid),
      .mem_req_rd_empty(mem_req_rd_empty),
      .mem_res_wr_dta(mem_res_wr_dta), .mem_res_wr_en(mem_res_wr_en), .mem_res_wr_almost_full(mem_res_wr_almost_full),
      .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
      .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
      .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
      .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
      .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
      .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
      .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
      .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
  );

  fake_axi_ddr slave (
      .clk(mem_clk), .rst(rst),
      .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
      .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
      .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
      .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
      .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
      .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
      .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
      .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
  );

  /* the REAL mem_response_fifo -- identical instantiation to framestore.v's
   * (dta_width=64 selects fifo_mem_rsp_dc_64x128 inside xfifo_dc.v),
   * wr_clk=mem_clk (matches mem2axi_bridge), rd_clk=clk (matches
   * framestore_response.v) -- a genuine clock-domain crossing. */
  fifo_dc #(
      .addr_width(9'd7),
      .dta_width(9'd64),
      .prog_thresh(9'd64),
      .FIFO_XILINX(0)
      )
      mem_response_fifo (
      .wr_rst(rst),
      .rd_rst(rst),
      .wr_clk(mem_clk),
      .din(mem_res_wr_dta),
      .wr_en(mem_res_wr_en),
      .full(),
      .wr_ack(),
      .overflow(),
      .prog_full(mem_res_wr_almost_full),
      .rd_clk(clk),
      .dout(mem_res_rd_dta),
      .rd_en(mem_res_rd_en),
      .empty(mem_res_rd_empty),
      .valid(mem_res_rd_valid),
      .underflow(),
      .prog_empty()
      );

  /* FLUSH-scenario instance -- 2026-08-26, testing framestore_response.v's
   * STATE_FLUSH pattern directly: does holding rd_en high, unconditionally,
   * across a long window while the real mem_response_fifo (fifo_mem_rsp_
   * dc_64x128, FWFT:false) is EMPTY, then dropping it, permanently wedge
   * the fifo the way holding mem_req_rd_en high did for mem_request_fifo
   * (root cause #1, mem2axi_bridge.v)? Same width/depth params as the real
   * mem_response_fifo instance above, same wr_clk=mem_clk/rd_clk=clk
   * orientation as framestore.v's real one. */
  reg  [63:0] flush_din;
  reg         flush_wr_en;
  wire        flush_full;
  wire [63:0] flush_dout;
  reg         flush_rd_en;
  wire        flush_empty;
  wire        flush_valid;

  fifo_dc #(
      .addr_width(9'd7),
      .dta_width(9'd64),
      .prog_thresh(9'd64),
      .FIFO_XILINX(0)
      )
      mem_response_fifo_flush_test (
      .wr_rst(rst),
      .rd_rst(rst),
      .wr_clk(mem_clk),
      .din(flush_din),
      .wr_en(flush_wr_en),
      .full(flush_full),
      .wr_ack(),
      .overflow(),
      .prog_full(),
      .rd_clk(clk),
      .dout(flush_dout),
      .rd_en(flush_rd_en),
      .empty(flush_empty),
      .valid(flush_valid),
      .underflow(),
      .prog_empty()
      );

  /* SECOND real CoreFIFO instance -- fifo_mem_req_dc_88x64 (framestore.v's
   * mem_request_fifo), completely independent copied source, to test
   * whether the same fifo_dc(.rst(~rst)) wiring bug reproduces here too.
   * Driven directly (no mem2axi_bridge/framestore_request.v involved) --
   * just write on wr_clk=mem_clk, read on rd_clk=clk, exactly like
   * mem_response_fifo above. */
  reg  [87:0] req_din;
  reg         req_wr_en;
  wire        req_full;
  wire [87:0] req_dout;
  wire        req_rd_en;
  wire        req_empty;
  wire        req_valid;

  fifo_dc #(
      .addr_width(9'd6),
      .dta_width(9'd88),
      .prog_thresh(9'd32),
      .FIFO_XILINX(0)
      )
      mem_request_fifo_test (
      .wr_rst(rst),
      .rd_rst(rst),
      .wr_clk(mem_clk),
      .din(req_din),
      .wr_en(req_wr_en),
      .full(req_full),
      .wr_ack(),
      .overflow(),
      .prog_full(),
      .rd_clk(clk),
      .dout(req_dout),
      .rd_en(req_rd_en),
      .empty(req_empty),
      .valid(req_valid),
      .underflow(),
      .prog_empty()
      );

  /* THIRD real CoreFIFO instance -- 2026-08-26, mem_req_wr_almost_full
   * investigation continued: mem_request_fifo_test above has wr_clk/rd_clk
   * swapped relative to framestore.v's real mem_request_fifo (wr_clk=clk,
   * rd_clk=mem_clk there) AND gates its rd_en on ~empty, unlike mem2axi_
   * bridge's real S_IDLE behavior (mem_req_rd_en held continuously HIGH
   * regardless of empty, see mem2axi_bridge.v: `mem_req_rd_en <= (next ==
   * S_IDLE)`). Real hardware retest (2026-08-26, with wr_rst/rd_rst fix
   * applied and confirmed via dbg_mem_req_wr_push_cnt/dbg_mem_req_rd_pop_cnt)
   * showed push_cnt=60/pop_cnt=0 forever -- AFULL correct, but EMPTY/DVLD
   * on the *read* (mem_clk) side never assert despite genuine 60-deep
   * occupancy. This instance matches the real orientation and RE-held-high
   * usage exactly, to see if it reproduces in a controlled, fast sim. */
  reg  [87:0] req2_din;
  reg         req2_wr_en;
  wire        req2_full;
  wire [87:0] req2_dout;
  wire        req2_valid;
  wire        req2_empty;

  fifo_dc #(
      .addr_width(9'd6),
      .dta_width(9'd88),
      .prog_thresh(9'd32),
      .FIFO_XILINX(0)
      )
      mem_request_fifo_test2 (
      .wr_rst(rst),
      .rd_rst(rst),
      .wr_clk(clk),          /* matches framestore.v: mem_request_fifo wr_clk=clk */
      .din(req2_din),
      .wr_en(req2_wr_en),
      .full(req2_full),
      .wr_ack(),
      .overflow(),
      .prog_full(),
      .rd_clk(mem_clk),      /* matches framestore.v: mem_request_fifo rd_clk=mem_clk */
      .dout(req2_dout),
      .rd_en(1'b1),          /* held continuously high, matching mem2axi_bridge's real S_IDLE RE */
      .empty(req2_empty),
      .valid(req2_valid),
      .underflow(),
      .prog_empty()
      );

  /* FOURTH instance -- 2026-08-26, the actual fix under test: a real
   * mem2axi_bridge (dut2) driving/driven-by a real mem_request_fifo
   * (same orientation as mem_request_fifo_test2 above, wr_clk=clk/
   * rd_clk=mem_clk), end to end, with mem_req_rd_en now gated on
   * ~mem_req_rd_empty instead of held continuously high (see mem2axi_
   * bridge.v's header comment). Pushes 60 real CMD_WRITE requests
   * (matching the real stuck-at-60 hardware occupancy) and checks all
   * 60 actually reach slave2 as AXI4 writes -- proving the fix pops the
   * whole fifo instead of stalling after ~3 like req2 above (unfixed
   * RE-held-high) does. */
  reg  [87:0] e2e_din;
  reg         e2e_wr_en;
  wire        e2e_full;
  wire [87:0] e2e_dout;
  wire        e2e_rd_en;
  wire        e2e_valid;
  wire        e2e_empty;

  wire [1:0]  e2e_mem_req_rd_cmd  = e2e_dout[87:86];
  wire [21:0] e2e_mem_req_rd_addr = e2e_dout[85:64];
  wire [63:0] e2e_mem_req_rd_dta  = e2e_dout[63:0];

  fifo_dc #(
      .addr_width(9'd6),
      .dta_width(9'd88),
      .prog_thresh(9'd32),
      .FIFO_XILINX(0)
      )
      mem_request_fifo_e2e (
      .wr_rst(rst),
      .rd_rst(rst),
      .wr_clk(clk),
      .din(e2e_din),
      .wr_en(e2e_wr_en),
      .full(e2e_full),
      .wr_ack(),
      .overflow(),
      .prog_full(),
      .rd_clk(mem_clk),
      .dout(e2e_dout),
      .rd_en(e2e_rd_en),
      .empty(e2e_empty),
      .valid(e2e_valid),
      .underflow(),
      .prog_empty()
      );

  wire  [3:0] m2_axi_awid;
  wire [37:0] m2_axi_awaddr;
  wire  [7:0] m2_axi_awlen;
  wire  [2:0] m2_axi_awsize;
  wire  [1:0] m2_axi_awburst;
  wire        m2_axi_awvalid;
  wire        m2_axi_awready;
  wire [63:0] m2_axi_wdata;
  wire  [7:0] m2_axi_wstrb;
  wire        m2_axi_wlast;
  wire        m2_axi_wvalid;
  wire        m2_axi_wready;
  wire  [3:0] m2_axi_bid;
  wire  [1:0] m2_axi_bresp;
  wire        m2_axi_bvalid;
  wire        m2_axi_bready;
  wire  [3:0] m2_axi_arid;
  wire [37:0] m2_axi_araddr;
  wire  [7:0] m2_axi_arlen;
  wire  [2:0] m2_axi_arsize;
  wire  [1:0] m2_axi_arburst;
  wire        m2_axi_arvalid;
  wire        m2_axi_arready;
  wire  [3:0] m2_axi_rid;
  wire [63:0] m2_axi_rdata;
  wire  [1:0] m2_axi_rresp;
  wire        m2_axi_rlast;
  wire        m2_axi_rvalid;
  wire        m2_axi_rready;
  wire [63:0] e2e_mem_res_wr_dta;
  wire        e2e_mem_res_wr_en;

  mem2axi_bridge #(.DDR_BASE(38'h02000000)) dut2 (
      .clk(mem_clk), .rst(rst),
      .mem_req_rd_cmd(e2e_mem_req_rd_cmd), .mem_req_rd_addr(e2e_mem_req_rd_addr),
      .mem_req_rd_dta(e2e_mem_req_rd_dta), .mem_req_rd_en(e2e_rd_en), .mem_req_rd_valid(e2e_valid),
      .mem_req_rd_empty(e2e_empty),
      .mem_res_wr_dta(e2e_mem_res_wr_dta), .mem_res_wr_en(e2e_mem_res_wr_en), .mem_res_wr_almost_full(1'b0),
      .m_axi_awid(m2_axi_awid), .m_axi_awaddr(m2_axi_awaddr), .m_axi_awlen(m2_axi_awlen),
      .m_axi_awsize(m2_axi_awsize), .m_axi_awburst(m2_axi_awburst), .m_axi_awvalid(m2_axi_awvalid), .m_axi_awready(m2_axi_awready),
      .m_axi_wdata(m2_axi_wdata), .m_axi_wstrb(m2_axi_wstrb), .m_axi_wlast(m2_axi_wlast), .m_axi_wvalid(m2_axi_wvalid), .m_axi_wready(m2_axi_wready),
      .m_axi_bid(m2_axi_bid), .m_axi_bresp(m2_axi_bresp), .m_axi_bvalid(m2_axi_bvalid), .m_axi_bready(m2_axi_bready),
      .m_axi_arid(m2_axi_arid), .m_axi_araddr(m2_axi_araddr), .m_axi_arlen(m2_axi_arlen),
      .m_axi_arsize(m2_axi_arsize), .m_axi_arburst(m2_axi_arburst), .m_axi_arvalid(m2_axi_arvalid), .m_axi_arready(m2_axi_arready),
      .m_axi_rid(m2_axi_rid), .m_axi_rdata(m2_axi_rdata), .m_axi_rresp(m2_axi_rresp),
      .m_axi_rlast(m2_axi_rlast), .m_axi_rvalid(m2_axi_rvalid), .m_axi_rready(m2_axi_rready)
  );

  fake_axi_ddr slave2 (
      .clk(mem_clk), .rst(rst),
      .m_axi_awid(m2_axi_awid), .m_axi_awaddr(m2_axi_awaddr), .m_axi_awlen(m2_axi_awlen),
      .m_axi_awsize(m2_axi_awsize), .m_axi_awburst(m2_axi_awburst), .m_axi_awvalid(m2_axi_awvalid), .m_axi_awready(m2_axi_awready),
      .m_axi_wdata(m2_axi_wdata), .m_axi_wstrb(m2_axi_wstrb), .m_axi_wlast(m2_axi_wlast), .m_axi_wvalid(m2_axi_wvalid), .m_axi_wready(m2_axi_wready),
      .m_axi_bid(m2_axi_bid), .m_axi_bresp(m2_axi_bresp), .m_axi_bvalid(m2_axi_bvalid), .m_axi_bready(m2_axi_bready),
      .m_axi_arid(m2_axi_arid), .m_axi_araddr(m2_axi_araddr), .m_axi_arlen(m2_axi_arlen),
      .m_axi_arsize(m2_axi_arsize), .m_axi_arburst(m2_axi_arburst), .m_axi_arvalid(m2_axi_arvalid), .m_axi_arready(m2_axi_arready),
      .m_axi_rid(m2_axi_rid), .m_axi_rdata(m2_axi_rdata), .m_axi_rresp(m2_axi_rresp),
      .m_axi_rlast(m2_axi_rlast), .m_axi_rvalid(m2_axi_rvalid), .m_axi_rready(m2_axi_rready)
  );

  /* count real AXI4 writes dut2 completes, to verify all 60 pushed
   * CMD_WRITEs actually drain instead of stalling like req2 does */
  integer e2e_writes_done;
  always @(posedge mem_clk)
    if (~rst) e2e_writes_done <= 0;
    else if (m2_axi_awvalid && m2_axi_awready) e2e_writes_done <= e2e_writes_done + 1;

  /* clocks -- genuinely different rates/phases, matching real core_clk/mem_clk */
  initial begin
    mem_clk = 1'b0;
    forever #(`MEM_CLK_PERIOD / 2) mem_clk = ~mem_clk;
  end

  initial begin
    clk = 1'b0;
    forever #(`CLK_PERIOD / 2) clk = ~clk;
  end

  /* reset */
  initial begin
    rst = 1'b0;
    #(`MEM_CLK_PERIOD * 4);
    rst = 1'b1;
  end

  /* Watchdog */
  initial begin
    #2000000;
    $display("TIMEOUT: simulation did not finish in time (stuck handshake?)");
    $finish;
  end

  initial begin
    mem_req_rd_cmd = 2'b00;
    mem_req_rd_addr = 22'b0;
    mem_req_rd_dta = 64'b0;
    mem_req_rd_valid = 1'b0;
    req_din = 88'b0;
    req_wr_en = 1'b0;
    req2_din = 88'b0;
    req2_wr_en = 1'b0;
    e2e_din = 88'b0;
    e2e_wr_en = 1'b0;
    flush_din = 64'b0;
    flush_wr_en = 1'b0;
    flush_rd_en = 1'b0;
  end

  assign req_rd_en = rst & ~req_empty;

  /* mem_req_rd BFM -- identical to bench/mem_axi_bridge/testbench.v's, on mem_clk */
  reg  [1:0]  q_cmd;
  reg  [21:0] q_addr;
  reg  [63:0] q_dta;
  reg         q_pending;

  /* 2026-08-26: dut now gates rd_en on ~mem_req_rd_empty -- see
   * bench/mem_axi_bridge/testbench.v's identical comment. */
  assign mem_req_rd_empty = ~q_pending;

  always @(posedge mem_clk)
    if (~rst) begin
      mem_req_rd_valid <= 1'b0;
      q_pending        <= 1'b0;
    end else if (mem_req_rd_en && q_pending) begin
      mem_req_rd_cmd   <= q_cmd;
      mem_req_rd_addr  <= q_addr;
      mem_req_rd_dta   <= q_dta;
      mem_req_rd_valid <= 1'b1;
      q_pending        <= 1'b0;
    end else begin
      mem_req_rd_valid <= 1'b0;
    end

  task push_req;
    input [1:0]  cmd;
    input [21:0] addr;
    input [63:0] dta;
    begin
      @(posedge mem_clk);
      #1;
      q_cmd     = cmd;
      q_addr    = addr;
      q_dta     = dta;
      q_pending = 1'b1;
      wait (mem_req_rd_valid === 1'b1);
      @(posedge mem_clk);
      #1;
    end
  endtask

  /* drain the REAL response fifo on clk, free-running (like framestore_
   * response.v's STATE_READ -- request a pop whenever not empty).
   * Combinational, matching FWFT semantics (dout valid the same cycle
   * empty=0, rd_en pops it) -- a registered version caused spurious
   * "reading when empty" once the reset fix let the fifo actually
   * transact instead of sitting permanently empty. */
  assign mem_res_rd_en = rst & ~mem_res_rd_empty;

  /* wait for the fifo to actually deliver a valid word (crossing from
   * mem_clk into clk -- this is the real, previously-unexercised path) */
  task wait_res;
    output [63:0] dta;
    integer       timeout;
    begin
      timeout = 0;
      while (!(mem_res_rd_valid === 1'b1)) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 200) begin
          errors = errors + 1;
          checks = checks + 1;
          $display("FAIL wait_res: timed out waiting for mem_res_rd_valid (fifo empty=%b)", mem_res_rd_empty);
          dta = 64'hDEAD_DEAD_DEAD_DEAD;
          disable wait_res;
        end
      end
      dta = mem_res_rd_dta;
      @(posedge clk);
    end
  endtask

  task check_eq64;
    input [255:0] name;
    input [63:0]  got;
    input [63:0]  expected;
    begin
      checks = checks + 1;
      if (got !== expected) begin
        errors = errors + 1;
        $display("FAIL %0s: got 0x%016h, expected 0x%016h", name, got, expected);
      end else begin
        $display("PASS %0s: 0x%016h", name, got);
      end
    end
  endtask

  reg [63:0] rdata;

`ifdef DEBUG_TRACE
  initial $monitor("t=%0t mem_res_wr_en=%b mem_res_wr_dta=%h mem_res_wr_almost_full=%b | fifo: empty=%b valid=%b dout=%h full=%b",
    $time, mem_res_wr_en, mem_res_wr_dta, mem_res_wr_almost_full,
    mem_res_rd_empty, mem_res_rd_valid, mem_res_rd_dta, mem_response_fifo.full);
`endif

`ifdef DEBUG_TRACE2
  initial $monitor("t=%0t we_i=%b re_i=%b wptr=%0d rptr=%0d wptr_gray=%b rptr_gray=%b rdiff_bus=%0d empty_r=%b aresetn_rclk=%b sresetn_rclk=%b aresetn_wclk=%b sresetn_wclk=%b",
    $time,
    mem_response_fifo.genblk1.xfifo_dc.genblk2.genblk2.mem_rsp_fifo_dc.fifo_mem_rsp_dc_64x128_0.sync0_wge_gen.U_corefifo_async.we_i,
    mem_response_fifo.genblk1.xfifo_dc.genblk2.genblk2.mem_rsp_fifo_dc.fifo_mem_rsp_dc_64x128_0.sync0_wge_gen.U_corefifo_async.re_i,
    mem_response_fifo.genblk1.xfifo_dc.genblk2.genblk2.mem_rsp_fifo_dc.fifo_mem_rsp_dc_64x128_0.sync0_wge_gen.U_corefifo_async.wptr,
    mem_response_fifo.genblk1.xfifo_dc.genblk2.genblk2.mem_rsp_fifo_dc.fifo_mem_rsp_dc_64x128_0.sync0_wge_gen.U_corefifo_async.rptr,
    mem_response_fifo.genblk1.xfifo_dc.genblk2.genblk2.mem_rsp_fifo_dc.fifo_mem_rsp_dc_64x128_0.sync0_wge_gen.U_corefifo_async.wptr_gray,
    mem_response_fifo.genblk1.xfifo_dc.genblk2.genblk2.mem_rsp_fifo_dc.fifo_mem_rsp_dc_64x128_0.sync0_wge_gen.U_corefifo_async.rptr_gray,
    mem_response_fifo.genblk1.xfifo_dc.genblk2.genblk2.mem_rsp_fifo_dc.fifo_mem_rsp_dc_64x128_0.sync0_wge_gen.U_corefifo_async.rdiff_bus,
    mem_response_fifo.genblk1.xfifo_dc.genblk2.genblk2.mem_rsp_fifo_dc.fifo_mem_rsp_dc_64x128_0.sync0_wge_gen.U_corefifo_async.empty_r,
    mem_response_fifo.genblk1.xfifo_dc.genblk2.genblk2.mem_rsp_fifo_dc.fifo_mem_rsp_dc_64x128_0.sync0_wge_gen.U_corefifo_async.aresetn_rclk,
    mem_response_fifo.genblk1.xfifo_dc.genblk2.genblk2.mem_rsp_fifo_dc.fifo_mem_rsp_dc_64x128_0.sync0_wge_gen.U_corefifo_async.sresetn_rclk,
    mem_response_fifo.genblk1.xfifo_dc.genblk2.genblk2.mem_rsp_fifo_dc.fifo_mem_rsp_dc_64x128_0.sync0_wge_gen.U_corefifo_async.aresetn_wclk,
    mem_response_fifo.genblk1.xfifo_dc.genblk2.genblk2.mem_rsp_fifo_dc.fifo_mem_rsp_dc_64x128_0.sync0_wge_gen.U_corefifo_async.sresetn_wclk);
`endif

  initial begin
    errors = 0;
    checks = 0;
    rdata  = 64'b0;

    wait (rst === 1'b1);
    repeat (5) @(posedge mem_clk);

    /* single write then read-back, through the REAL CoreFIFO response path */
    push_req(2'b11 /* CMD_WRITE */, 22'h000010, 64'hdead_beef_0000_0001);
    push_req(2'b10 /* CMD_READ */,  22'h000010, 64'b0);
    wait_res(rdata);
    check_eq64("write then read back through real mem_response_fifo, addr 0x10", rdata, 64'hdead_beef_0000_0001);

    push_req(2'b11, 22'h000123, 64'h1111_2222_3333_4444);
    push_req(2'b10, 22'h000123, 64'b0);
    wait_res(rdata);
    check_eq64("write then read back, addr 0x123", rdata, 64'h1111_2222_3333_4444);

    /* several reads in a row, no idle in between -- stresses the async
     * pointer/gray-code synchronizers with back-to-back CDC crossings,
     * closer to the real hardware scenario (many reads dispatched close
     * together once vbuf becomes non-empty) */
    push_req(2'b11, 22'h000200, 64'haaaa_aaaa_aaaa_aaaa);
    push_req(2'b11, 22'h000201, 64'hbbbb_bbbb_bbbb_bbbb);
    push_req(2'b11, 22'h000202, 64'hcccc_cccc_cccc_cccc);
    push_req(2'b10, 22'h000200, 64'b0);
    push_req(2'b10, 22'h000201, 64'b0);
    push_req(2'b10, 22'h000202, 64'b0);
    wait_res(rdata);
    check_eq64("back-to-back reads through real fifo: 0x200", rdata, 64'haaaa_aaaa_aaaa_aaaa);
    wait_res(rdata);
    check_eq64("back-to-back reads through real fifo: 0x201", rdata, 64'hbbbb_bbbb_bbbb_bbbb);
    wait_res(rdata);
    check_eq64("back-to-back reads through real fifo: 0x202", rdata, 64'hcccc_cccc_cccc_cccc);

    /* many reads (16, matching the exact count observed stuck on real
     * hardware) to see if the fifo/CDC degrades or stalls after some count */
    begin : many_reads
      integer i;
      reg [63:0] expect_val;
      for (i = 0; i < 16; i = i + 1) begin
        push_req(2'b11, 22'h000300 + i, {32'hf00d_0000 + i, 32'hf00d_0000 + i});
      end
      for (i = 0; i < 16; i = i + 1) begin
        push_req(2'b10, 22'h000300 + i, 64'b0);
        wait_res(rdata);
        expect_val = {32'hf00d_0000 + i, 32'hf00d_0000 + i};
        check_eq64("16-read stress, matching real hw's stuck-at-16 count", rdata, expect_val);
      end
    end

    /* FLUSH-scenario test -- reproduces framestore_response.v's OLD
     * STATE_FLUSH behavior directly against the real mem_response_fifo
     * shape: hold rd_en high, unconditionally, for a long window while
     * genuinely empty (scaled down from the real 65536 cycles -- the
     * mechanism doesn't depend on the exact count, only on "RE held high
     * across an empty window, then dropped"), then push real writes and
     * drain with properly-gated RE (matching the STATE_READ/fixed path)
     * to see whether the fifo ever recovers. */
    begin : res_flush_test
      integer i;
      integer timeout;
      integer got_count;

      flush_rd_en = 1'b0;
      @(posedge clk);
      flush_rd_en = 1'b1;
      for (i = 0; i < 500; i = i + 1) @(posedge clk);
      flush_rd_en = 1'b0;

      $display("[%0t] res_flush_test: released RE after 500-cycle empty hold, flush_empty=%b", $time, flush_empty);

      for (i = 0; i < 10; i = i + 1) begin
        @(posedge mem_clk);
        #1;
        flush_din   = 64'hF1F0_0000_0000_0000 + i;
        flush_wr_en = 1'b1;
        @(posedge mem_clk);
        #1;
        flush_wr_en = 1'b0;
      end

      got_count = 0;
      timeout = 0;
      while (got_count < 10 && timeout < 5000) begin
        @(posedge clk);
        #1;
        flush_rd_en = ~flush_empty & ~flush_rd_en;
        if (flush_valid === 1'b1) got_count = got_count + 1;
        timeout = timeout + 1;
      end

      checks = checks + 1;
      if (got_count == 10) begin
        $display("[%0t] RESULT res_flush_test: PASS -- all 10 words delivered after the bounded RE-held-high-while-empty flush window. STATE_FLUSH does NOT wedge the real fifo in sim.", $time);
      end else begin
        errors = errors + 1;
        $display("[%0t] RESULT res_flush_test: FAIL -- only %0d/10 words delivered (flush_empty=%b flush_full=%b). STATE_FLUSH's RE-held-high DOES wedge the real fifo.",
                  $time, got_count, flush_empty, flush_full);
      end
    end

    /* Second CoreFIFO instance test -- fifo_mem_req_dc_88x64, completely
     * independent copied source, driven directly (bypassing mem2axi_bridge
     * entirely). Tests whether the same fifo_dc(.rst(~rst)) wiring reaches
     * the same internal-reset-stuck state here too. */
    begin : req_fifo_test
      integer timeout;
      @(posedge mem_clk);
      #1;
      req_din   = 88'hAAAA_1111_2222_3333_4444;
      req_wr_en = 1'b1;
      @(posedge mem_clk);
      #1;
      req_wr_en = 1'b0;

      timeout = 0;
      while (!(req_valid === 1'b1)) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 200) begin
          checks = checks + 1;
          errors = errors + 1;
          $display("FAIL mem_request_fifo (fifo_mem_req_dc_88x64): req_valid never asserted, empty=%b -- SAME bug reproduces here too", req_empty);
          disable req_fifo_test;
        end
      end
      if (req_valid === 1'b1) begin
        checks = checks + 1;
        if (req_dout !== 88'hAAAA_1111_2222_3333_4444) begin
          errors = errors + 1;
          $display("FAIL mem_request_fifo delivered wrong data: got 0x%022h, expected 0x%022h", req_dout, 88'hAAAA_1111_2222_3333_4444);
        end else begin
          $display("PASS mem_request_fifo (fifo_mem_req_dc_88x64) delivered a word correctly -- bug does NOT reproduce here: 0x%022h", req_dout);
        end
      end
    end

    /* THIRD CoreFIFO instance test -- real orientation (wr_clk=clk, rd_clk=
     * mem_clk) and RE held continuously high (matching mem2axi_bridge's real
     * S_IDLE behavior), pushing 60 words (matching the real stuck-at-60
     * occupancy seen on hardware) to see if DVLD/valid ever assert. */
    begin : req_fifo_test2
      integer i;
      integer timeout;
      reg [87:0] expect_val;
      integer got_count;

      for (i = 0; i < 60; i = i + 1) begin
        @(posedge clk);
        #1;
        req2_din   = {24'hAAAAAA, 32'hF00D_0000 + i, 32'hF00D_0000 + i};
        req2_wr_en = 1'b1;
        @(posedge clk);
        #1;
        req2_wr_en = 1'b0;
      end

      $display("[%0t] req_fifo_test2: pushed 60 words, req2_empty=%b, waiting for req2_valid...", $time, req2_empty);

      got_count = 0;
      timeout = 0;
      while (got_count < 60 && timeout < 5000) begin
        @(posedge mem_clk);
        timeout = timeout + 1;
        if (req2_valid === 1'b1) begin
          expect_val = {24'hAAAAAA, 32'hF00D_0000 + got_count, 32'hF00D_0000 + got_count};
          if (req2_dout !== expect_val) begin
            $display("[%0t] req_fifo_test2: word %0d MISMATCH got=0x%022h expected=0x%022h",
                      $time, got_count, req2_dout, expect_val);
          end
          got_count = got_count + 1;
        end
      end

      checks = checks + 1;
      if (got_count == 60) begin
        $display("[%0t] RESULT req_fifo_test2: PASS -- all 60 words delivered (real orientation + RE held high). Hypothesis NOT reproduced in sim.", $time);
      end else begin
        errors = errors + 1;
        $display("[%0t] RESULT req_fifo_test2: FAIL -- only %0d/60 words delivered before timeout (req2_empty=%b req2_full=%b). Hypothesis REPRODUCED.",
                  $time, got_count, req2_empty, req2_full);
      end
    end

    /* FOURTH test -- the actual fix, end to end: real mem2axi_bridge (dut2)
     * + real mem_request_fifo (mem_request_fifo_e2e), mem_req_rd_en now
     * gated on ~empty. Push 60 real CMD_WRITE requests (distinct addresses/
     * data, matching the real stuck-at-60 hardware occupancy) and confirm
     * dut2 actually completes all 60 AXI4 writes instead of stalling like
     * req_fifo_test2 (unfixed) does above. */
    begin : e2e_fix_test
      integer     i;
      integer     timeout;
      reg  [21:0] e2e_addr;
      reg  [31:0] e2e_dta_half;

      for (i = 0; i < 60; i = i + 1) begin
        e2e_addr     = 22'h001000 + i[21:0];
        e2e_dta_half = 32'hE2E0_0000 + i[31:0];
        @(posedge clk);
        #1;
        /* explicit-width locals above -- packing "22'h001000 + i" (an
         * unsized integer) directly inside a concatenation self-determines
         * the sum's width from its widest operand (32 bits, from i), not
         * the 22-bit literal, silently growing the concatenation past 88
         * bits and truncating/misaligning every field (first attempt here
         * showed cmd_r always decoding as CMD_NOOP). */
        e2e_din   = {2'b11 /* CMD_WRITE */, e2e_addr, e2e_dta_half, e2e_dta_half};
        e2e_wr_en = 1'b1;
        @(posedge clk);
        #1;
        e2e_wr_en = 1'b0;
      end

      $display("[%0t] e2e_fix_test: pushed 60 real CMD_WRITE requests, e2e_empty=%b", $time, e2e_empty);

      timeout = 0;
      while (e2e_writes_done < 60 && timeout < 20000) begin
        @(posedge mem_clk);
        timeout = timeout + 1;
`ifdef DEBUG_E2E
        if (e2e_writes_done >= 29 && timeout < 3000)
          $display("[%0t] dbg: state=%0d rd_en=%b valid=%b empty=%b writes_done=%0d | internal: empty_r=%b wptr=%0d rptr=%0d wptr_gray=%b rptr_gray=%b wptr_gray_sync=%b rdiff_bus=%0d we_i=%b re_i=%b",
                    $time, dut2.state, e2e_rd_en, e2e_valid, e2e_empty, e2e_writes_done,
                    mem_request_fifo_e2e.genblk1.xfifo_dc.genblk2.genblk3.mem_req_fifo_dc.fifo_mem_req_dc_88x64_0.sync0_wge_gen.U_corefifo_async.empty_r,
                    mem_request_fifo_e2e.genblk1.xfifo_dc.genblk2.genblk3.mem_req_fifo_dc.fifo_mem_req_dc_88x64_0.sync0_wge_gen.U_corefifo_async.wptr,
                    mem_request_fifo_e2e.genblk1.xfifo_dc.genblk2.genblk3.mem_req_fifo_dc.fifo_mem_req_dc_88x64_0.sync0_wge_gen.U_corefifo_async.rptr,
                    mem_request_fifo_e2e.genblk1.xfifo_dc.genblk2.genblk3.mem_req_fifo_dc.fifo_mem_req_dc_88x64_0.sync0_wge_gen.U_corefifo_async.wptr_gray,
                    mem_request_fifo_e2e.genblk1.xfifo_dc.genblk2.genblk3.mem_req_fifo_dc.fifo_mem_req_dc_88x64_0.sync0_wge_gen.U_corefifo_async.rptr_gray,
                    mem_request_fifo_e2e.genblk1.xfifo_dc.genblk2.genblk3.mem_req_fifo_dc.fifo_mem_req_dc_88x64_0.sync0_wge_gen.U_corefifo_async.wptr_gray_sync,
                    mem_request_fifo_e2e.genblk1.xfifo_dc.genblk2.genblk3.mem_req_fifo_dc.fifo_mem_req_dc_88x64_0.sync0_wge_gen.U_corefifo_async.rdiff_bus,
                    mem_request_fifo_e2e.genblk1.xfifo_dc.genblk2.genblk3.mem_req_fifo_dc.fifo_mem_req_dc_88x64_0.sync0_wge_gen.U_corefifo_async.we_i,
                    mem_request_fifo_e2e.genblk1.xfifo_dc.genblk2.genblk3.mem_req_fifo_dc.fifo_mem_req_dc_88x64_0.sync0_wge_gen.U_corefifo_async.re_i);
`endif
      end

      checks = checks + 1;
      if (e2e_writes_done == 60) begin
        $display("[%0t] RESULT e2e_fix_test: PASS -- all 60 real AXI4 writes completed through the fixed mem2axi_bridge + real CoreFIFO. FIX CONFIRMED IN SIM.", $time);
      end else begin
        errors = errors + 1;
        $display("[%0t] RESULT e2e_fix_test: FAIL -- only %0d/60 writes completed before timeout (e2e_empty=%b e2e_full=%b). Fix did NOT resolve the stall in sim.",
                  $time, e2e_writes_done, e2e_empty, e2e_full);
      end
    end

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $display("%0d TEST(S) FAILED out of %0d checks", errors, checks);

    $finish;
  end

endmodule
/* not truncated */
