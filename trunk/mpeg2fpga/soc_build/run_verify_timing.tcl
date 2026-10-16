# Standalone, headless static timing analysis of the already placed-and-routed
# MPEG2FPGA_SOC project, with the real clock constraints:
#   libero SCRIPT:run_verify_timing.tcl
# Re-registers the VERIFYTIMING constraint set (derived clocks + the bridge's
# false paths) and runs Verify Timing; synthesis and place-and-route are not
# touched, so the reports are those of the bitstream already in the project.
# Reports: MPEG2FPGA_SOC/designer/MPFS_DISCOVERY_KIT/*timing*

set local_dir [pwd]
set project_name "MPEG2FPGA_SOC"
set project_dir "$local_dir/$project_name"

open_project -file $project_dir/$project_name.prjx

organize_tool_files \
    -tool {VERIFYTIMING} \
    -file "${project_dir}/constraint/MPFS_DISCOVERY_KIT_derived_constraints.sdc" \
    -file "${project_dir}/constraint/apb3_mpeg2fpga_bridge_cdc.sdc" \
    -module {MPFS_DISCOVERY_KIT::work} \
    -input_type {constraint}
run_tool -name {VERIFYTIMING}
save_project
close_project
