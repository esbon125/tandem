/*
 * mpeg2fpga_apb_peripheral.v
 *
 * Top-level wrapper combining apb3_mpeg2fpga_bridge.v and mpeg2video.v into
 * a single APB3 slave peripheral, registered as a Libero HDL core (see
 * script_support/components/MPEG2FPGA_APB_PERIPHERAL.tcl) and instantiated
 * in the FIC_3_PERIPHERALS SmartDesign in place of the Discovery Kit's
 * 7-segment display SPI (unused by this project) -- see Fase 5b in the
 * project plan and docs/bringup/05_mss_apb_bridge_tdd.md for why.
 *
 * Only the register interface and interrupt are wired to the rest of the
 * SoC in this phase; the stream input, video output and external memory
 * FIFOs are tied off exactly as hdl/top.v already did (Fase 5 explicitly
 * scopes those out -- they need a DDR/video-output architecture decision
 * of their own).
 */

`include "timescale.v"

module mpeg2fpga_apb_peripheral (
    /* APB3 slave: FIC_3's PCLK domain */
    PCLK, PRESETn,
    PSEL, PENABLE, PWRITE, PADDR, PWDATA, PRDATA, PREADY,

    /* mpeg2video's own reference clock and reset (PF_CCC_C0 derives
     * clk/mem_clk/dot_clk from ref_clk internally, see mpeg2video.v)
     */
    ref_clk, rst_n,

    /* single interrupt line, routed to a free MSS_INT_F2M bit */
    interrupt
);

  input        PCLK;
  input        PRESETn;
  input        PSEL;
  input        PENABLE;
  input        PWRITE;
  input  [5:0] PADDR;
  input [31:0] PWDATA;
  output[31:0] PRDATA;
  output       PREADY;

  input        ref_clk;
  input        rst_n;

  output       interrupt;

  wire  [3:0]  reg_addr;
  wire         reg_wr_en;
  wire [31:0]  reg_dta_in;
  wire         reg_rd_en;
  wire [31:0]  reg_dta_out;

  wire         busy;
  wire         error;
  wire         watchdog_rst;

  wire  [7:0]  r, g, b, y, u, v;
  wire         pixel_en, h_sync, v_sync, c_sync;

  wire  [1:0]  mem_req_rd_cmd;
  wire [21:0]  mem_req_rd_addr;
  wire [63:0]  mem_req_rd_dta;
  wire         mem_req_rd_valid;
  wire         mem_res_wr_almost_full;

  wire [33:0]  testpoint;

  /* mpeg2video's internal "clk" (PF_CCC_C0-derived from ref_clk) is what
   * regfile.v actually samples reg_addr/reg_wr_en/reg_rd_en/reg_dta_in on
   * (doc/mpeg2fpga.txt sec. 1.2.4: "clocked with clk") -- the bridge's
   * core_clk must be *that exact signal*, not an independently-instantiated
   * second PF_CCC_C0 output of the same nominal frequency (which would be
   * a second, unsynchronized PLL, silently reintroducing an unhandled
   * clock-domain crossing between the bridge and regfile.v). mpeg2video.v
   * was given a small additive change (clk_out output port, mirroring its
   * existing internal clk wire) specifically so this wrapper can reuse the
   * one real clock instead.
   */
  wire clk_internal;

  apb3_mpeg2fpga_bridge u_bridge (
      .PCLK(PCLK), .PRESETn(PRESETn),
      .PSEL(PSEL), .PENABLE(PENABLE), .PWRITE(PWRITE),
      .PADDR(PADDR), .PWDATA(PWDATA), .PRDATA(PRDATA), .PREADY(PREADY),

      .core_clk(clk_internal), .core_rst_n(rst_n),
      .reg_addr(reg_addr), .reg_wr_en(reg_wr_en), .reg_dta_in(reg_dta_in),
      .reg_rd_en(reg_rd_en), .reg_dta_out(reg_dta_out)
  );

  mpeg2video u_mpeg2 (
      .ref_clk(ref_clk),
      .clk_out(clk_internal),
      .rst(rst_n),

      .stream_data(8'h00),
      .stream_valid(1'b0),

      .reg_addr(reg_addr),
      .reg_wr_en(reg_wr_en),
      .reg_dta_in(reg_dta_in),
      .reg_rd_en(reg_rd_en),
      .reg_dta_out(reg_dta_out),

      .busy(busy),
      .error(error),
      .interrupt(interrupt),
      .watchdog_rst(watchdog_rst),

      .r(r), .g(g), .b(b), .y(y), .u(u), .v(v),
      .pixel_en(pixel_en), .h_sync(h_sync), .v_sync(v_sync), .c_sync(c_sync),

      .mem_req_rd_cmd(mem_req_rd_cmd),
      .mem_req_rd_addr(mem_req_rd_addr),
      .mem_req_rd_dta(mem_req_rd_dta),
      .mem_req_rd_en(1'b0),
      .mem_req_rd_valid(mem_req_rd_valid),

      .mem_res_wr_dta(64'h0),
      .mem_res_wr_en(1'b0),
      .mem_res_wr_almost_full(mem_res_wr_almost_full),

      .testpoint_dip(4'h0),
      .testpoint_dip_en(1'b0),
      .testpoint(testpoint)
  );

endmodule
/* not truncated */
