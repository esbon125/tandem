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
#
# Fase 7a (2026-08-23) TEMPORARY EXPERIMENT: re-enabling this to capture
# Libero's exact rejection message, now that the per-signal bypass above is
# the prime suspect for why m_axi_awready never arrives on real hardware
# (mem2axi_bridge's AXI write FSM never completes a single transaction).
# REVERT after reading the error -- this is not meant to stay enabled.
hdl_core_add_bif -hdl_core_name {mpeg2fpga_apb_peripheral} -bif_definition {AXI4:AMBA:AMBA4:mirroredSlave} -bif_name {mem_axi_bif} -signal_map {\
"AWID:m_axi_awid" \
"AWADDR:m_axi_awaddr" \
"AWLEN:m_axi_awlen" \
"AWSIZE:m_axi_awsize" \
"AWBURST:m_axi_awburst" \
"AWLOCK:m_axi_awlock" \
"AWCACHE:m_axi_awcache" \
"AWPROT:m_axi_awprot" \
"AWQOS:m_axi_awqos" \
"AWREGION:m_axi_awregion" \
"AWUSER:m_axi_awuser" \
"AWVALID:m_axi_awvalid" \
"AWREADY:m_axi_awready" \
"WDATA:m_axi_wdata" \
"WSTRB:m_axi_wstrb" \
"WLAST:m_axi_wlast" \
"WUSER:m_axi_wuser" \
"WVALID:m_axi_wvalid" \
"WREADY:m_axi_wready" \
"BID:m_axi_bid" \
"BRESP:m_axi_bresp" \
"BUSER:m_axi_buser" \
"BVALID:m_axi_bvalid" \
"BREADY:m_axi_bready" \
"ARID:m_axi_arid" \
"ARADDR:m_axi_araddr" \
"ARLEN:m_axi_arlen" \
"ARSIZE:m_axi_arsize" \
"ARBURST:m_axi_arburst" \
"ARLOCK:m_axi_arlock" \
"ARCACHE:m_axi_arcache" \
"ARPROT:m_axi_arprot" \
"ARQOS:m_axi_arqos" \
"ARREGION:m_axi_arregion" \
"ARUSER:m_axi_aruser" \
"ARVALID:m_axi_arvalid" \
"ARREADY:m_axi_arready" \
"RID:m_axi_rid" \
"RDATA:m_axi_rdata" \
"RRESP:m_axi_rresp" \
"RLAST:m_axi_rlast" \
"RUSER:m_axi_ruser" \
"RVALID:m_axi_rvalid" \
"RREADY:m_axi_rready" }
