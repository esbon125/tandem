# Microchip Technology Inc.
# Date: 2026-Jun-24 03:39:03
# This file was generated based on the following SDC source files:
#   /home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/PF_CCC_C0/PF_CCC_C0_0/PF_CCC_C0_PF_CCC_C0_0_PF_CCC.sdc
#   /home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_pixel_stream_dc_35x1024/fifo_pixel_stream_dc_35x1024_0/fifo_pixel_stream_dc_35x1024_fifo_pixel_stream_dc_35x1024_0_COREFIFO.sdc
#   /home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_req_dc_88x64/fifo_mem_req_dc_88x64_0/fifo_mem_req_dc_88x64_fifo_mem_req_dc_88x64_0_COREFIFO.sdc
#   /home/esbon/Proyectos/tandem/trunk/mpeg2fpga/mpeg2fpga/component/work/fifo_mem_rsp_dc_64x128/fifo_mem_rsp_dc_64x128_0/fifo_mem_rsp_dc_64x128_fifo_mem_rsp_dc_64x128_0_COREFIFO.sdc
# *** Any modifications to this file will be lost if derived constraints is re-run. ***
#

create_clock -name {ref_clk} -period 20 [ get_ports { ref_clk } ]
create_generated_clock -name {u_mpeg2/u_ccc/PF_CCC_C0_0/pll_inst_0/OUT0} -multiply_by 81 -divide_by 25 -source [ get_pins { u_mpeg2/u_ccc/PF_CCC_C0_0/pll_inst_0/REF_CLK_0 } ] -phase 0 [ get_pins { u_mpeg2/u_ccc/PF_CCC_C0_0/pll_inst_0/OUT0 } ]
create_generated_clock -name {u_mpeg2/u_ccc/PF_CCC_C0_0/pll_inst_0/OUT1} -multiply_by 54 -divide_by 25 -source [ get_pins { u_mpeg2/u_ccc/PF_CCC_C0_0/pll_inst_0/REF_CLK_0 } ] -phase 0 [ get_pins { u_mpeg2/u_ccc/PF_CCC_C0_0/pll_inst_0/OUT1 } ]
create_generated_clock -name {u_mpeg2/u_ccc/PF_CCC_C0_0/pll_inst_0/OUT2} -multiply_by 27 -divide_by 50 -source [ get_pins { u_mpeg2/u_ccc/PF_CCC_C0_0/pll_inst_0/REF_CLK_0 } ] -phase 0 [ get_pins { u_mpeg2/u_ccc/PF_CCC_C0_0/pll_inst_0/OUT2 } ]

# CoreFIFO_dc async FIFOs (fifo_pixel_stream_dc, fifo_mem_req_dc, fifo_mem_rsp_dc)
# each embed a multi-stage gray-code pointer synchronizer (U_corefifo_async/
# *_NstagesSync) plus a synchronized-reset input feeding the same flops' load
# pins. The core generator ships a matching false path in its own
# component-scoped SDC (component/work/.../*_COREFIFO.sdc), but that file is
# never merged into top_derived_constraints.sdc/place_route.sdc/
# timing_analysis.sdc -- Libero's Derive Constraints flow only promotes clock
# definitions from IP SDCs, not exceptions -- so full-chip min-delay analysis
# runs straight through these known-async capture stages and reports hold
# violations (see designer/top/top_min_timing_violations_multi_corner.xml).
# Re-declare the exception here, widened to also cover shift_mem_reg and
# ptr_bin_sync2, which the vendor's shift_reg* glob misses.
set_false_path -to [get_cells {*U_corefifo_async/*shift_reg*}]
set_false_path -to [get_cells {*U_corefifo_async/*shift_mem_reg*}]
set_false_path -to [get_cells {*U_corefifo_async/*ptr_bin_sync*}]

# reset.v builds its clk/mem_clk/dot_clk resets out of chained sync_reset
# instances (u_mpeg2/reset/clk_sreset_0, dot_sreset_1, clk_sreset_2, ...),
# each an async-assert/sync-deassert synchronizer whose whole purpose is to
# hand a clock's downstream logic a reset that needs no timing relationship
# to the register that produced it. Excepting destination register names one
# at a time (shift_reg, shift_mem_reg, ptr_bin_sync2, and now rptr_fwft /
# rptr_gray_fwft, plus reset.v's own internal dot_sreset_1 ALn/rff1 pins) is
# whack-a-mole: any new synchronizer stage or fanout target reintroduces the
# same false min-delay (removal) violation. Except at the source instead --
# every path launched from any syncrst/rff1 stage inside the reset tree,
# regardless of where it lands.
set_false_path -from [get_cells {u_mpeg2/reset/*syncrst*}]
set_false_path -from [get_cells {u_mpeg2/reset/*rff1*}]