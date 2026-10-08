/*
 * build_id.v -- release identity read back through apb3_mpeg2fpga_bridge.v
 * (BUILD_VERSION 0x2b, BUILD_GIT 0x2c).
 *
 * The values in the tree are placeholders. soc_build/build_mpeg2fpga_soc.tcl
 * rewrites the Libero project's own copy of this file (MPEG2FPGA_SOC/hdl/)
 * after importing the sources, with the commit it is building from, so the
 * tree itself never goes dirty because of a build. Bump
 * MPEG2FPGA_BUILD_VERSION here as part of cutting a release.
 *
 *   MPEG2FPGA_BUILD_VERSION  {major[7:0], minor[7:0], patch[15:0]}
 *   MPEG2FPGA_BUILD_GIT      {dirty, 3'b0, short hash[27:0]}; 0 = unknown
 */
`ifndef MPEG2FPGA_BUILD_ID
`define MPEG2FPGA_BUILD_ID
`define MPEG2FPGA_BUILD_VERSION 32'h00_01_0000
`define MPEG2FPGA_BUILD_GIT     32'h0000_0000
`endif
