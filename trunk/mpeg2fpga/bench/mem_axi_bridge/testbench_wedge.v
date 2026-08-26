/*
 * testbench_wedge.v - write-side analogue of bench/stream_dma/testbench_
 * wedge.v: exercises the AXI4-interconnect wedge scenario and the
 * graceful-abort fix for it on mem2axi_bridge.v's AXI4 master -- a
 * watchdog-triggered reset landing while an AW/W/B or AR/R transaction is
 * outstanding on the *shared* FIC_1 side, which does NOT reset with the
 * core watchdog on real hardware.
 *
 * fake_axi_ddr.v is reused unmodified as the slave model; here it is given
 * its own reset (ddr_rst) kept high (never reset) across the DUT's
 * watchdog_rst pulse, exactly mirroring "shared fabric survives a watchdog
 * event that only touches mpeg2video's own core/mem_clk domain". Its
 * CS_BVALID state (like RS_RVALID in fake_axi_ddr_ro.v) only clears BVALID
 * once BREADY arrives -- if mem2axi_bridge drops bready for good
 * mid-transaction, this model will sit there holding BVALID high forever,
 * exactly like the real DDR controller/FIC_1 would.
 *
 * Originally written with dut_rst itself as the mid-transaction trigger,
 * which DID reproduce the wedge in both scenarios below (see
 * docs/bringup/24_fase7a_fwft_fix_and_axi4_interconnect_wedge.md and the
 * 2026-08-26 hardware trace -- dbg_last_write_awaddr_issued reading back an
 * arithmetically-impossible 0 mid-stall, only explainable by mem2axi_
 * bridge's rst firing again with no forward progress since). Now drives
 * the DUT's new dedicated watchdog_rst pulse instead (dut_rst stays high
 * throughout, matching the corrected wiring in
 * mpeg2fpga_apb_peripheral.v), to confirm the graceful-abort path added to
 * mem2axi_bridge.v actually drains the outstanding transaction instead of
 * abandoning it.
 *
 * No dbg_state port exists on mem2axi_bridge.v (unlike stream_dma.v) --
 * this testbench peeks dut.state directly via hierarchical reference
 * instead of adding one, since it's simulation-only observability.
 *
 * Run: iverilog -g2005 -D__IVERILOG__ -o testbench_wedge.vvp -I../../rtl/mpeg2 \
 *        testbench_wedge.v fake_axi_ddr.v ../../rtl/mpeg2/mem2axi_bridge.v
 *      vvp testbench_wedge.vvp
 */

`include "timescale.v"

`define CLK_PERIOD 10.0

