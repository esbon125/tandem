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
 *
 * Fase 7c adds a second, autonomous stream source: u_stream_dma (see
 * stream_dma.v) reads a DDR staging buffer over its own AXI4 master
 * (promoted to top-level dma_axi_* ports, wired to the SmartDesign's
 * previously-unused FIC_2_AXI4_TARGET) and drives the same stream_data/
 * stream_valid pair u_bridge's STREAM_PUSH_ADDR does. A mux picks whichever
 * source is active, selected by u_stream_dma's own busy output (high =
 * a DMA transfer owns the pair) -- the two are mutually exclusive by
 * software contract (don't write STREAM_PUSH_ADDR while a DMA transfer is
 * running), not by extra interlock hardware, matching every other
 * register-ordering contract in this design (e.g. DMA_ADDR/DMA_LEN before
 * DMA_CTRL). u_stream_dma runs on the exact same clk_internal (core_clk)
 * u_bridge and u_mpeg2 already do -- newly promoted here as top-level
 * clk_out so the SmartDesign can feed it into FIC_2_ACLK too, avoiding a
 * second clock-domain crossing entirely (see stream_dma.v's header).
 *
 * Fase 7c PWDATA investigation, root cause found: PWDATA reaching u_bridge
 * was never actually wrong -- the MSS FIC_3 AXI-to-APB conversion presents
 * a 32-bit software store as *multiple* single-byte APB write beats (each
 * with that byte replicated across all 4 PWDATA lanes), using PSTRB to mark
 * which lane is real on each beat, and apb3_mpeg2fpga_bridge.v was blindly
 * overwriting its DMA_ADDR/DMA_LEN registers with whatever was on PWDATA on
 * *every* beat -- so only the last (most-significant-byte) beat survived,
 * explaining "always reads back 0" for every small test value ever tried
 * (see docs/bringup). PSTRB is a broadcast signal, not part of the APB_bif
 * decode chain (CoreAPB3 doesn't even have a PSTRB port -- see
 * FIC_3_PERIPHERALS.tcl), so it's a new, separate top-level port here,
 * wired in parallel the same way RECONFIGURATION_INTERFACE_0 already was.
 */

`include "timescale.v"

module mpeg2fpga_apb_peripheral (
    /* APB3 slave: FIC_3's PCLK domain */
    PCLK, PRESETn,
    PSEL, PENABLE, PWRITE, PADDR, PWDATA, PRDATA, PREADY,
    PSTRB,

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

    /* mpeg2video's internal core clk (clk_out), promoted (Fase 7c) so the
     * SmartDesign top can feed the same clock into FIC_2_ACLK for
     * u_stream_dma's AXI4 master -- see stream_dma.v's header comment. */
    clk_out,

    /* AXI4 master to MSS_WRAPPER:FIC_1_AXI4_TARGET (DDR4), via mem2axi_bridge.
     * See mem2axi_bridge.v's port list comment for why the *LOCK, *CACHE,
     * *PROT, *QOS, *REGION, *USER sideband signals are here too. */
    m_axi_awid, m_axi_awaddr, m_axi_awlen, m_axi_awsize, m_axi_awburst, m_axi_awlock, m_axi_awcache, m_axi_awprot, m_axi_awqos, m_axi_awregion, m_axi_awuser, m_axi_awvalid, m_axi_awready,
    m_axi_wdata, m_axi_wstrb, m_axi_wlast, m_axi_wuser, m_axi_wvalid, m_axi_wready,
    m_axi_bid, m_axi_bresp, m_axi_buser, m_axi_bvalid, m_axi_bready,
    m_axi_arid, m_axi_araddr, m_axi_arlen, m_axi_arsize, m_axi_arburst, m_axi_arlock, m_axi_arcache, m_axi_arprot, m_axi_arqos, m_axi_arregion, m_axi_aruser, m_axi_arvalid, m_axi_arready,
    m_axi_rid, m_axi_rdata, m_axi_rresp, m_axi_rlast, m_axi_ruser, m_axi_rvalid, m_axi_rready,

    /* AXI4 read-only master to MSS_WRAPPER:FIC_2_AXI4_TARGET (DDR4), via
     * u_stream_dma -- a second, independent fabric-master path into DDR
     * (Fase 7c), free since the base reference design never uses FIC_2. */
    dma_axi_arid, dma_axi_araddr, dma_axi_arlen, dma_axi_arsize, dma_axi_arburst, dma_axi_arlock, dma_axi_arcache, dma_axi_arprot, dma_axi_arqos, dma_axi_arregion, dma_axi_aruser, dma_axi_arvalid, dma_axi_arready,
    dma_axi_rid, dma_axi_rdata, dma_axi_rresp, dma_axi_rlast, dma_axi_ruser, dma_axi_rvalid, dma_axi_rready
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
  input  [3:0] PSTRB;

  input        ref_clk;
  input        rst_n;

  output       interrupt;

  output       mem_clk_out;
  output       clk_out;

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

  output      [3:0]dma_axi_arid;
  output     [37:0]dma_axi_araddr;
  output      [7:0]dma_axi_arlen;
  output      [2:0]dma_axi_arsize;
  output      [1:0]dma_axi_arburst;
  output           dma_axi_arlock;
  output      [3:0]dma_axi_arcache;
  output      [2:0]dma_axi_arprot;
  output      [3:0]dma_axi_arqos;
  output      [3:0]dma_axi_arregion;
  output      [0:0]dma_axi_aruser;
  output           dma_axi_arvalid;
  input            dma_axi_arready;

  input       [3:0]dma_axi_rid;
  input      [63:0]dma_axi_rdata;
  input       [1:0]dma_axi_rresp;
  input            dma_axi_rlast;
  input       [0:0]dma_axi_ruser;
  input            dma_axi_rvalid;
  output           dma_axi_rready;

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
  /* Fase 7a debug (2026-08-23): mpeg2video's core_clk-domain equivalent of
   * mem_rst_internal above (reset pin OR watchdog expiry) -- see
   * mpeg2video.v's core_rst_out comment and stream_dma.v's header. */
  wire         core_rst_internal;

  wire [33:0]  testpoint;

  /* Fase 7a debug (2026-08-21) */
  wire [21:0]  vbuf_wr_addr_internal;
  wire [21:0]  vbuf_rd_addr_internal;
  wire [31:0]  disp_service_cnt_internal;
  wire [31:0]  vbr_service_cnt_internal;
  wire [31:0]  vbr_starved_cnt_internal;
  wire [31:0]  arbiter_flags_internal;
  wire [31:0]  mem_res_valid_cnt_internal;
  wire [21:0]  dbg_last_write_addr_from_fifo_internal;
  wire [37:0]  dbg_last_write_awaddr_issued_internal;
  wire [21:0]  dbg_last_mem_req_wr_addr_internal;

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

  /* Fase 7c: stream_dma control (core_clk domain, driven by u_bridge's new
   * DMA_ADDR/DMA_LEN/DMA_CTRL/DMA_STATUS registers) and its own stream_data/
   * stream_valid pair, muxed with u_bridge's manual-push pair below. */
  wire        dma_start;
  wire [31:0] dma_addr;
  wire [31:0] dma_len;
  wire        dma_busy;
  wire        dma_done;
  wire [31:0] dma_bytes_done;
  wire [7:0]  dma_stream_data;
  wire        dma_stream_valid;

  wire [7:0] stream_data_mux  = dma_busy ? dma_stream_data  : stream_data_internal;
  wire       stream_valid_mux = dma_busy ? dma_stream_valid : stream_valid_internal;

  /* Fase 7a debug (2026-08-23): stream_dma.v's own FSM state, packed into
   * ARBITER_FLAGS's previously-unused [31:19] bits (see arbiter_flags_
   * internal's own [18:0]-only usage below) instead of claiming a new APB
   * address -- lets software directly confirm/refute whether stream_dma is
   * still mid-transaction (S_AR/S_RDATA/S_DRAIN with dma_axi_arvalid or
   * dma_axi_rvalid stuck asserted) after a watchdog-triggered reset,
   * instead of only inferring it from mem2axi_bridge's downstream symptoms.
   * dma_axi_arvalid/dma_axi_rvalid are already this module's own top-level
   * wires (real AXI4 signals to FIC_2), no new plumbing needed for those. */
  wire [2:0] dma_state_dbg;
  wire [31:0] arbiter_flags_combined =
      {8'b0, dma_axi_rvalid, dma_axi_arvalid, dma_state_dbg, arbiter_flags_internal[18:0]};

  apb3_mpeg2fpga_bridge u_bridge (
      .PCLK(PCLK), .PRESETn(PRESETn),
      .PSEL(PSEL), .PENABLE(PENABLE), .PWRITE(PWRITE),
      .PADDR(PADDR), .PWDATA(PWDATA), .PRDATA(PRDATA), .PREADY(PREADY),
      .PSTRB(PSTRB),

      .core_clk(clk_internal), .core_rst_n(rst_n),
      .reg_addr(reg_addr), .reg_wr_en(reg_wr_en), .reg_dta_in(reg_dta_in),
      .reg_rd_en(reg_rd_en), .reg_dta_out(reg_dta_out),

      .busy(busy),
      .stream_data(stream_data_internal),
      .stream_valid(stream_valid_internal),

      .dma_start(dma_start), .dma_addr(dma_addr), .dma_len(dma_len),
      .dma_busy(dma_busy), .dma_done(dma_done), .dma_bytes_done(dma_bytes_done),

      .vbuf_wr_addr(vbuf_wr_addr_internal), .vbuf_rd_addr(vbuf_rd_addr_internal),

      .disp_service_cnt(disp_service_cnt_internal),
      .vbr_service_cnt(vbr_service_cnt_internal),
      .vbr_starved_cnt(vbr_starved_cnt_internal),
      .arbiter_flags(arbiter_flags_combined),
      .mem_res_valid_cnt(mem_res_valid_cnt_internal),

      .dbg_last_write_addr_from_fifo(dbg_last_write_addr_from_fifo_internal),
      .dbg_last_write_awaddr_issued(dbg_last_write_awaddr_issued_internal),
      .dbg_last_mem_req_wr_addr(dbg_last_mem_req_wr_addr_internal)
  );

  stream_dma u_stream_dma (
      .clk(clk_internal), .rst_n(core_rst_internal),

      .start(dma_start), .addr(dma_addr), .len(dma_len),
      .busy(dma_busy), .done(dma_done), .bytes_done(dma_bytes_done),

      .mpeg_busy(busy),
      .stream_data(dma_stream_data), .stream_valid(dma_stream_valid),

      .m_axi_arid(dma_axi_arid), .m_axi_araddr(dma_axi_araddr), .m_axi_arlen(dma_axi_arlen),
      .m_axi_arsize(dma_axi_arsize), .m_axi_arburst(dma_axi_arburst),
      .m_axi_arlock(dma_axi_arlock), .m_axi_arcache(dma_axi_arcache), .m_axi_arprot(dma_axi_arprot),
      .m_axi_arqos(dma_axi_arqos), .m_axi_arregion(dma_axi_arregion), .m_axi_aruser(dma_axi_aruser),
      .m_axi_arvalid(dma_axi_arvalid), .m_axi_arready(dma_axi_arready),
      .m_axi_rid(dma_axi_rid), .m_axi_rdata(dma_axi_rdata), .m_axi_rresp(dma_axi_rresp),
      .m_axi_rlast(dma_axi_rlast), .m_axi_ruser(dma_axi_ruser), .m_axi_rvalid(dma_axi_rvalid), .m_axi_rready(dma_axi_rready),
      .dbg_state(dma_state_dbg)
  );

  assign clk_out = clk_internal;

  mpeg2video u_mpeg2 (
      .ref_clk(ref_clk),
      .clk_out(clk_internal),
      .mem_clk_out(mem_clk_internal),
      .mem_rst_out(mem_rst_internal),
      .core_rst_out(core_rst_internal),
      .rst(rst_n),

      .stream_data(stream_data_mux),
      .stream_valid(stream_valid_mux),

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
      .testpoint(testpoint),

      .vbuf_wr_addr(vbuf_wr_addr_internal),
      .vbuf_rd_addr(vbuf_rd_addr_internal),

      .disp_service_cnt(disp_service_cnt_internal),
      .vbr_service_cnt(vbr_service_cnt_internal),
      .vbr_starved_cnt(vbr_starved_cnt_internal),
      .arbiter_flags(arbiter_flags_internal),
      .mem_res_valid_cnt(mem_res_valid_cnt_internal),
      .dbg_last_mem_req_wr_addr(dbg_last_mem_req_wr_addr_internal)
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
      .m_axi_rlast(m_axi_rlast), .m_axi_ruser(m_axi_ruser), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),

      .dbg_last_write_addr_from_fifo(dbg_last_write_addr_from_fifo_internal),
      .dbg_last_write_awaddr_issued(dbg_last_write_awaddr_issued_internal)
  );

endmodule
/* not truncated */
