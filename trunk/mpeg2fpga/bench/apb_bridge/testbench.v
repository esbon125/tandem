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
  reg  [6:0]  PADDR;
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

  reg         busy;
  wire  [7:0] stream_data;
  wire        stream_valid;

  wire        dma_start;
  wire [31:0] dma_addr;
  wire [31:0] dma_len;
  reg         dma_busy;
  reg         dma_done;
  reg  [31:0] dma_bytes_done;

  integer     errors;
  integer     checks;

  apb3_mpeg2fpga_bridge dut (
      .PCLK(PCLK), .PRESETn(PRESETn),
      .PSEL(PSEL), .PENABLE(PENABLE), .PWRITE(PWRITE),
      .PADDR(PADDR), .PWDATA(PWDATA), .PRDATA(PRDATA), .PREADY(PREADY),
      .core_clk(core_clk), .core_rst_n(core_rst_n),
      .reg_addr(reg_addr), .reg_wr_en(reg_wr_en), .reg_dta_in(reg_dta_in),
      .reg_rd_en(reg_rd_en), .reg_dta_out(reg_dta_out),
      .busy(busy), .stream_data(stream_data), .stream_valid(stream_valid),
      .dma_start(dma_start), .dma_addr(dma_addr), .dma_len(dma_len),
      .dma_busy(dma_busy), .dma_done(dma_done), .dma_bytes_done(dma_bytes_done)
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
    PADDR   = 7'b0;
    PWDATA  = 32'b0;
    busy    = 1'b0;
    dma_busy = 1'b0;
    dma_done = 1'b0;
    dma_bytes_done = 32'b0;
  end

  /* APB3 master BFM: one full write or read transfer, polling PREADY.
   * The #1 after every @(posedge PCLK) avoids a race against the DUT's own
   * posedge-PCLK always block -- without it, the DUT and this task could
   * sample/drive PSEL/PENABLE in the same delta cycle in either order,
   * depending on simulator scheduling.
   */
  task apb_transfer;
    input         write;
    input  [4:0]  addr;
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

  /* captures every stream_data byte the DUT pushes (stream_valid pulses
   * for exactly one core_clk cycle, gone well before apb_transfer's task
   * call returns) so the test can check it afterward. */
  reg [7:0] captured_stream [0:15];
  integer   captured_count;

  always @(posedge core_clk)
    if (stream_valid) begin
      captured_stream[captured_count] = stream_data;
      captured_count = captured_count + 1;
    end

  /* counts dma_start pulses, to check DMA_CTRL writes do/don't trigger one */
  integer dma_start_count;

  always @(posedge core_clk)
    if (dma_start) dma_start_count = dma_start_count + 1;

`ifdef DEBUG_TRACE
  initial $monitor("t=%0t PSEL=%b PENABLE=%b PREADY=%b apb_state=%b req_toggle=%b ack_toggle_sync=%b core_state=%b req_toggle_sync=%b req_toggle_seen=%b reg_wr_en=%b reg_rd_en=%b",
    $time, PSEL, PENABLE, PREADY, dut.apb_state, dut.req_toggle, dut.ack_toggle_sync,
    dut.core_state, dut.req_toggle_sync, dut.req_toggle_seen, reg_wr_en, reg_rd_en);
`endif

  initial begin
    errors = 0;
    checks = 0;
    rdata  = 32'b0;
    captured_count = 0;

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

    /* STREAM_PUSH_ADDR (index 5'h10, Fase 7a): a write pulses stream_valid/
     * stream_data instead of touching the regfile at all -- fake_regfile's
     * write_mem[0] (reg_addr reads as 0 during a stream push, see the
     * "assign reg_addr = apb_addr_r[3:0]" comment in the DUT) must stay
     * untouched, since reg_wr_en is never asserted for this address.
     */
    apb_transfer(1'b1, 5'h10, 32'h0000_00ab, rdata);
    check_eq("stream push: captured byte", {24'b0, captured_stream[captured_count-1]}, 32'h0000_00ab);
    /* write_mem[0] was set to 0x7f04 by the very first transfer in this test
     * (watchdog_interval config write, top of this block) -- a stream push
     * decodes to reg_addr==0 too (apb_addr_r[3:0] of STREAM_PUSH_ADDR is
     * 0), so this checks reg_wr_en really never fires for it, not that the
     * register happens to read back as zero. */
    check_eq("stream push: regfile untouched", fake.write_mem[0], 32'h0000_7f04);

    /* busy backpressure: the transaction must not complete (PREADY stays
     * low) until mpeg2video's busy output deasserts -- APB's own wait-state
     * mechanism is the flow control here, no separate polling register.
     */
    busy = 1'b1;
    fork
      apb_transfer(1'b1, 5'h10, 32'h0000_00cd, rdata);
      begin
        repeat (30) @(posedge core_clk);
        checks = checks + 1;
        if (PREADY !== 1'b0) begin
          errors = errors + 1;
          $display("FAIL stream push: completed while busy was still asserted");
        end else begin
          $display("PASS stream push: held off while busy asserted");
        end
        busy = 1'b0;
      end
    join
    check_eq("stream push: delivered once busy clears", {24'b0, captured_stream[captured_count-1]}, 32'h0000_00cd);

    /* a register access right after a stream push must still work normally */
    apb_transfer(1'b0, 4'h0, 32'b0, rdata);
    check_eq("register read still works after stream push", rdata, 32'h0000_0001);

    /* DMA_ADDR/DMA_LEN (Fase 7c): plain holding-register writes, no CDC
     * pulse involved -- checked directly against the bridge's dma_addr/
     * dma_len outputs, which are just continuous assigns of the holding
     * registers.
     */
    apb_transfer(1'b1, 5'h11, 32'h0000_1000, rdata);
    apb_transfer(1'b1, 5'h12, 32'h0000_0080, rdata);
    check_eq("DMA_ADDR latched", dma_addr, 32'h0000_1000);
    check_eq("DMA_LEN latched", dma_len, 32'h0000_0080);

    /* Fase 7c debug: DMA_ADDR/DMA_LEN readback (added while investigating a
     * real-hardware bug where DMA_LEN's written value never reached
     * stream_dma.v -- lets software read back what the bridge actually
     * latched, to bisect a write-path bug from a stream_dma-side one). */
    apb_transfer(1'b0, 5'h11, 32'b0, rdata);
    check_eq("DMA_ADDR readback", rdata, 32'h0000_1000);
    apb_transfer(1'b0, 5'h12, 32'b0, rdata);
    check_eq("DMA_LEN readback", rdata, 32'h0000_0080);

    /* DMA_CTRL start bit: pulses dma_start for one core_clk cycle when the
     * DUT sees dma_busy low.
     */
    dma_start_count = 0;
    dma_busy = 1'b0;
    apb_transfer(1'b1, 5'h13, 32'h0000_0001, rdata);
    repeat (5) @(posedge core_clk);
    check_eq("DMA_CTRL start: dma_start pulsed once", dma_start_count, 32'd1);

    /* DMA_STATUS read while busy: bit0=1, bit1 (done) still 0 */
    dma_busy = 1'b1;
    dma_bytes_done = 32'd40;
    apb_transfer(1'b0, 5'h14, 32'b0, rdata);
    check_eq("DMA_STATUS while busy", rdata, {24'd40, 6'b0, 1'b0, 1'b1});   /* done=0, busy=1 */

    /* a DMA_CTRL start write while already busy must be ignored -- software
     * is expected to poll DMA_STATUS first, same contract as DMA_ADDR/
     * DMA_LEN must be written before DMA_CTRL.
     */
    dma_start_count = 0;
    apb_transfer(1'b1, 5'h13, 32'h0000_0001, rdata);
    repeat (5) @(posedge core_clk);
    check_eq("DMA_CTRL start ignored while busy", dma_start_count, 32'd0);

    /* dma_done pulse sets a sticky bit DMA_STATUS reports until the next
     * start clears it.
     */
    dma_busy = 1'b0;
    @(posedge core_clk);
    dma_done = 1'b1;
    @(posedge core_clk);
    dma_done = 1'b0;
    dma_bytes_done = 32'd112;
    apb_transfer(1'b0, 5'h14, 32'b0, rdata);
    check_eq("DMA_STATUS done sticky set", rdata, {24'd112, 6'b0, 1'b1, 1'b0});   /* done=1, busy=0 */

    apb_transfer(1'b1, 5'h13, 32'h0000_0001, rdata);   /* new start clears done_sticky */
    dma_busy = 1'b1;
    apb_transfer(1'b0, 5'h14, 32'b0, rdata);
    check_eq("DMA_STATUS done_sticky cleared by new start", rdata, {24'd112, 6'b0, 1'b0, 1'b1});   /* done=0, busy=1 */
    dma_busy = 1'b0;

    /* regfile/stream-push paths must still be unaffected by DMA register
     * traffic -- same non-interference guarantee already checked above for
     * stream push vs. regular registers.
     */
    apb_transfer(1'b0, 4'h0, 32'b0, rdata);
    check_eq("register read still works after DMA register traffic", rdata, 32'h0000_0001);

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $display("%0d TEST(S) FAILED out of %0d checks", errors, checks);

    $finish;
  end

endmodule
/* not truncated */
