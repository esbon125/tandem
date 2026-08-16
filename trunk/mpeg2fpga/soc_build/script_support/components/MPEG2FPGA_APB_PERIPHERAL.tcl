# Register mpeg2fpga_apb_peripheral.v (rtl/mpeg2/mpeg2fpga_apb_peripheral.v)
# as a Libero HDL+ core with an APB3 slave bus interface, following the same
# pattern as components/APB_ARBITER.tcl (a plain user Verilog module, not a
# vendor DirectCore IP). See docs/bringup/05_mss_apb_bridge_tdd.md.
create_hdl_core -file {hdl/mpeg2fpga_apb_peripheral.v} -module {mpeg2fpga_apb_peripheral} -library {work} -package {}
hdl_core_add_bif -hdl_core_name {mpeg2fpga_apb_peripheral} -bif_definition {APB:AMBA:AMBA2:slave} -bif_name {APB_bif} -signal_map {\
"PADDR:PADDR" \
"PENABLE:PENABLE" \
"PWRITE:PWRITE" \
"PRDATA:PRDATA" \
"PWDATA:PWDATA" \
"PREADY:PREADY" \
"PSELx:PSEL" }

# Fase 6b: mem2axi_bridge's AXI4 master (m_axi_* ports on this HDL module)
# is deliberately NOT registered as an hdl_core_add_bif bus interface here.
# It was originally (bif "AXI4:AMBA:AMBA4:master"), but Libero's bus-
# interface compatibility check rejected connecting it -- as
# master/mirroredMaster/mirroredSlave alike -- to a boundary bif port of
# the same AMBA:AMBA4:AXI4:r0p0_0 busdef, for reasons that didn't resolve
# from Libero's Tcl reference docs or the working catalog-IP precedent
# (FIC_0_PERIPHERALS.tcl's AXI4mslave0/AXI4mmaster0, sourced from actual
# DirectCore IP, not an hdl_core_add_bif core). FIC_3_PERIPHERALS.tcl
# connects each m_axi_* pin individually instead (plain sd_connect_pins,
# which only checks pin width, not bus-interface type) -- see the "Note"
# comment there.
