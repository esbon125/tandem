puts "TCL_BEGIN: [info script]"

#
# // mpeg2fpga SoC build (Fase 5b)
#
# Adapted from polarfire-soc-discovery-kit-reference-design's
# MPFS_DISCOVERY_KIT_REFERENCE_DESIGN.tcl (MIT license, see
# REFERENCE_DESIGN_LICENSE.md) -- trimmed to only the default build path
# (the reference design's ALTCONFIG variants: I2C_LOOPBACK, VECTORBLOX,
# SMARTHLS, MIV_RV32_CFGx, FIR_DEMO, AXI4_STREAM_DEMO -- are not used here).
# Reuses the *same* MSS configuration already proven to boot Linux and
# Ethernet in Fases 1-3, with one change: the Discovery Kit's 7-segment
# display SPI is replaced by mpeg2fpga at the same FIC_3 APB address slot.
# See docs/bringup/05_mss_apb_bridge_tdd.md.
#

if { $::argc > 0 } {
    foreach arg $::argv {
        if {[string match "*:*" $arg]} {
            set var [string range $arg 0 [string first ":" $arg]-1]
            set val [string range $arg [string first ":" $arg]+1 end]
            puts "Setting parameter $var to $val"
            set $var "$val"
        } else {
            set $arg 1
            puts "set $arg to 1"
        }
    }
} else {
    puts "no command line argument passed"
}

set install_loc [defvar_get -name ACTEL_SW_DIR]
set mss_config_loc "$install_loc/bin64/pfsoc_mss"
set local_dir [pwd]
set constraint_path ./script_support/constraints

set project_name "MPEG2FPGA_SOC"
set project_dir "$local_dir/$project_name"

source ./script_support/additional_configurations/functions.tcl

