// SPDX-FileCopyrightText: 2026 Esteban Bustamante
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// This source describes Open Hardware and is licensed under the CERN-OHL-S v2.
// You may redistribute and modify this source and make products using it
// under the terms of the CERN-OHL-S v2 (https://ohwr.org/cern_ohl_s_v2.txt).
// This source is distributed WITHOUT ANY EXPRESS OR IMPLIED WARRANTY,
// INCLUDING OF MERCHANTABILITY, SATISFACTORY QUALITY AND FITNESS FOR A
// PARTICULAR PURPOSE. Please see the CERN-OHL-S v2 for applicable conditions.
// Source location: https://github.com/esbon125/tandem
//
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
