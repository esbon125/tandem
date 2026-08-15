puts "TCL_BEGIN: [info script]"

#
# Fase 5c debug isolation test: does the board still boot-loop (hangs right
# after "Initializing Mi-V IHC V2" in the HSS console, MPFS_DISCOVERY_KIT_MSS
# reset-looping) with mpeg2fpga_apb_peripheral removed from FIC_3_PERIPHERALS'
# slot 4? Static netlist review found no smoking gun in the MSS_INT_F2M
# bit-slicing or the shared APB bus wiring, so this rules the peripheral
# in/out empirically instead. NOT part of the normal build flow -- run once,
# standalone, against the already-built MPEG2FPGA_SOC project.
#
# Reverts to a truly empty slot (no core reinstantiated in place of
# mpeg2fpga_apb_peripheral) rather than restoring the original 7-segment SPI,
# to isolate exactly one variable (our new peripheral's presence) instead of
# also reintroducing the old SPI core as a second variable.
#

set local_dir [pwd]
set project_name "MPEG2FPGA_SOC"
set project_dir "$local_dir/$project_name"

open_project -file $project_dir/$project_name.prjx
open_smartdesign -sd_name {FIC_3_PERIPHERALS}

sd_connect_pins_to_constant -sd_name {FIC_3_PERIPHERALS} -pin_names {MPEG2FPGA_INTERRUPT} -value {GND}

save_smartdesign -sd_name {FIC_3_PERIPHERALS}
generate_component -component_name {FIC_3_PERIPHERALS}

build_design_hierarchy
save_project

puts "TCL_END: [info script]"