if { [file exists $project_dir/$project_name.prjx] } {
    puts "Open existing project"
    open_project -file $project_dir/$project_name.prjx
    open_smartdesign -sd_name {MPFS_DISCOVERY_KIT}
} else {
    puts "Creating a new project"
    new_project \
        -location $project_dir \
        -name $project_name \
        -project_description {} \
        -block_mode 0 \
        -standalone_peripheral_initialization 0 \
        -instantiate_in_smartdesign 1 \
        -ondemand_build_dh 1 \
        -use_relative_path 0 \
        -linked_files_root_dir_env {} \
        -hdl {VERILOG} \
        -family {PolarFireSoC} \
        -die {MPFS095T} \
        -package {FCSG325} \
        -speed {-1} \
        -die_voltage {1.0} \
        -part_range {EXT} \
        -adv_options {IO_DEFT_STD:LVCMOS 1.8V} \
        -adv_options {RESTRICTPROBEPINS:1} \
        -adv_options {RESTRICTSPIPINS:0} \
        -adv_options {SYSTEM_CONTROLLER_SUSPEND_MODE:0} \
        -adv_options {TEMPR:EXT} \
        -adv_options {VCCI_1.2_VOLTR:EXT} \
        -adv_options {VCCI_1.5_VOLTR:EXT} \
        -adv_options {VCCI_1.8_VOLTR:EXT} \
        -adv_options {VCCI_2.5_VOLTR:EXT} \
        -adv_options {VCCI_3.3_VOLTR:EXT} \
        -adv_options {VOLTR:EXT}

    smartdesign \
        -memory_map_drc_change_error_to_warning 1 \
        -bus_interface_data_width_drc_change_error_to_warning 1 \
        -bus_interface_id_width_drc_change_error_to_warning 1

    #
    # // Download required cores (already present in the local vault from
    # // earlier Fase 1/2 work; download_core is a no-op if already cached)
    #

    try {
        download_core -vlnv {Actel:SgCore:PF_OSC:*} -location {www.microchip-ip.com/repositories/SgCore}
        download_core -vlnv {Actel:SgCore:PF_CCC:*} -location {www.microchip-ip.com/repositories/SgCore}
        download_core -vlnv {Actel:DirectCore:CORERESET_PF:*} -location {www.microchip-ip.com/repositories/DirectCore}
        download_core -vlnv {Microsemi:SgCore:PFSOC_INIT_MONITOR:*} -location {www.microchip-ip.com/repositories/SgCore}
        download_core -vlnv {Actel:DirectCore:COREAXI4INTERCONNECT:2.9.100} -location {www.microchip-ip.com/repositories/DirectCore}
        download_core -vlnv {Actel:SgCore:PF_CLK_DIV:*} -location {www.microchip-ip.com/repositories/SgCore}
        download_core -vlnv {Actel:SgCore:PF_DRI:*} -location {www.microchip-ip.com/repositories/SgCore}
        download_core -vlnv {Actel:SgCore:PF_NGMUX:*} -location {www.microchip-ip.com/repositories/SgCore}
        download_core -vlnv {Actel:SgCore:PF_PCIE:*} -location {www.microchip-ip.com/repositories/SgCore}
        download_core -vlnv {Actel:SgCore:PF_TX_PLL:*} -location {www.microchip-ip.com/repositories/SgCore}
        download_core -vlnv {Actel:SgCore:PF_XCVR_REF_CLK:*} -location {www.microchip-ip.com/repositories/SgCore}
        download_core -vlnv {Actel:DirectCore:CoreAPB3:4.2.100} -location {www.microchip-ip.com/repositories/DirectCore}
        download_core -vlnv {Actel:DirectCore:COREAXI4DMACONTROLLER:2.2.107} -location {www.microchip-ip.com/repositories/DirectCore}
        download_core -vlnv {Actel:DirectCore:CoreGPIO:3.2.102} -location {www.microchip-ip.com/repositories/DirectCore}
        download_core -vlnv {Actel:SystemBuilder:PF_SRAM_AHBL_AXI:*} -location {www.microchip-ip.com/repositories/SgCore}
        download_core -vlnv {Actel:Simulation:CLK_GEN:*} -location {www.microchip-ip.com/repositories/SgCore}
        download_core -vlnv {Actel:Simulation:RESET_GEN:*} -location {www.microchip-ip.com/repositories/SgCore}
        download_core -vlnv {Actel:DirectCore:corepwm:4.5.100} -location {www.microchip-ip.com/repositories/DirectCore}
        download_core -vlnv {Actel:DirectCore:COREI2C:7.2.101} -location {www.microchip-ip.com/repositories/DirectCore}
        download_core -vlnv {Actel:DirectCore:CoreUARTapb:5.7.100} -location {www.microchip-ip.com/repositories/DirectCore}
        download_core -vlnv {Actel:DirectCore:CoreTimer:2.0.103} -location {www.microchip-ip.com/repositories/DirectCore}
        download_core -vlnv {Actel:DirectCore:COREJTAGDEBUG:4.0.100} -location {www.microchip-ip.com/repositories/DirectCore}
        download_core -vlnv {Actel:DirectCore:COREAXITOAHBL:3.6.101} -location {www.microchip-ip.com/repositories/DirectCore}
        download_core -vlnv {Actel:DirectCore:COREAHBTOAPB3:3.2.101} -location {www.microchip-ip.com/repositories/DirectCore}
        download_core -vlnv {Actel:DirectCore:CoreAHBLite:6.1.101} -location {www.microchip-ip.com/repositories/DirectCore}
        download_core -vlnv {Actel:DirectCore:COREFIFO:3.1.101} -location {www.microchip-ip.com/repositories/DirectCore}
        download_core -vlnv {Microchip:MiV:MIV_IHC:2.0.100} -location {www.microchip-ip.com/repositories/DirectCore}
    } on error err {
        puts "Downloading cores failed, the script will continue but will fail if all of the required cores aren't present in the vault."
    }

    #
    # // Generate and import MSS component (same config as Fases 1-3)
    #

    if {[file isdirectory $local_dir/script_support/components/MSS]} {
        file delete -force $local_dir/script_support/components/MSS
    }
    file mkdir $local_dir/script_support/components/MSS

    exec $mss_config_loc -GENERATE -CONFIGURATION_FILE:$local_dir/script_support/MPFS_DISCOVERY_KIT_MSS.cfg -OUTPUT_DIR:$local_dir/script_support/components/MSS

    import_mss_component -file "$local_dir/script_support/components/MSS/MPFS_DISCOVERY_KIT_MSS.cxz"

    #
    # // Generate base design
    #

    cd ./script_support/
    safe_source MPFS_DISCOVERY_KIT_recursive.tcl
    cd ../
    set_root -module {MPFS_DISCOVERY_KIT::work}

    #
    # // Import I/O constraints (same as reference design, minus the
    # // 7-segment display PDC -- that peripheral no longer exists here.
    # // MPFS_DISCOVERY_I2C_LOOPBACK.pdc is also deliberately NOT imported
    # // here: the reference design imports it unconditionally but only ever
    # // organizes/registers it for PLACEROUTE inside its I2C_LOOPBACK
    # // altconfig branch -- its default build, like ours, never applies it.
    # // Confirmed the hard way (Fase 5c): registering it here errors,
    # // because I2C1_SCL/I2C1_SDA (two of its four set_io lines) only exist
    # // as top-level ports when that altconfig's MSS regen sets I2C_1 to
    # // "FABRIC", which this project's MSS config never does.)
    #

    import_files \
        -convert_EDN_to_HDL 0 \
        -io_pdc "${constraint_path}/MPFS_DISCOVERY_KIT_BANK_SETTINGS.pdc" \
        -io_pdc "${constraint_path}/MPFS_DISCOVERY_KIT_BOARD_MISC.pdc" \
        -io_pdc "${constraint_path}/MPFS_DISCOVERY_MAC.pdc" \
        -io_pdc "${constraint_path}/MPFS_DISCOVERY_mikroBUS.pdc" \
        -io_pdc "${constraint_path}/MPFS_DISCOVERY_RPi.pdc" \
        -io_pdc "${constraint_path}/MPFS_DISCOVERY_UARTS.pdc" \
        -fp_pdc "${constraint_path}/SW_PLL.pdc"

    # Order matters here -- matches the reference design's own script exactly
    # (organize_tool_files immediately after import_files, before
    # build_design_hierarchy is ever called). Confirmed the hard way (Fase
    # 5c): moving this same call to run only *after* build_design_hierarchy/
    # derive_constraints_sdc (as a supposedly-equivalent unconditional
    # version further down) silently produced zero locked pins even on a
    # byte-fresh project -- "No User PDC file(s) was specified" and 0/55
    # locked, despite identical -file arguments and 0 SDC/PDC read errors.
    # apb3_mpeg2fpga_bridge_cdc.sdc is included in THIS SAME call (not a
    # separate organize_tool_files -tool {PLACEROUTE} call further down, as
    # it was before) because organize_tool_files *replaces* a tool's file
    # set rather than appending to it -- confirmed the hard way (Fase 5c):
    # this io_pdc call was correct and correctly positioned, but a second,
    # later organize_tool_files -tool {PLACEROUTE} call (registering only
    # the bridge sdc, for its own reasons) silently wiped out every one of
    # these pin-lock files, producing "No User PDC file(s) was specified"
    # and 0/55 locked pins despite this call itself having 0 errors.
    organize_tool_files \
        -tool {PLACEROUTE} \
        -file "${project_dir}/constraint/io/MPFS_DISCOVERY_KIT_BANK_SETTINGS.pdc" \
        -file "${project_dir}/constraint/io/MPFS_DISCOVERY_KIT_BOARD_MISC.pdc" \
        -file "${project_dir}/constraint/io/MPFS_DISCOVERY_MAC.pdc" \
        -file "${project_dir}/constraint/io/MPFS_DISCOVERY_mikroBUS.pdc" \
        -file "${project_dir}/constraint/io/MPFS_DISCOVERY_RPi.pdc" \
        -file "${project_dir}/constraint/io/MPFS_DISCOVERY_UARTS.pdc" \
        -file "${project_dir}/constraint/fp/SW_PLL.pdc" \
        -file "${project_dir}/constraint/apb3_mpeg2fpga_bridge_cdc.sdc" \
        -module {MPFS_DISCOVERY_KIT::work} \
        -input_type {constraint}

    build_design_hierarchy
    derive_constraints_sdc

    save_project
    sd_reset_layout -sd_name {CLOCKS_AND_RESETS}
    save_smartdesign -sd_name {CLOCKS_AND_RESETS}
    sd_reset_layout -sd_name {FIC_0_PERIPHERALS}
    save_smartdesign -sd_name {FIC_0_PERIPHERALS}
    sd_reset_layout -sd_name {CORE_I2C_C0_0_WRAPPER}
    save_smartdesign -sd_name {CORE_I2C_C0_0_WRAPPER}
    sd_reset_layout -sd_name {FIC_3_ADDRESS_GENERATION}
    save_smartdesign -sd_name {FIC_3_ADDRESS_GENERATION}
    sd_reset_layout -sd_name {FIC_3_PERIPHERALS}
    save_smartdesign -sd_name {FIC_3_PERIPHERALS}
    sd_reset_layout -sd_name {MSS_WRAPPER}
    save_smartdesign -sd_name {MSS_WRAPPER}
    sd_reset_layout -sd_name {MPFS_DISCOVERY_KIT}
    save_smartdesign -sd_name {MPFS_DISCOVERY_KIT}

    build_design_hierarchy
    derive_constraints_sdc
}

