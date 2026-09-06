/*
 * testbench_wedge.v - exercises the AXI4-interconnect wedge scenario and the
 * graceful-abort fix for it: a watchdog-triggered reset of stream_dma.v
 * while an AXI4 read burst is still outstanding on the *shared* FIC_2 side,
 * which -- unlike stream_dma.v's own core_clk logic -- does NOT reset with
 * the core watchdog on real hardware. fake_axi_ddr_ro.v is reused
 * unmodified as the slave model; here it is given its own reset (ddr_rst_n)
 * kept high (never reset) across the DUT's watchdog_rst pulse, exactly
 * mirroring "shared fabric survives a watchdog event that only touches
 * mpeg2video's own core_clk domain".
 *
 * Originally written with dut_rst_n itself as the mid-burst trigger, which
 * DID reproduce the wedge (see docs/bringup/24_fase7a_fwft_fix_and_axi4_
 * interconnect_wedge.md) -- confirming that routing mpeg2video's watchdog-
 * inclusive core_rst_out straight into stream_dma.v's rst_n (as that
 * session's first fix attempt did) does not solve it. Now drives the DUT's
 * new dedicated watchdog_rst pulse instead (rst_n stays high throughout,
 * matching the corrected wiring in mpeg2fpga_apb_peripheral.v), to confirm
 * the graceful-abort path added to stream_dma.v actually drains the
 * outstanding burst instead of abandoning it.
 *
 * Run: iverilog -g2005 -D__IVERILOG__ -o testbench_wedge.vvp -I../../rtl/mpeg2 \
 *        testbench_wedge.v fake_axi_ddr_ro.v ../../rtl/mpeg2/stream_dma.v
 *      vvp testbench_wedge.vvp
 */

`include "timescale.v"

`define CLK_PERIOD 10.0

