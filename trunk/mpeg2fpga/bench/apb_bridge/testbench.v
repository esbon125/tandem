/*
 * testbench.v - apb3_mpeg2fpga_bridge unit test
 *
 * Exercises the bridge in isolation (fake_regfile.v standing in for
 * mpeg2video's real regfile.v) over an APB3 master BFM. PCLK and core_clk
 * deliberately run at an unrelated, non-integer ratio to stress the
 * toggle-handshake clock-domain crossing -- a bug that only shows up at a
 * "convenient" clock ratio would be a false negative here.
 *
 * Run: make (see Makefile). Prints one line per check and a final
 * "ALL TESTS PASSED" / "N TEST(S) FAILED" summary.
 */

`include "timescale.v"

/* PCLK at 50 MHz (typical fabric/APB clock) */
`define PCLK_PERIOD 20.0

/* core_clk at 108 MHz, matching the project's existing clk convention
 * (bench/iverilog/testbench.v `CLK_PERIOD, PF_CCC_C0 OUT1_FABCLK_0) --
 * deliberately not an integer multiple of PCLK_PERIOD.
 */
`define CORE_CLK_PERIOD 9.259

module testbench ();

  reg         PCLK;
  reg         PRESETn;
  reg         PSEL;
  reg         PENABLE;
  reg         PWRITE;
  reg  [5:0]  PADDR;
  reg  [31:0] PWDATA;
  wire [31:0] PRDATA;
  wire        PREADY;

  reg         core_clk;
  reg         core_rst_n;
  wire  [3:0] reg_addr;
  wire        reg_wr_en;
  wire [31:0] reg_dta_in;
  wire        reg_rd_en;
  wire [31:0] reg_dta_out;

  integer     errors;
  integer     checks;

  apb3_mpeg2fpga_bridge dut (
      .PCLK(PCLK), .PRESETn(PRESETn),
      .PSEL(PSEL), .PENABLE(PENABLE), .PWRITE(PWRITE),
      .PADDR(PADDR), .PWDATA(PWDATA), .PRDATA(PRDATA), .PREADY(PREADY),
      .core_clk(core_clk), .core_rst_n(core_rst_n),
      .reg_addr(reg_addr), .reg_wr_en(reg_wr_en), .reg_dta_in(reg_dta_in),
      .reg_rd_en(reg_rd_en), .reg_dta_out(reg_dta_out)
  );

  fake_regfile fake (
      .core_clk(core_clk), .core_rst_n(core_rst_n),
      .reg_addr(reg_addr), .reg_wr_en(reg_wr_en), .reg_dta_in(reg_dta_in),
      .reg_rd_en(reg_rd_en), .reg_dta_out(reg_dta_out)
  );

  /* clocks */
  initial begin
    PCLK = 1'b0;
    forever #(`PCLK_PERIOD / 2) PCLK = ~PCLK;
  end

  initial begin
    core_clk = 1'b0;
    forever #(`CORE_CLK_PERIOD / 2) core_clk = ~core_clk;
  end

  /* resets: hold both domains in reset for a few of their own cycles */
  initial begin
    PRESETn    = 1'b0;
    core_rst_n = 1'b0;
    #(`PCLK_PERIOD * 4);
    PRESETn    = 1'b1;
    #(`CORE_CLK_PERIOD * 4);
    core_rst_n = 1'b1;
  end

  /* Watchdog: a stuck handshake (e.g. a CDC bug) would otherwise hang the
   * simulator forever instead of failing loudly.
   */
  initial begin
    #100000;
    $display("TIMEOUT: simulation did not finish in time (stuck handshake?)");
    $finish;
  end

  initial begin
    PSEL    = 1'b0;
    PENABLE = 1'b0;
    PWRITE  = 1'b0;
    PADDR   = 6'b0;
    PWDATA  = 32'b0;
  end

  /* APB3 master BFM: one full write or read transfer, polling PREADY.
   * The #1 after every @(posedge PCLK) avoids a race against the DUT's own
   * posedge-PCLK always block -- without it, the DUT and this task could
   * sample/drive PSEL/PENABLE in the same delta cycle in either order,
   * depending on simulator scheduling.
   */
  task apb_transfer;
    input         write;
    input  [3:0]  addr;
    input  [31:0] wdata;
    output [31:0] rdata;
    begin
      @(posedge PCLK);
      #1;
      PSEL    = 1'b1;
      PENABLE = 1'b0;
      PWRITE  = write;
      PADDR   = {addr, 2'b00};
      PWDATA  = wdata;
      @(posedge PCLK);
      #1;
      PENABLE = 1'b1;
      @(posedge PCLK);
      #1;
      while (PREADY !== 1'b1) begin
        @(posedge PCLK);
        #1;
      end
      rdata   = PRDATA;
      PSEL    = 1'b0;
      PENABLE = 1'b0;
    end
  endtask

  task check_eq;
    input [255:0] name;   /* plain string, no $sformat needed for this Icarus version */
    input [31:0]  got;
    input [31:0]  expected;
    begin
      checks = checks + 1;
      if (got !== expected) begin
        errors = errors + 1;
        $display("FAIL %0s: got 0x%08h, expected 0x%08h", name, got, expected);
      end else begin
        $display("PASS %0s: 0x%08h", name, got);
      end
    end
  endtask

  reg [31:0] rdata;

`ifdef DEBUG_TRACE
  initial $monitor("t=%0t PSEL=%b PENABLE=%b PREADY=%b apb_state=%b req_toggle=%b ack_toggle_sync=%b core_state=%b req_toggle_sync=%b req_toggle_seen=%b reg_wr_en=%b reg_rd_en=%b",
    $time, PSEL, PENABLE, PREADY, dut.apb_state, dut.req_toggle, dut.ack_toggle_sync,
    dut.core_state, dut.req_toggle_sync, dut.req_toggle_seen, reg_wr_en, reg_rd_en);
`endif

  initial begin
    errors = 0;
    checks = 0;
    rdata  = 32'b0;

    /* level wait, not two chained edge waits: PRESETn and core_rst_n
     * release at different times (see the reset initial block above), so
     * waiting for one edge and then the other -- in a fixed order -- would
     * block forever if the one waited for second already went high first.
     */
    wait (PRESETn === 1'b1 && core_rst_n === 1'b1);
    repeat (5) @(posedge PCLK);

    /* Writes land in the write-mode bank (fake.write_mem), independent of
     * whatever is preloaded in the read-mode bank (fake.read_mem).
     */
    apb_transfer(1'b1, 4'h0, 32'h0000_7f04, rdata); /* watchdog_interval=0x7f, all *_intr_en set, like mpeg2fpga_core's default */
    apb_transfer(1'b1, 4'h5, 32'hdead_beef, rdata);
    apb_transfer(1'b1, 4'hb, 32'h1234_5678, rdata);

    check_eq("write_mem[0]", fake.write_mem[0], 32'h0000_7f04);
    check_eq("write_mem[5]", fake.write_mem[5], 32'hdead_beef);
    check_eq("write_mem[11]", fake.write_mem[11], 32'h1234_5678);
    check_eq("write_mem[1] untouched", fake.write_mem[1], 32'h0000_0000);

    /* Reads come from the independent read-mode bank */
    fake.read_mem[0] = 32'h0000_0001;         /* version */
    fake.read_mem[1] = 32'h0000_0008;         /* status: picture_hdr bit */
    fake.read_mem[15] = 32'hcafe_babe;        /* testpoint */

    apb_transfer(1'b0, 4'h0, 32'b0, rdata);
    check_eq("read reg 0 (version)", rdata, 32'h0000_0001);

    apb_transfer(1'b0, 4'h1, 32'b0, rdata);
    check_eq("read reg 1 (status)", rdata, 32'h0000_0008);

    apb_transfer(1'b0, 4'hf, 32'b0, rdata);
    check_eq("read reg 15 (testpoint)", rdata, 32'hcafe_babe);

    /* Back-to-back transactions, no idle cycles between them: stresses the
     * toggle handshake to confirm it neither drops nor duplicates a
     * transaction when a new one starts as soon as the previous PREADY
     * fires.
     */
    fake.read_mem[2] = 32'h1111_1111;
    fake.read_mem[3] = 32'h2222_2222;
    apb_transfer(1'b1, 4'h2, 32'haaaa_aaaa, rdata);
    apb_transfer(1'b0, 4'h2, 32'b0, rdata);
    check_eq("back-to-back: read after write, reg 2", rdata, 32'h1111_1111);
    check_eq("back-to-back: write_mem[2] unaffected by read", fake.write_mem[2], 32'haaaa_aaaa);
    apb_transfer(1'b0, 4'h3, 32'b0, rdata);
    check_eq("back-to-back: read reg 3", rdata, 32'h2222_2222);

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $display("%0d TEST(S) FAILED out of %0d checks", errors, checks);

    $finish;
  end

endmodule
/* not truncated */
