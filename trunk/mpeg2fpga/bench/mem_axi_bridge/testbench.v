/*
 * testbench.v - mem2axi_bridge unit test
 *
 * Exercises mem2axi_bridge in isolation (fake_axi_ddr.v standing in for the
 * real FIC_0/DDR4 path) over a mem_req_rd/mem_res_wr BFM -- the same
 * interface mpeg2video's framestore.v drives. Does not instantiate
 * mpeg2video or Libero -- see Fase 6a in the plan (docs/bringup, once
 * written up).
 *
 * Run: make (see Makefile). Prints one line per check and a final
 * "ALL TESTS PASSED" / "N TEST(S) FAILED" summary.
 */

`include "timescale.v"

`define CLK_PERIOD 10.0

module testbench ();

  reg         clk;
  reg         rst;

  reg  [1:0]  mem_req_rd_cmd;
  reg  [21:0] mem_req_rd_addr;
  reg  [63:0] mem_req_rd_dta;
  wire        mem_req_rd_en;
  reg         mem_req_rd_valid;   /* driven by the BFM task, mimicking the fifo_dc read port */
  wire [63:0] mem_res_wr_dta;
  wire        mem_res_wr_en;
  reg         mem_res_wr_almost_full;

  wire  [7:0] m_axi_awid;
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

  wire  [7:0] m_axi_bid;
  wire  [1:0] m_axi_bresp;
  wire        m_axi_bvalid;
  wire        m_axi_bready;

  wire  [7:0] m_axi_arid;
  wire [37:0] m_axi_araddr;
  wire  [7:0] m_axi_arlen;
  wire  [2:0] m_axi_arsize;
  wire  [1:0] m_axi_arburst;
  wire        m_axi_arvalid;
  wire        m_axi_arready;

  wire  [7:0] m_axi_rid;
  wire [63:0] m_axi_rdata;
  wire  [1:0] m_axi_rresp;
  wire        m_axi_rlast;
  wire        m_axi_rvalid;
  wire        m_axi_rready;

  integer     errors;
  integer     checks;

  mem2axi_bridge #(.DDR_BASE(38'h02000000)) dut (
      .clk(clk), .rst(rst),
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
      .clk(clk), .rst(rst),
      .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
      .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
      .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
      .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
      .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
      .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
      .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
      .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
  );

  /* clock */
  initial begin
    clk = 1'b0;
    forever #(`CLK_PERIOD / 2) clk = ~clk;
  end

  /* reset */
  initial begin
    rst = 1'b0;
    #(`CLK_PERIOD * 4);
    rst = 1'b1;
  end

  /* Watchdog: a stuck handshake (fifo semantics bug, AXI channel deadlock)
   * would otherwise hang the simulator forever instead of failing loudly.
   */
  initial begin
    #200000;
    $display("TIMEOUT: simulation did not finish in time (stuck handshake?)");
    $finish;
  end

  initial begin
    mem_req_rd_cmd = 2'b00;
    mem_req_rd_addr = 22'b0;
    mem_req_rd_dta = 64'b0;
    mem_req_rd_valid = 1'b0;
    mem_res_wr_almost_full = 1'b0;
  end

  /*
   * mem_req_rd BFM: mimics fifo_dc's read port (see xfifo_dc.v) -- rd_en
   * asserted one cycle, dout/valid presented the cycle after. Pushes a
   * single {cmd,addr,dta} request once the dut asserts mem_req_rd_en, then
   * drops valid until the next request is queued.
   */
  reg  [1:0]  q_cmd;
  reg  [21:0] q_addr;
  reg  [63:0] q_dta;
  reg         q_pending;

  always @(posedge clk)
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
      @(posedge clk);
      #1;   /* avoid a race against the BFM's own posedge-clk always block, see apb_bridge/testbench.v */
      q_cmd     = cmd;
      q_addr    = addr;
      q_dta     = dta;
      q_pending = 1'b1;
      wait (mem_req_rd_valid === 1'b1);
      @(posedge clk);
      #1;
    end
  endtask

  /* wait for a mem_res_wr push and capture the data */
  task wait_res;
    output [63:0] dta;
    integer       timeout;
    begin
      timeout = 0;
      while (!(mem_res_wr_en === 1'b1)) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 1000) begin
          $display("FAIL wait_res: timed out waiting for mem_res_wr_en");
          $finish;
        end
      end
      dta = mem_res_wr_dta;
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
  initial $monitor("t=%0t state=%0d ar_state=%b ar_cnt=%0d r_state=%0d r_cnt=%0d arvalid=%b arready=%b rvalid=%b",
    $time, dut.state, slave.ar_state, slave.ar_cnt, slave.r_state, slave.r_cnt,
    m_axi_arvalid, m_axi_arready, m_axi_rvalid);
`endif

  initial begin
    errors = 0;
    checks = 0;
    rdata  = 64'b0;

    wait (rst === 1'b1);
    repeat (5) @(posedge clk);

    /* single write then read-back */
    push_req(2'b11 /* CMD_WRITE */, 22'h000010, 64'hdead_beef_0000_0001);
    push_req(2'b10 /* CMD_READ */,  22'h000010, 64'b0);
    wait_res(rdata);
    check_eq64("write then read back, addr 0x10", rdata, 64'hdead_beef_0000_0001);

    /* a second, different address -- catches an address-latching bug that
     * happened to work for a single request */
    push_req(2'b11, 22'h000123, 64'h1111_2222_3333_4444);
    push_req(2'b10, 22'h000123, 64'b0);
    wait_res(rdata);
    check_eq64("write then read back, addr 0x123", rdata, 64'h1111_2222_3333_4444);

    /* original address must be unaffected by the second write */
    push_req(2'b10, 22'h000010, 64'b0);
    wait_res(rdata);
    check_eq64("addr 0x10 unaffected by write", rdata, 64'hdead_beef_0000_0001);

    /* back-to-back reads, no idle requests in between: stresses the
     * fully-serialized request/response pipeline for dropped or duplicated
     * transactions. */
    push_req(2'b11, 22'h000200, 64'haaaa_aaaa_aaaa_aaaa);
    push_req(2'b11, 22'h000201, 64'hbbbb_bbbb_bbbb_bbbb);
    push_req(2'b10, 22'h000200, 64'b0);
    wait_res(rdata);
    check_eq64("back-to-back: read 0x200", rdata, 64'haaaa_aaaa_aaaa_aaaa);
    push_req(2'b10, 22'h000201, 64'b0);
    wait_res(rdata);
    check_eq64("back-to-back: read 0x201", rdata, 64'hbbbb_bbbb_bbbb_bbbb);

    /* mem_res_wr_almost_full backpressure: bridge must hold the already-
     * fetched read result and only push once the response fifo has room,
     * without dropping or corrupting it. */
    mem_res_wr_almost_full = 1'b1;
    push_req(2'b10, 22'h000200, 64'b0);
    repeat (20) @(posedge clk);
    if (mem_res_wr_en === 1'b1) begin
      errors = errors + 1;
      $display("FAIL backpressure: mem_res_wr_en asserted while mem_res_wr_almost_full");
    end else begin
      checks = checks + 1;
      $display("PASS backpressure: held off while mem_res_wr_almost_full");
    end
    mem_res_wr_almost_full = 1'b0;
    wait_res(rdata);
    check_eq64("backpressure: delivered later", rdata, 64'haaaa_aaaa_aaaa_aaaa);

    /* CMD_NOOP must not produce any AXI transaction or mem_res_wr push */
    push_req(2'b00 /* CMD_NOOP */, 22'h0003ff, 64'b0);
    repeat (10) @(posedge clk);
    checks = checks + 1;
    if ((m_axi_awvalid === 1'b1) || (m_axi_arvalid === 1'b1) || (mem_res_wr_en === 1'b1)) begin
      errors = errors + 1;
      $display("FAIL CMD_NOOP triggered an AXI transaction or a response push");
    end else begin
      $display("PASS CMD_NOOP: no AXI transaction, no response");
    end

    /* decoder must still respond normally to a request right after a NOOP */
    push_req(2'b10, 22'h000201, 64'b0);
    wait_res(rdata);
    check_eq64("read after CMD_NOOP works", rdata, 64'hbbbb_bbbb_bbbb_bbbb);

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $display("%0d TEST(S) FAILED out of %0d checks", errors, checks);

    $finish;
  end

endmodule
/* not truncated */