# apb3_mpeg2fpga_bridge_cdc.sdc (Fase 5a/5c) is imported as a project source
# in hdl_source.tcl, but that alone doesn't put it in any tool's constraint
# set -- same as the io_pdc files above, it has to be explicitly organized
# in per tool, or that tool never applies its false-path exceptions.
# PLACEROUTE is deliberately NOT registered here -- it's combined into the
# single io_pdc organize_tool_files call above instead, since a second call
# for the same tool replaces rather than appends to its file set (see the
# comment above that call). VERIFYTIMING still needs its own registration
# here: PLACEROUTE consumes this file into place_route.sdc for its own
# timing-driven placement, but the *separate* consolidated file that the
# Verify Timing step actually reports violations against (designer/.../
# timing_analysis.sdc) is built from a DIFFERENT, independently-registered
# constraint set -- without this registration, timing_analysis.sdc silently
# omits this file entirely (confirmed by grepping it) and every violation
# report keeps showing the exact same u_bridge/apb_addr_r-sourced violations
# regardless of the SDC content or the PLACEROUTE registration being
# correct. Both organize_tool_files calls below are outside the
# fresh-project if/else above so they also take effect on an
# already-existing project when only SYNTHESIZE/VERIFY_TIMING is re-run.
organize_tool_files \
    -tool {SYNTHESIZE} \
    -file "${project_dir}/constraint/apb3_mpeg2fpga_bridge_cdc.sdc" \
    -module {MPFS_DISCOVERY_KIT::work} \
    -input_type {constraint}