module testbench_wedge ();

  reg         clk;
  reg         dut_rst;         /* mem2axi_bridge's raw hard reset -- stays high once released */
  reg         dut_watchdog_rst; /* mem2axi_bridge's new watchdog-only pulse input, active low */
  reg         ddr_rst;         /* fake_axi_ddr's reset -- stays high: shared fabric survives */

  reg  [1:0]  mem_req_rd_cmd;
  reg  [21:0] mem_req_rd_addr;
  reg  [63:0] mem_req_rd_dta;
  wire        mem_req_rd_en;
  reg         mem_req_rd_valid;
  wire [63:0] mem_res_wr_dta;
  wire        mem_res_wr_en;
  reg         mem_res_wr_almost_full;

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

  localparam [2:0]
    S_IDLE = 3'd0, S_LATCH = 3'd1, S_WRITE = 3'd2, S_BRESP = 3'd3,
    S_ARADDR = 3'd4, S_RDATA = 3'd5, S_RESP = 3'd6;

  mem2axi_bridge #(.DDR_BASE(38'h02000000)) dut (
      .clk(clk), .rst(dut_rst), .watchdog_rst(dut_watchdog_rst),
      .mem_req_rd_cmd(mem_req_rd_cmd), .mem_req_rd_addr(mem_req_rd_addr),
      .mem_req_rd_dta(mem_req_rd_dta), .mem_req_rd_en(mem_req_rd_en), .mem_req_rd_valid(mem_req_rd_valid),
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
      .clk(clk), .rst(ddr_rst),
      .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
      .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
      .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
      .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
      .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
      .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
      .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
      .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
  );

  initial begin
    clk = 1'b0;
    forever #(`CLK_PERIOD / 2) clk = ~clk;
  end

  initial begin
    $dumpfile("testbench_wedge.vcd");
    $dumpvars(0, testbench_wedge);
  end

  /* Watchdog: a stuck handshake would otherwise hang the simulator forever
   * instead of failing loudly. */
  initial begin
    #2000000;
    $display("TIMEOUT: simulation did not finish in time (stuck handshake?)");
    $finish;
  end

  /* ---- mem_req_rd BFM: mimics fifo_dc's read port, same as testbench.v ---- */
  reg  [1:0]  q_cmd;
  reg  [21:0] q_addr;
  reg  [63:0] q_dta;
  reg         q_pending;

  always @(posedge clk)
    if (~dut_rst) begin
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
      @(posedge clk);
      #1;
      q_cmd     = cmd;
      q_addr    = addr;
      q_dta     = dta;
      q_pending = 1'b1;
      wait (mem_req_rd_valid === 1'b1);
      @(posedge clk);
      #1;
    end
  endtask

  /* like push_req, but does not wait for the dut to actually pop it --
   * used right before a mid-transaction reset, when the dut may already be
   * too busy (state != S_IDLE) to service mem_req_rd_en at all. */
  task queue_req;
    input [1:0]  cmd;
    input [21:0] addr;
    input [63:0] dta;
    begin
      @(posedge clk);
      #1;
      q_cmd     = cmd;
      q_addr    = addr;
      q_dta     = dta;
      q_pending = 1'b1;
    end
  endtask

  task wait_res;
    output [63:0] dta;
    integer       timeout;
    integer       ok;
    begin
      timeout = 0;
      ok = 1;
      while (!(mem_res_wr_en === 1'b1)) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 100000) begin
          ok = 0;
          dta = 64'hxxxx_xxxx_xxxx_xxxx;
          disable wait_res;
        end
      end
      dta = mem_res_wr_dta;
      @(posedge clk);
    end
  endtask

  reg [63:0] rdata;
  integer    i;
  integer    result_A_wedged;
  integer    result_B_wedged;
  integer    result_C_wedged;
  integer    result_D_wedged;

  initial begin
    dut_rst = 1'b0;
    dut_watchdog_rst = 1'b1;
    ddr_rst = 1'b0;
    mem_req_rd_cmd = 2'b00;
    mem_req_rd_addr = 22'b0;
    mem_req_rd_dta = 64'b0;
    mem_req_rd_valid = 1'b0;
    mem_res_wr_almost_full = 1'b0;

    #(`CLK_PERIOD * 4);
    dut_rst = 1'b1;
    ddr_rst = 1'b1;   /* both come up together, like power-on */

    repeat (5) @(posedge clk);

    /* ---- scenario A: watchdog_rst pulse while S_WRITE (AW issued,
     * AWREADY/WREADY not seen yet -- fake_axi_ddr's AW_LATENCY=2/W_LATENCY=3
     * guarantees a window where mem2axi_bridge is waiting) ---- */
    queue_req(2'b11 /* CMD_WRITE */, 22'h000010, 64'hdead_beef_0000_0001);

    i = 0;
    while (dut.state != S_WRITE && i < 1000) begin
      @(posedge clk);
      i = i + 1;
    end
    $display("[%0t] scenario A: caught in state=%0d (S_WRITE=%0d) after %0d cycles, awvalid=%b awready=%b wvalid=%b wready=%b",
              $time, dut.state, S_WRITE, i, m_axi_awvalid, m_axi_awready, m_axi_wvalid, m_axi_wready);

    dut_watchdog_rst = 1'b0;
    @(posedge clk);
    dut_watchdog_rst = 1'b1;

    $display("[%0t] scenario A: post-pulse state=%0d", $time, dut.state);

    /* try a brand-new request; if the AXI4 write channel got wedged, this
     * will time out inside wait_res */
    push_req(2'b11, 22'h000030, 64'hcafe_babe_0000_0002);
    push_req(2'b10 /* CMD_READ */, 22'h000030, 64'b0);
    wait_res(rdata);
    result_A_wedged = (rdata !== 64'hcafe_babe_0000_0002);
    if (!result_A_wedged)
      $display("[%0t] RESULT (scenario A, mid S_WRITE): PASS -- recovered, read back 0x%016h.", $time, rdata);
    else
      $display("[%0t] RESULT (scenario A, mid S_WRITE): FAIL -- WEDGED (got 0x%016h, state=%0d awvalid=%b awready=%b wvalid=%b wready=%b bvalid=%b bready=%b).",
                $time, rdata, dut.state, m_axi_awvalid, m_axi_awready, m_axi_wvalid, m_axi_wready, m_axi_bvalid, m_axi_bready);

    /* ---- scenario B: watchdog_rst pulse while S_BRESP (AW+W already
     * accepted by the slave, waiting on BVALID -- the same "response
     * channel abandoned" shape as stream_dma's S_RDATA case) ---- */
    repeat (10) @(posedge clk);
    queue_req(2'b11, 22'h000040, 64'h1111_2222_3333_4444);

    i = 0;
    while (dut.state != S_BRESP && i < 1000) begin
      @(posedge clk);
      i = i + 1;
    end
    $display("[%0t] scenario B: caught in state=%0d (S_BRESP=%0d) after %0d cycles, bvalid=%b bready=%b",
              $time, dut.state, S_BRESP, i, m_axi_bvalid, m_axi_bready);

    dut_watchdog_rst = 1'b0;
    @(posedge clk);
    dut_watchdog_rst = 1'b1;

    $display("[%0t] scenario B: post-pulse state=%0d", $time, dut.state);

    push_req(2'b11, 22'h000050, 64'h5555_6666_7777_8888);
    push_req(2'b10, 22'h000050, 64'b0);
    wait_res(rdata);
    result_B_wedged = (rdata !== 64'h5555_6666_7777_8888);
    if (!result_B_wedged)
      $display("[%0t] RESULT (scenario B, mid S_BRESP): PASS -- recovered, read back 0x%016h.", $time, rdata);
    else
      $display("[%0t] RESULT (scenario B, mid S_BRESP): FAIL -- WEDGED (got 0x%016h, state=%0d awvalid=%b awready=%b wvalid=%b wready=%b bvalid=%b bready=%b).",
                $time, rdata, dut.state, m_axi_awvalid, m_axi_awready, m_axi_wvalid, m_axi_wready, m_axi_bvalid, m_axi_bready);

    /* ---- scenario C: watchdog_rst pulse while S_ARADDR (AR issued,
     * ARREADY not seen yet -- this bridge's read path, same shape as
     * stream_dma's S_AR scenario) ---- */
    repeat (10) @(posedge clk);
    queue_req(2'b10 /* CMD_READ */, 22'h000010, 64'b0);

    i = 0;
    while (dut.state != S_ARADDR && i < 1000) begin
      @(posedge clk);
      i = i + 1;
    end
    $display("[%0t] scenario C: caught in state=%0d (S_ARADDR=%0d) after %0d cycles, arvalid=%b arready=%b",
              $time, dut.state, S_ARADDR, i, m_axi_arvalid, m_axi_arready);

    dut_watchdog_rst = 1'b0;
    @(posedge clk);
    dut_watchdog_rst = 1'b1;

    $display("[%0t] scenario C: post-pulse state=%0d", $time, dut.state);

    push_req(2'b11, 22'h000060, 64'hbeef_1234_5678_9abc);
    push_req(2'b10, 22'h000060, 64'b0);
    wait_res(rdata);
    result_C_wedged = (rdata !== 64'hbeef_1234_5678_9abc);
    if (!result_C_wedged)
      $display("[%0t] RESULT (scenario C, mid S_ARADDR): PASS -- recovered, read back 0x%016h.", $time, rdata);
    else
      $display("[%0t] RESULT (scenario C, mid S_ARADDR): FAIL -- WEDGED (got 0x%016h, state=%0d arvalid=%b arready=%b rvalid=%b rready=%b).",
                $time, rdata, dut.state, m_axi_arvalid, m_axi_arready, m_axi_rvalid, m_axi_rready);

    /* ---- scenario D: watchdog_rst pulse while S_RDATA (AR accepted,
     * waiting on RVALID) ---- */
    repeat (10) @(posedge clk);
    queue_req(2'b10, 22'h000070, 64'b0);

    i = 0;
    while (dut.state != S_RDATA && i < 1000) begin
      @(posedge clk);
      i = i + 1;
    end
    $display("[%0t] scenario D: caught in state=%0d (S_RDATA=%0d) after %0d cycles, rvalid=%b rready=%b",
              $time, dut.state, S_RDATA, i, m_axi_rvalid, m_axi_rready);

    dut_watchdog_rst = 1'b0;
    @(posedge clk);
    dut_watchdog_rst = 1'b1;

    $display("[%0t] scenario D: post-pulse state=%0d", $time, dut.state);

    push_req(2'b11, 22'h000080, 64'hcccc_dddd_eeee_ffff);
    push_req(2'b10, 22'h000080, 64'b0);
    wait_res(rdata);
    result_D_wedged = (rdata !== 64'hcccc_dddd_eeee_ffff);
    if (!result_D_wedged)
      $display("[%0t] RESULT (scenario D, mid S_RDATA): PASS -- recovered, read back 0x%016h.", $time, rdata);
    else
      $display("[%0t] RESULT (scenario D, mid S_RDATA): FAIL -- WEDGED (got 0x%016h, state=%0d arvalid=%b arready=%b rvalid=%b rready=%b).",
                $time, rdata, dut.state, m_axi_arvalid, m_axi_arready, m_axi_rvalid, m_axi_rready);

    if (result_A_wedged || result_B_wedged || result_C_wedged || result_D_wedged)
      $display("SUMMARY: mem2axi_bridge still WEDGES on a watchdog_rst pulse mid-transaction -- fix incomplete.");
    else
      $display("SUMMARY: graceful-abort fix confirmed -- all four mid-transaction scenarios recovered.");

    $finish;
  end

endmodule
/* not truncated */
