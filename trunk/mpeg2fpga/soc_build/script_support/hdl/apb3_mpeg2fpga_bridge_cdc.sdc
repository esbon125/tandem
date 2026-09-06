# CDC timing exceptions for apb3_mpeg2fpga_bridge.v (Fase 5a/5c).
#
# apb_addr_r/apb_wdata_r/apb_write_r (PCLK domain) and rdata_hold (core_clk
# domain) are deliberately read directly by the other clock domain without
# their own synchronizer -- see the design-note comment in
# apb3_mpeg2fpga_bridge.v: they are set/held stable for the whole duration of
# a transaction (many cycles, guarded by the req_toggle/ack_toggle two-phase
# handshake, which *is* properly 2FF-synchronized), so sampling them any time
# after the synchronized toggle edge is safe. STA has no way to know that
# protocol-level guarantee and times them as ordinary single-cycle paths
# between unrelated clocks, which cannot be met (see docs/bringup for the
# ~-5.5ns violations this produced before this file existed). These paths are
# true false paths, not a masked bug -- verified against
# MPFS_DISCOVERY_KIT_timing_violations_max_*.rpt (Fase 5c).
#
# NOTE: `name[*]` (asterisk *inside* brackets) is wrong here -- in the
# Tcl-glob syntax get_cells uses, `[...]` denotes a character class, so
# `[*]` matches a single literal '*' character, not "any bus index". It
# silently matched zero cells (no SDC0023, since abort_flow_on_sdc_errors is
# off below) and every one of these paths kept showing up as violations
# through two full P&R re-runs. The working convention, confirmed against
# COREFIFO's own auto-derived `shift_reg*` false-path pattern elsewhere in
# this project (MPFS_DISCOVERY_KIT_derived_constraints.sdc), is a bare
# trailing `*` with no brackets around it.
set_false_path -from [ get_cells { FIC_3_PERIPHERALS_0/MPEG2FPGA_APB_PERIPHERAL_0/u_bridge/apb_addr_r* } ]
set_false_path -from [ get_cells { FIC_3_PERIPHERALS_0/MPEG2FPGA_APB_PERIPHERAL_0/u_bridge/apb_wdata_r* } ]
set_false_path -from [ get_cells { FIC_3_PERIPHERALS_0/MPEG2FPGA_APB_PERIPHERAL_0/u_bridge/apb_write_r } ]
set_false_path -from [ get_cells { FIC_3_PERIPHERALS_0/MPEG2FPGA_APB_PERIPHERAL_0/u_bridge/rdata_hold* } ]
