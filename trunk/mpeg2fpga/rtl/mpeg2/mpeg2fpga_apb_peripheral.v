/*
 * mpeg2fpga_apb_peripheral.v
 *
 * Top-level wrapper combining apb3_mpeg2fpga_bridge.v, mem2axi_bridge.v and
 * mpeg2video.v into a single peripheral, registered as a Libero HDL core
 * (see script_support/components/MPEG2FPGA_APB_PERIPHERAL.tcl) and
 * instantiated in the FIC_3_PERIPHERALS SmartDesign in place of the
 * Discovery Kit's 7-segment display SPI (unused by this project) -- see
 * Fase 5b in the project plan and docs/bringup/05_mss_apb_bridge_tdd.md.
 *
 * Fase 6b adds the external-memory side: mpeg2video's mem_req_rd_ and
 * mem_res_wr_ ports now drive a real mem2axi_bridge instance instead of being
 * tied off, with its AXI4 master promoted to top-level ports here so the
 * SmartDesign can wire them to the MSS's FIC_1_AXI4_TARGET port (chosen
 * because it's free -- see mem2axi_bridge.v's header comment). The video
 * output path is still tied off exactly as hdl/top.v did.
 *
 * Fase 7a adds the stream input side: u_bridge's new STREAM_PUSH_ADDR
 * (see apb3_mpeg2fpga_bridge.v) now drives mpeg2video's stream_data/
 * stream_valid directly, instead of the 8'h00/1'b0 tie-off. mpeg2video's
 * busy output feeds back into the bridge so a push blocks (via APB wait
 * states) until there's room, instead of silently dropping bytes.
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
    interrupt,

    /* mpeg2video's internal mem_clk, promoted so the SmartDesign top can
     * feed the exact same clock into MSS_WRAPPER's FIC_1_ACLK -- see
     * mem2axi_bridge.v's header comment for why this must not be a second,
     * independently-generated clock. */
    mem_clk_out,

    /* AXI4 master to MSS_WRAPPER:FIC_1_AXI4_TARGET (DDR4), via mem2axi_bridge.
     * See mem2axi_bridge.v's port list comment for why the *LOCK, *CACHE,
     * *PROT, *QOS, *REGION, *USER sideband signals are here too. */
    m_axi_awid, m_axi_awaddr, m_axi_awlen, m_axi_awsize, m_axi_awburst, m_axi_awlock, m_axi_awcache, m_axi_awprot, m_axi_awqos, m_axi_awregion, m_axi_awuser, m_axi_awvalid, m_axi_awready,
    m_axi_wdata, m_axi_wstrb, m_axi_wlast, m_axi_wuser, m_axi_wvalid, m_axi_wready,
    m_axi_bid, m_axi_bresp, m_axi_buser, m_axi_bvalid, m_axi_bready,
    m_axi_arid, m_axi_araddr, m_axi_arlen, m_axi_arsize, m_axi_arburst, m_axi_arlock, m_axi_arcache, m_axi_arprot, m_axi_arqos, m_axi_arregion, m_axi_aruser, m_axi_arvalid, m_axi_arready,
    m_axi_rid, m_axi_rdata, m_axi_rresp, m_axi_rlast, m_axi_ruser, m_axi_rvalid, m_axi_rready
);

  /* Fase 7a debug (SIZE staying 0 after a real push): DDR_BASE=0 pointed
   * mem2axi_bridge at physical address 0x0, which "cat /proc/iomem" on the
   * real board confirms is NOT DDR -- Linux's own "System RAM" only starts
   * at 0x80000000. Writes there were very likely going nowhere, which
   * explains vbr_rd_dta (probe.v testpoint 0) never showing any of the
   * pushed bytes read back.
   *
   * 0xc8000000 is "udmabuf-ddr-nc0" (dmesg: "u-dma-buf udmabuf1: assigned
   * reserved memory node buffer@c8000000", exposed to Linux as
   * /dev/udmabuf-ddr-nc0) -- an existing 32 MiB reserved-memory carve-out
   * from the base Discovery Kit reference design, exactly the size of
   * mpeg2fpga's private window, 32 MiB aligned, non-cached (so a future
   * Linux-side mmap of the *same* physical bytes -- Fase 7c/7d -- can't see
   * stale CPU-cached data written by fabric, which never goes through the
   * cache at all). Reusing it also means Fase 7c doesn't need a new
   * reserved-memory device-tree entry of its own, same reasoning as
   * reusing already-proven MSS config in Fase 5b/6b.
   */
  parameter [37:0] DDR_BASE = 38'hc8000000;

  input        PCLK;
  input        PRESETn;
  input        PSEL;
  input        PENABLE;
  input        PWRITE;
  input  [6:0] PADDR;
  input [31:0] PWDATA;
  output[31:0] PRDATA;
  output       PREADY;

  input        ref_clk;
  input        rst_n;

  output       interrupt;

  output       mem_clk_out;

  output      [3:0]m_axi_awid;
  output     [37:0]m_axi_awaddr;
  output      [7:0]m_axi_awlen;
  output      [2:0]m_axi_awsize;
  output      [1:0]m_axi_awburst;
  output           m_axi_awlock;
  output      [3:0]m_axi_awcache;
  output      [2:0]m_axi_awprot;
  output      [3:0]m_axi_awqos;
  output      [3:0]m_axi_awregion;
  output      [0:0]m_axi_awuser;
  output           m_axi_awvalid;
  input            m_axi_awready;

  output     [63:0]m_axi_wdata;
  output      [7:0]m_axi_wstrb;
  output           m_axi_wlast;
  output      [0:0]m_axi_wuser;
  output           m_axi_wvalid;
  input            m_axi_wready;

  input       [3:0]m_axi_bid;
  input       [1:0]m_axi_bresp;
  input       [0:0]m_axi_buser;
  input            m_axi_bvalid;
  output           m_axi_bready;

  output      [3:0]m_axi_arid;
  output     [37:0]m_axi_araddr;
  output      [7:0]m_axi_arlen;
  output      [2:0]m_axi_arsize;
  output      [1:0]m_axi_arburst;
  output           m_axi_arlock;
  output      [3:0]m_axi_arcache;
  output      [2:0]m_axi_arprot;
  output      [3:0]m_axi_arqos;
  output      [3:0]m_axi_arregion;
  output      [0:0]m_axi_aruser;
  output           m_axi_arvalid;
  input            m_axi_arready;

  input       [3:0]m_axi_rid;
  input      [63:0]m_axi_rdata;
  input       [1:0]m_axi_rresp;
  input            m_axi_rlast;
  input       [0:0]m_axi_ruser;
  input            m_axi_rvalid;
  output           m_axi_rready;

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
  wire         mem_req_rd_en;
  wire         mem_req_rd_valid;
  wire [63:0]  mem_res_wr_dta;
  wire         mem_res_wr_en;
  wire         mem_res_wr_almost_full;

  wire         mem_clk_internal;
  wire         mem_rst_internal;

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
  wire [7:0] stream_data_internal;
  wire       stream_valid_internal;

  apb3_mpeg2fpga_bridge u_bridge (
      .PCLK(PCLK), .PRESETn(PRESETn),
      .PSEL(PSEL), .PENABLE(PENABLE), .PWRITE(PWRITE),
      .PADDR(PADDR), .PWDATA(PWDATA), .PRDATA(PRDATA), .PREADY(PREADY),

      .core_clk(clk_internal), .core_rst_n(rst_n),
      .reg_addr(reg_addr), .reg_wr_en(reg_wr_en), .reg_dta_in(reg_dta_in),
      .reg_rd_en(reg_rd_en), .reg_dta_out(reg_dta_out),

      .busy(busy),
      .stream_data(stream_data_internal),
      .stream_valid(stream_valid_internal)
  );

  mpeg2video u_mpeg2 (
      .ref_clk(ref_clk),
      .clk_out(clk_internal),
      .mem_clk_out(mem_clk_internal),
      .mem_rst_out(mem_rst_internal),
      .rst(rst_n),

      .stream_data(stream_data_internal),
      .stream_valid(stream_valid_internal),

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
      .mem_req_rd_en(mem_req_rd_en),
      .mem_req_rd_valid(mem_req_rd_valid),

      .mem_res_wr_dta(mem_res_wr_dta),
      .mem_res_wr_en(mem_res_wr_en),
      .mem_res_wr_almost_full(mem_res_wr_almost_full),

      .testpoint_dip(4'h0),
      .testpoint_dip_en(1'b0),
      .testpoint(testpoint)
  );

  assign mem_clk_out = mem_clk_internal;

  mem2axi_bridge #(.DDR_BASE(DDR_BASE)) u_mem_bridge (
      .clk(mem_clk_internal),
      .rst(mem_rst_internal),

      .mem_req_rd_cmd(mem_req_rd_cmd),
      .mem_req_rd_addr(mem_req_rd_addr),
      .mem_req_rd_dta(mem_req_rd_dta),
      .mem_req_rd_en(mem_req_rd_en),
      .mem_req_rd_valid(mem_req_rd_valid),

      .mem_res_wr_dta(mem_res_wr_dta),
      .mem_res_wr_en(mem_res_wr_en),
      .mem_res_wr_almost_full(mem_res_wr_almost_full),

      .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
      .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
      .m_axi_awlock(m_axi_awlock), .m_axi_awcache(m_axi_awcache), .m_axi_awprot(m_axi_awprot),
      .m_axi_awqos(m_axi_awqos), .m_axi_awregion(m_axi_awregion), .m_axi_awuser(m_axi_awuser),
      .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
      .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast), .m_axi_wuser(m_axi_wuser),
      .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
      .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp), .m_axi_buser(m_axi_buser), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
      .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
      .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
      .m_axi_arlock(m_axi_arlock), .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot),
      .m_axi_arqos(m_axi_arqos), .m_axi_arregion(m_axi_arregion), .m_axi_aruser(m_axi_aruser),
      .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
      .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
      .m_axi_rlast(m_axi_rlast), .m_axi_ruser(m_axi_ruser), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
  );

endmodule
/* not truncated */