module testbench_wedge ();

  reg         clk;
  reg         dut_rst_n;      /* stream_dma's raw hard reset -- stays high once released */
  reg         dut_watchdog_rst; /* stream_dma's new watchdog-only pulse input, active low */
  reg         ddr_rst_n;      /* fake_axi_ddr_ro's reset -- stays high: shared fabric survives */

  reg         start;
  reg  [31:0] addr;
  reg  [31:0] len;
  wire        busy;
  wire        done;
  wire [31:0] bytes_done;

  reg         mpeg_busy;
  wire  [7:0] stream_data;
  wire        stream_valid;

  wire  [3:0] m_axi_arid;
  wire [37:0] m_axi_araddr;
  wire  [7:0] m_axi_arlen;
  wire  [2:0] m_axi_arsize;
  wire  [1:0] m_axi_arburst;
  wire        m_axi_arlock;
  wire  [3:0] m_axi_arcache;
  wire  [2:0] m_axi_arprot;
  wire  [3:0] m_axi_arqos;
  wire  [3:0] m_axi_arregion;
  wire  [0:0] m_axi_aruser;
  wire        m_axi_arvalid;
  wire        m_axi_arready;

  wire  [3:0] m_axi_rid = 4'b0;
  wire [63:0] m_axi_rdata;
  wire  [1:0] m_axi_rresp;
  wire        m_axi_rlast;
  wire  [0:0] m_axi_ruser = 1'b0;
  wire        m_axi_rvalid;
  wire        m_axi_rready;

  wire  [2:0] dbg_state;

  stream_dma #(.STAGING_BASE(38'h0), .BURST_BEATS(5'd16)) dut (
      .clk(clk), .rst_n(dut_rst_n), .watchdog_rst(dut_watchdog_rst),
      .start(start), .addr(addr), .len(len),
      .busy(busy), .done(done), .bytes_done(bytes_done),
      .mpeg_busy(mpeg_busy),
      .stream_data(stream_data), .stream_valid(stream_valid),
      .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
      .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
      .m_axi_arlock(m_axi_arlock), .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot),
      .m_axi_arqos(m_axi_arqos), .m_axi_arregion(m_axi_arregion), .m_axi_aruser(m_axi_aruser),
      .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
      .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
      .m_axi_rlast(m_axi_rlast), .m_axi_ruser(m_axi_ruser), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
      .dbg_state(dbg_state)
  );

  fake_axi_ddr_ro ddr (
      .clk(clk), .rst(ddr_rst_n),
      .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
      .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
      .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
      .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
  );

  initial begin
    clk = 1'b0;
    forever #(`CLK_PERIOD / 2) clk = ~clk;
  end

  initial begin
    $dumpfile("testbench_wedge.vcd");
    $dumpvars(0, testbench_wedge);
  end

  task preload_ramp;
    input [19:0] base;
    input integer n;
    integer i;
    begin
      for (i = 0; i < n; i = i + 1)
        ddr.preload_byte(base + i[19:0], (i * 7 + 3) & 8'hFF);
    end
  endtask

  integer i;

  initial begin
    dut_rst_n        = 1'b0;
    dut_watchdog_rst = 1'b1;
    ddr_rst_n        = 1'b0;
    start            = 1'b0;
    addr             = 32'b0;
    len              = 32'b0;
    mpeg_busy        = 1'b0;

    #(`CLK_PERIOD * 4);
    dut_rst_n = 1'b1;
    ddr_rst_n = 1'b1;   /* both come up together, like power-on */

    preload_ramp(20'd0, 300);

    @(posedge clk);
    @(posedge clk);

    /* ---- start a 3-burst transfer (300 bytes), let the first burst get
     * partway through (a couple of beats accepted, m_axi_rvalid having
     * pulsed at least once), then pulse dut_watchdog_rst only -- mirroring
     * the watchdog firing mid-DMA while FIC_2/the DDR controller (and
     * stream_dma's own rst_n) keep running, exactly as mpeg2video's
     * watchdog.v behaves on real hardware. */
    addr  = 32'd0;
    len   = 32'd300;
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;

    /* wait until we've entered S_RDATA at least twice (i.e. the burst is
     * genuinely in flight, not just sitting in S_AR) */
    i = 0;
    while (i < 2) begin
      @(posedge clk);
      if (dbg_state == 3'd2) begin   /* S_RDATA entered */
        i = i + 1;
        @(negedge clk);   /* let state settle past the edge before sampling again */
      end
    end

    $display("[%0t] mid-burst watchdog pulse: dbg_state=%0d busy=%b m_axi_rvalid=%b m_axi_rready=%b beats seen=%0d",
              $time, dbg_state, busy, m_axi_rvalid, m_axi_rready, i);

    /* the real watchdog_rst signal: a single-cycle active-low pulse,
     * rst_n never moves */
    dut_watchdog_rst = 1'b0;
    @(posedge clk);
    dut_watchdog_rst = 1'b1;

    $display("[%0t] post-pulse: dbg_state=%0d busy=%b m_axi_rvalid=%b m_axi_rready=%b",
              $time, dbg_state, busy, m_axi_rvalid, m_axi_rready);

    /* wait for the abort-drain to actually finish (busy back to 0) rather
     * than guessing a fixed cycle count -- it was caught 2 beats into a
     * 16-beat burst, so up to 14 more beats' worth of AR_LATENCY+R_LATENCY
     * must still play out through the (unreset) ddr model. */
    i = 0;
    while (busy && i < 2000) begin
      @(posedge clk);
      i = i + 1;
    end

    $display("[%0t] settled after %0d cycles: dbg_state=%0d busy=%b m_axi_rvalid=%b m_axi_rready=%b ddr.ar_state=%0d ddr.r_state=%0d",
              $time, i, dbg_state, busy, m_axi_rvalid, m_axi_rready, ddr.ar_state, ddr.r_state);

    /* ---- now try a brand-new transfer, as software would after seeing
     * the watchdog recover and re-issuing the DMA push ---- */
    preload_ramp(20'd5000, 64);
    addr  = 32'd5000;
    len   = 32'd64;
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;

    i = 0;
    while (!done && i < 2000) begin
      @(posedge clk);
      i = i + 1;
    end

    if (done)
      $display("[%0t] RESULT (mid-burst): PASS -- second transfer completed after %0d cycles, bytes_done=%0d (expected 96). Graceful-abort fix confirmed.", $time, i, bytes_done);
    else
      $display("[%0t] RESULT (mid-burst): FAIL -- WEDGED. second transfer never completed (dbg_state=%0d m_axi_arvalid=%b m_axi_arready=%b m_axi_rvalid=%b m_axi_rready=%b ddr.ar_state=%0d ddr.r_state=%0d).",
                $time, dbg_state, m_axi_arvalid, m_axi_arready, m_axi_rvalid, m_axi_rready, ddr.ar_state, ddr.r_state);

    /* ---- second scenario: watchdog_rst while ARVALID is outstanding but
     * ARREADY hasn't arrived yet (S_AR) -- the other code path the abort
     * fix touches: the AR handshake must still be completed per AXI4 (a
     * VALID can't be retracted before its READY) before anything can idle. */
    preload_ramp(20'd8000, 200);
    addr  = 32'd8000;
    len   = 32'd200;
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;

    i = 0;
    while (dbg_state != 3'd1 && i < 2000) begin   /* wait for S_AR */
      @(posedge clk);
      i = i + 1;
    end

    $display("[%0t] caught in S_AR: dbg_state=%0d m_axi_arvalid=%b m_axi_arready=%b",
              $time, dbg_state, m_axi_arvalid, m_axi_arready);

    dut_watchdog_rst = 1'b0;
    @(posedge clk);
    dut_watchdog_rst = 1'b1;

    i = 0;
    while (busy && i < 2000) begin
      @(posedge clk);
      i = i + 1;
    end

    $display("[%0t] settled after %0d cycles: dbg_state=%0d busy=%b",
              $time, i, dbg_state, busy);

    preload_ramp(20'd9000, 64);
    addr  = 32'd9000;
    len   = 32'd64;
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;

    i = 0;
    while (!done && i < 2000) begin
      @(posedge clk);
      i = i + 1;
    end

    if (done)
      $display("[%0t] RESULT (S_AR abort): PASS -- transfer completed after %0d cycles, bytes_done=%0d (expected 96).", $time, i, bytes_done);
    else
      $display("[%0t] RESULT (S_AR abort): FAIL -- WEDGED (dbg_state=%0d m_axi_arvalid=%b m_axi_arready=%b m_axi_rvalid=%b m_axi_rready=%b).",
                $time, dbg_state, m_axi_arvalid, m_axi_arready, m_axi_rvalid, m_axi_rready);

    $finish;
  end

endmodule
/* not truncated */
