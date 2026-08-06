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