organize_tool_files \
    -tool {VERIFYTIMING} \
    -file "${project_dir}/constraint/apb3_mpeg2fpga_bridge_cdc.sdc" \
    -module {MPFS_DISCOVERY_KIT::work} \
    -input_type {constraint}

configure_tool \
         -name {CONFIGURE_PROG_OPTIONS} \
         -params {back_level_version:0} \
         -params design_version:0 \
         -params silicon_signature:D15C0417

# Multi-pass layout (5-seed search for best worst-slack) was needed while
# u_bridge/apb_addr_r-sourced CDC violations were unresolved (Fase 5c). Now
# that the false-path sdc is correctly registered for VERIFYTIMING too (see
# organize_tool_files above) and a single deterministic pass already meets
# timing with zero violations ("No Path" in the max-delay violation report),
# multi-pass search is unnecessary -- and actively breaks a clean run: when
# the first pass has zero violations, Libero's multi-pass wrapper script
# fails trying to compare an empty violations report against other passes
# ("Multi-Pass: Analysis using specified comparison criteria failed"),
# marking run_tool as failed even though placement/routing itself succeeded.
# Plain single-pass PLACEROUTE avoids that wrapper entirely.
configure_tool -name {PLACEROUTE} -params {DELAY_ANALYSIS:MAX} -params {EFFORT_LEVEL:true} -params {GB_DEMOTION:true} -params {INCRPLACEANDROUTE:false} -params {IOREG_COMBINING:false} -params {MULTI_PASS_CRITERIA:VIOLATIONS} -params {MULTI_PASS_LAYOUT:false} -params {NUM_MULTI_PASSES:1} -params {PDPR:false} -params {RANDOM_SEED:0} -params {REPAIR_MIN_DELAY:true} -params {REPLICATION:false} -params {SLACK_CRITERIA:WORST_SLACK} -params {SPECIFIC_CLOCK:} -params {START_SEED_INDEX:1} -params {STOP_ON_FIRST_PASS:true} -params {TDPR:true}

