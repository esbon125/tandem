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
    # // 7-segment display PDC -- that peripheral no longer exists here)
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

    organize_tool_files \
        -tool {PLACEROUTE} \
        -file "${project_dir}/constraint/io/MPFS_DISCOVERY_KIT_BANK_SETTINGS.pdc" \
        -file "${project_dir}/constraint/io/MPFS_DISCOVERY_KIT_BOARD_MISC.pdc" \
        -file "${project_dir}/constraint/io/MPFS_DISCOVERY_MAC.pdc" \
        -file "${project_dir}/constraint/io/MPFS_DISCOVERY_mikroBUS.pdc" \
        -file "${project_dir}/constraint/io/MPFS_DISCOVERY_RPi.pdc" \
        -file "${project_dir}/constraint/io/MPFS_DISCOVERY_UARTS.pdc" \
        -file "${project_dir}/constraint/fp/SW_PLL.pdc" \
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

configure_tool \
         -name {CONFIGURE_PROG_OPTIONS} \
         -params {back_level_version:0} \
         -params design_version:0 \
         -params silicon_signature:D15C0417

configure_tool -name {PLACEROUTE} -params {DELAY_ANALYSIS:MAX} -params {EFFORT_LEVEL:true} -params {GB_DEMOTION:true} -params {INCRPLACEANDROUTE:false} -params {IOREG_COMBINING:false} -params {MULTI_PASS_CRITERIA:VIOLATIONS} -params {MULTI_PASS_LAYOUT:true} -params {NUM_MULTI_PASSES:5} -params {PDPR:false} -params {RANDOM_SEED:0} -params {REPAIR_MIN_DELAY:true} -params {REPLICATION:false} -params {SLACK_CRITERIA:WORST_SLACK} -params {SPECIFIC_CLOCK:} -params {START_SEED_INDEX:1} -params {STOP_ON_FIRST_PASS:true} -params {TDPR:true}

if {[info exists SYNTHESIZE]} {
    run_tool -name {SYNTHESIZE}
} elseif {[info exists PLACEROUTE]} {
    run_tool -name {PLACEROUTE}
} elseif {[info exists VERIFY_TIMING]} {
    run_tool -name {VERIFYTIMING}
}

if {[info exists GENERATE_PROGRAMMING_DATA]} {
    run_tool -name {GENERATEPROGRAMMINGDATA}
} elseif {[info exists PROGRAM]} {
    run_tool -name {PROGRAMDEVICE}
}

save_project

puts "TCL_END: [info script]"
