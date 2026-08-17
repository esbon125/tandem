/*
 * testbench.v - stream_dma unit test
 *
 * Exercises stream_dma.v in isolation: fake_axi_ddr_ro.v stands in for the
 * staging-buffer AXI4 target (FIC_2 side), and a small BFM here stands in
 * for mpeg2video's busy/stream_data/stream_valid side, mirroring the same
 * two-sided-fake approach bench/mem_axi_bridge/testbench.v used for
 * mem2axi_bridge.v (Fase 6a). Does not instantiate mpeg2video, the APB
 * bridge, or Libero -- see Fase 7c in the plan.
 *
 * Run: make (see Makefile). Prints one line per check and a final
 * "ALL TESTS PASSED" / "N TEST(S) FAILED" summary.
 */

`include "timescale.v"

`define CLK_PERIOD 10.0

module testbench ();

  reg         clk;
  reg         rst_n;

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

  integer     errors;
  integer     checks;

  /* STAGING_BASE=0 so `addr` maps directly onto fake_axi_ddr_ro's byte
   * array -- the real hardware default (0x88000000) is only meaningful
   * against real DDR, and would just add a constant offset here. */
  stream_dma #(.STAGING_BASE(38'h0), .BURST_BEATS(5'd16)) dut (
      .clk(clk), .rst_n(rst_n),
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
      .m_axi_rlast(m_axi_rlast), .m_axi_ruser(m_axi_ruser), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
  );

  fake_axi_ddr_ro ddr (
      .clk(clk), .rst(rst_n),
      .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
      .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
      .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
      .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
  );

  /* clock */
  initial begin
    clk = 1'b0;
    forever #(`CLK_PERIOD / 2) clk = ~clk;
  end

  /* reset */
  initial begin
    rst_n = 1'b0;
    #(`CLK_PERIOD * 4);
    rst_n = 1'b1;
  end

  /* Watchdog: a stuck handshake would otherwise hang the simulator forever
   * instead of failing loudly. */
  initial begin
    #500000;
    $display("TIMEOUT: simulation did not finish in time (stuck handshake?)");
    $finish;
  end

  initial begin
    start     = 1'b0;
    addr      = 32'b0;
    len       = 32'b0;
    mpeg_busy = 1'b0;
  end

  /* ---- capture every stream_data/stream_valid pulse ---- */
  reg [7:0] captured [0:16383];
  integer   captured_count;

  always @(posedge clk)
    if (rst_n && stream_valid) begin
      captured[captured_count] = stream_data;
      captured_count = captured_count + 1;
    end

  /* ---- capture every accepted AR request's ARLEN, to check burst sizing ---- */
  reg [7:0] ar_seen [0:15];
  integer   ar_seen_count;

  always @(posedge clk)
    if (rst_n && m_axi_arvalid && m_axi_arready) begin
      ar_seen[ar_seen_count] = m_axi_arlen;
      ar_seen_count = ar_seen_count + 1;
    end

  task reset_capture;
    begin
      captured_count = 0;
      ar_seen_count  = 0;
    end
  endtask

  /* ---- run one transfer to completion ---- */
  task run_transfer;
    input [31:0] a;
    input [31:0] l;
    integer      timeout;
    begin
      reset_capture;
      @(posedge clk);
      addr  = a;
      len   = l;
      start = 1'b1;
      @(posedge clk);
      start = 1'b0;
      timeout = 0;
      while (!done) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 50000) begin
          $display("FAIL run_transfer: timed out waiting for done (addr=%0d len=%0d)", a, l);
          $finish;
        end
      end
      @(posedge clk);
    end
  endtask

  /* ---- checks ---- */
  task check_eq;
    input [255:0] name;
    input integer got;
    input integer expected;
    begin
      checks = checks + 1;
      if (got !== expected) begin
        errors = errors + 1;
        $display("FAIL %0s: got %0d, expected %0d", name, got, expected);
      end else begin
        $display("PASS %0s: %0d", name, got);
      end
    end
  endtask

  /* padding byte at index i (0-31): repeats {0x00,0x00,0x01,0xB7} 8 times */
  function [7:0] expected_pad_byte;
    input [4:0] i;
    case (i[1:0])
      2'd2:    expected_pad_byte = 8'h01;
      2'd3:    expected_pad_byte = 8'hB7;
      default: expected_pad_byte = 8'h00;
    endcase
  endfunction

  task check_captured_stream;
    input [255:0] name;
    input integer base;
    input integer payload_len;
    integer i;
    integer ok;
    begin
      checks = checks + 1;
      ok = 1;
      if (captured_count !== (payload_len + 32)) begin
        ok = 0;
        $display("FAIL %0s: captured_count=%0d, expected %0d", name, captured_count, payload_len + 32);
      end else begin
        for (i = 0; i < payload_len; i = i + 1)
          if (captured[i] !== ddr.mem[base + i]) begin
            ok = 0;
            $display("FAIL %0s: payload byte %0d = 0x%02h, expected 0x%02h (ddr.mem[%0d])",
                      name, i, captured[i], ddr.mem[base + i], base + i);
          end
        for (i = 0; i < 32; i = i + 1)
          if (captured[payload_len + i] !== expected_pad_byte(i[4:0])) begin
            ok = 0;
            $display("FAIL %0s: padding byte %0d = 0x%02h, expected 0x%02h",
                      name, i, captured[payload_len + i], expected_pad_byte(i[4:0]));
          end
      end
      if (ok) begin
        errors = errors;
        $display("PASS %0s: %0d payload bytes + 32 padding bytes, all match", name, payload_len);
      end else begin
        errors = errors + 1;
      end
    end
  endtask

  task preload_ramp;
    input [19:0] base;
    input integer n;
    integer i;
    begin
      for (i = 0; i < n; i = i + 1)
        ddr.preload_byte(base + i[19:0], (i * 7 + 3) & 8'hFF);
    end
  endtask

  /* ---- background mpeg_busy driver for the backpressure test: holds
   * mpeg_busy high for HOLD_CYCLES once captured_count first reaches
   * TRIGGER_AT, then releases it for the rest of the transfer. ---- */
  reg [31:0] bp_trigger_at;
  reg [31:0] bp_hold_cycles;
  reg        bp_armed;

  always @(posedge clk) begin
    if (!rst_n) begin
      mpeg_busy <= 1'b0;
    end else if (bp_armed && (captured_count >= bp_trigger_at) && (bp_hold_cycles > 0)) begin
      mpeg_busy      <= 1'b1;
      bp_hold_cycles <= bp_hold_cycles - 1;
    end else begin
      mpeg_busy <= 1'b0;
      if (bp_hold_cycles == 0) bp_armed <= 1'b0;
    end
  end

  initial begin
    errors = 0;
    checks = 0;
    bp_armed = 1'b0;
    bp_trigger_at = 32'd0;
    bp_hold_cycles = 32'd0;

    @(posedge rst_n);
    @(posedge clk);

    /* ---- test 1: zero-length transfer -- only padding, no AXI traffic ---- */
    run_transfer(32'd0, 32'd0);
    check_captured_stream("zero_length", 0, 0);
    check_eq("zero_length.ar_seen_count", ar_seen_count, 0);
    check_eq("zero_length.bytes_done", bytes_done, 32);

    /* ---- test 2: small transfer, single partial beat (5 bytes) ---- */
    preload_ramp(20'd0, 5);
    run_transfer(32'd0, 32'd5);
    check_captured_stream("small_5b", 0, 5);
    check_eq("small_5b.ar_seen_count", ar_seen_count, 1);
    check_eq("small_5b.arlen", ar_seen[0], 0);   /* 1 beat */
    check_eq("small_5b.bytes_done", bytes_done, 37);

    /* ---- test 3: exactly one full burst (128 bytes), nonzero addr ---- */
    preload_ramp(20'd1000, 128);
    run_transfer(32'd1000, 32'd128);
    check_captured_stream("full_burst_128b", 1000, 128);
    check_eq("full_burst_128b.ar_seen_count", ar_seen_count, 1);
    check_eq("full_burst_128b.arlen", ar_seen[0], 15);   /* 16 beats */
    check_eq("full_burst_128b.bytes_done", bytes_done, 160);

    /* ---- test 4: multi-burst with a non-multiple-of-8 tail (300 bytes) ---- */
    preload_ramp(20'd2000, 300);
    run_transfer(32'd2000, 32'd300);
    check_captured_stream("multi_burst_300b", 2000, 300);
    check_eq("multi_burst_300b.ar_seen_count", ar_seen_count, 3);
    check_eq("multi_burst_300b.arlen0", ar_seen[0], 15);   /* 128 bytes */
    check_eq("multi_burst_300b.arlen1", ar_seen[1], 15);   /* 128 bytes -> 256 total */
    check_eq("multi_burst_300b.arlen2", ar_seen[2], 5);    /* 44 bytes -> 6 beats */
    check_eq("multi_burst_300b.bytes_done", bytes_done, 332);

    /* ---- test 5: backpressure mid-transfer must not lose or duplicate bytes ---- */
    preload_ramp(20'd3000, 200);
    bp_trigger_at  = 32'd50;
    bp_hold_cycles = 32'd40;
    bp_armed       = 1'b1;
    run_transfer(32'd3000, 32'd200);
    check_captured_stream("backpressure_200b", 3000, 200);
    check_eq("backpressure_200b.bytes_done", bytes_done, 232);

    /* ---- test 6: a second start pulse while busy must be ignored ---- */
    preload_ramp(20'd4000, 128);
    reset_capture;
    @(posedge clk);
    addr = 32'd4000; len = 32'd128; start = 1'b1;
    @(posedge clk);
    start = 1'b0;
    @(posedge clk);
    addr = 32'd9000; len = 32'd9; start = 1'b1;   /* should be ignored: dut is busy */
    @(posedge clk);
    start = 1'b0;
    begin : wait_done6
      integer timeout;
      timeout = 0;
      while (!done) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 50000) begin
          $display("FAIL start_ignored_while_busy: timed out");
          $finish;
        end
      end
      @(posedge clk);
    end
    check_captured_stream("start_ignored_while_busy", 4000, 128);

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $display("%0d TEST(S) FAILED out of %0d checks", errors, checks);

    $finish;
  end

endmodule
/* not truncated */