# COREFIFO's own auto-generated SDC (Fase 5c) emits a set_false_path -to
# [get_cells {...shift_reg*}] wildcard for its Gray-code CDC synchronizer,
# templated for its largest configured depth. For the two smaller instances
# xfifo_dc.v uses (fifo_mem_req_dc_88x64, fifo_mem_rsp_dc_64x128), synthesis
# optimizes away the specific shift_reg bits that wildcard expects (BN132
# "equivalent instance" collapses, harmless), so the pattern matches zero
# cells post-synthesis. The constraint's *intent* (don't time the CDC
# synchronizer's internal settling path) is still met regardless -- only
# disable the hard-abort so P&R treats the empty match as a no-op instead of
# a fatal error, matching how this is normally handled for vendor IP timing
# exceptions that don't survive a specific optimization outcome.
project_settings -abort_flow_on_sdc_errors {FALSE}

if {[info exists SYNTHESIZE]} {
    run_tool -name {SYNTHESIZE}
} elseif {[info exists PLACEROUTE]} {
    run_tool -name {PLACEROUTE}
} elseif {[info exists VERIFY_TIMING]} {
    run_tool -name {VERIFYTIMING}
}

# Fase 5c debug: our project never touched eNVM (GENERATEPROGRAMMINGDATA /
# EXPORT_FPE only ever included "FABRIC SNVM" components, matching the
# reference design's own DEFAULT behavior -- HSS_UPDATE is opt-in there too).
# But the .job we've been using as our hardware "known good" control
# (~/Proyectos/polarfire-soc-discovery-kit-reference-design/programming_job/
# MPFS_DISCOVERY.job, from Microchip's official MPFS_DISCOVERY_KIT_2026_04.zip
# release) *does* bundle "bitstream + HSS v2026.04.1" per the release notes --
# i.e. it was built WITH HSS_UPDATE, so its eNVM was freshly written with a
# known HSS at the same time as its fabric. Our board's eNVM currently still
# holds whatever HSS was there from that last official-job flash, now paired
# with a *different* fabric build (ours) that never confirmed compatibility.
# Mirrors the reference design's HSS_UPDATE block verbatim so eNVM gets
# refreshed with the exact same official HSS our fabric is meant to pair with.
if {[info exists HSS_UPDATE]} {
    if !{[file exists "./script_support/hss-envm-wrapper.mpfs-disco-kit.hex"]} {
        if {[catch {exec wget https://github.com/polarfire-soc/hart-software-services/releases/latest/download/hss-envm-wrapper.mpfs-disco-kit.hex -P ./script_support/} issue]} {
        }
    }
    create_eNVM_config "$local_dir/script_support/components/MSS/ENVM.cfg" "$local_dir/script_support/hss-envm-wrapper.mpfs-disco-kit.hex"
    run_tool -name {GENERATEPROGRAMMINGDATA}
    configure_envm -cfg_file {script_support/components/MSS/ENVM.cfg}
}

if {[info exists GENERATE_PROGRAMMING_DATA]} {
    run_tool -name {GENERATEPROGRAMMINGDATA}
} elseif {[info exists PROGRAM]} {
    run_tool -name {PROGRAMDEVICE}
} elseif {[info exists EXPORT_FPE]} {
    # GENERATEPROGRAMMINGDATA only builds the internal FPGA array data --
    # the standalone .job file FlashPro Express/FlashPro6 actually load onto
    # the board is a separate export step (confirmed against the reference
    # design's EXPORT_FPE branch, MPFS_DISCOVERY_KIT_REFERENCE_DESIGN.tcl).
    set gUseSPI 0

    set jobPath $local_dir
    if {[file isdirectory $EXPORT_FPE]} {set jobPath $EXPORT_FPE}

    set components "FABRIC SNVM"
    if {[info exists HSS_UPDATE]} { set components "$components ENVM" }

    puts "export_fpe_job $project_name $jobPath $components $gUseSPI"
    export_fpe_job $project_name $jobPath $components $gUseSPI
}

save_project

puts "TCL_END: [info script]"
