# Standalone, headless SmartPower run against the already placed-and-routed
# MPEG2FPGA_SOC project (not part of build_mpeg2fpga_soc.tcl's flow):
#   libero SCRIPT:run_verify_power.tcl
# Reports land in power_reports/.

set local_dir [pwd]
set project_name "MPEG2FPGA_SOC"
set project_dir "$local_dir/$project_name"

open_project -file $project_dir/$project_name.prjx

# SmartPower takes its clock frequencies from the VERIFYTIMING constraint set
# (power_analysis.sdc is built from it). build_mpeg2fpga_soc.tcl registers
# only apb3_mpeg2fpga_bridge_cdc.sdc there, and organize_tool_files replaces
# rather than appends, so the set carries no create_clock at all and every
# fabric domain comes up at 0 MHz. Register the derived clocks too.
organize_tool_files \
    -tool {VERIFYTIMING} \
    -file "${project_dir}/constraint/MPFS_DISCOVERY_KIT_derived_constraints.sdc" \
    -file "${project_dir}/constraint/apb3_mpeg2fpga_bridge_cdc.sdc" \
    -module {MPFS_DISCOVERY_KIT::work} \
    -input_type {constraint}
run_tool -name {VERIFYPOWER} -script "$local_dir/power_analysis.tcl"
save_project
close_project
