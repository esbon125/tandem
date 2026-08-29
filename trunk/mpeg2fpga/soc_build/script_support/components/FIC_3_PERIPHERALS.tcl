# Creating SmartDesign FIC_3_PERIPHERALS
set sd_name {FIC_3_PERIPHERALS}
create_smartdesign -sd_name ${sd_name}

# Disable auto promotion of pins of type 'pad'
auto_promote_pad_pins -promote_all 0

# Create top level Scalar Ports
sd_create_scalar_port -sd_name ${sd_name} -port_name {APB_MMASTER_in_penable} -port_direction {IN}
sd_create_scalar_port -sd_name ${sd_name} -port_name {APB_MMASTER_in_psel} -port_direction {IN}
sd_create_scalar_port -sd_name ${sd_name} -port_name {APB_MMASTER_in_pwrite} -port_direction {IN}
sd_create_scalar_port -sd_name ${sd_name} -port_name {CoreUARTapb_RX} -port_direction {IN}
sd_create_scalar_port -sd_name ${sd_name} -port_name {PCLK} -port_direction {IN}
sd_create_scalar_port -sd_name ${sd_name} -port_name {PLL0_SW_DRI_INTERRUPT} -port_direction {IN}
sd_create_scalar_port -sd_name ${sd_name} -port_name {PRESETN} -port_direction {IN}
sd_create_scalar_port -sd_name ${sd_name} -port_name {REF_CLK_MPEG2FPGA} -port_direction {IN}

sd_create_scalar_port -sd_name ${sd_name} -port_name {APB_MMASTER_in_pready} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {APB_MMASTER_in_pslverr} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {CORE_I2C_C0_INT} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {CoreUARTapb_TX} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {FRAMING_ERR} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {OVERFLOW} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {PARITY_ERR} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {RXRDY} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {TXRDY} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {IHC_MP_APP_E51_IRQ} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {IHC_MP_APP_U54_1_IRQ} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {IHC_MP_APP_U54_2_IRQ} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {IHC_MP_APP_U54_3_IRQ} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {IHC_MP_APP_U54_4_IRQ} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {PWM_0} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {Q0_LANE0_DRI_DRI_ARST_N} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {Q0_LANE0_DRI_DRI_CLK} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {MPEG2FPGA_INTERRUPT} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {MEM_CLK_MPEG2FPGA} -port_direction {OUT}
# Fase 7c: mpeg2fpga_apb_peripheral's core_clk (clk_out), promoted so
# MPFS_DISCOVERY_KIT.tcl can feed the same clock into FIC_2_ACLK for
# u_stream_dma's AXI4 master -- same reasoning as MEM_CLK_MPEG2FPGA/FIC_1
# above, see rtl/mpeg2/stream_dma.v's header comment.
sd_create_scalar_port -sd_name ${sd_name} -port_name {CORE_CLK_MPEG2FPGA} -port_direction {OUT}

sd_create_scalar_port -sd_name ${sd_name} -port_name {COREI2C_C0_SCL} -port_direction {INOUT} -port_is_pad {1}
sd_create_scalar_port -sd_name ${sd_name} -port_name {COREI2C_C0_SDA} -port_direction {INOUT} -port_is_pad {1}

# Fase 7a (2026-08-23) EXPERIMENT: the Fase 6b comment here previously
# claimed "bif role is mirroredMaster" -- but AWVALID/ARVALID etc. below
# are OUT and AWREADY/ARREADY are IN, i.e. plain master-like directions.
# Per the WORKING precedent (FIC_0_PERIPHERALS.tcl's AXI4mslave0, which
# bubbles DMA_CONTROLLER's AXI4 master up to MSS_WRAPPER_0:FIC_0_AXI4_TARGET,
# role "slave"), a master-direction pass-through boundary port needs role
# "mirroredSlave", not "mirroredMaster" -- mirroredMaster has slave-like
# directions (AWVALID in, AWREADY out), which does not match these ports at
# all. That mismatch is the leading suspect for the original "not
# compatible" rejection this Fase 6b comment described. Testing the
# corrected role now via a real bif (previously this was never actually
# tried as a bif -- MEM_AXI_* were always plain per-signal ports).
# sd_create_bif_port only GROUPS already-existing ports into a bif -- it
# does not auto-create them (confirmed against FIC_0_PERIPHERALS.tcl's
# AXI4mslave0 precedent, whose SLAVE0_* ports are each separately declared
# via sd_create_scalar_port/sd_create_bus_port before its own
# sd_create_bif_port call). Declare the underlying ports first.
sd_create_scalar_port -sd_name ${sd_name} -port_name {MEM_AXI_AWVALID} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {MEM_AXI_AWREADY} -port_direction {IN}
sd_create_scalar_port -sd_name ${sd_name} -port_name {MEM_AXI_WVALID} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {MEM_AXI_WREADY} -port_direction {IN}
sd_create_scalar_port -sd_name ${sd_name} -port_name {MEM_AXI_WLAST} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {MEM_AXI_BVALID} -port_direction {IN}
sd_create_scalar_port -sd_name ${sd_name} -port_name {MEM_AXI_BREADY} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {MEM_AXI_ARVALID} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {MEM_AXI_ARREADY} -port_direction {IN}
sd_create_scalar_port -sd_name ${sd_name} -port_name {MEM_AXI_RVALID} -port_direction {IN}
sd_create_scalar_port -sd_name ${sd_name} -port_name {MEM_AXI_RREADY} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {MEM_AXI_RLAST} -port_direction {IN}
sd_create_scalar_port -sd_name ${sd_name} -port_name {MEM_AXI_AWLOCK} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {MEM_AXI_ARLOCK} -port_direction {OUT}

sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_AWID} -port_direction {OUT} -port_range {[3:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_AWADDR} -port_direction {OUT} -port_range {[37:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_AWLEN} -port_direction {OUT} -port_range {[7:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_AWSIZE} -port_direction {OUT} -port_range {[2:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_AWBURST} -port_direction {OUT} -port_range {[1:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_AWCACHE} -port_direction {OUT} -port_range {[3:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_AWPROT} -port_direction {OUT} -port_range {[2:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_AWQOS} -port_direction {OUT} -port_range {[3:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_WDATA} -port_direction {OUT} -port_range {[63:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_WSTRB} -port_direction {OUT} -port_range {[7:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_BID} -port_direction {IN} -port_range {[3:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_BRESP} -port_direction {IN} -port_range {[1:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_ARID} -port_direction {OUT} -port_range {[3:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_ARADDR} -port_direction {OUT} -port_range {[37:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_ARLEN} -port_direction {OUT} -port_range {[7:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_ARSIZE} -port_direction {OUT} -port_range {[2:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_ARBURST} -port_direction {OUT} -port_range {[1:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_ARCACHE} -port_direction {OUT} -port_range {[3:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_ARPROT} -port_direction {OUT} -port_range {[2:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_ARQOS} -port_direction {OUT} -port_range {[3:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_RID} -port_direction {IN} -port_range {[3:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_RDATA} -port_direction {IN} -port_range {[63:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {MEM_AXI_RRESP} -port_direction {IN} -port_range {[1:0]}

sd_create_bif_port -sd_name ${sd_name} -port_name {MEM_AXI_MIRROREDSLAVE} -port_bif_vlnv {AMBA:AMBA4:AXI4:r0p0_0} -port_bif_role {mirroredSlave} -port_bif_mapping {\
"AWID:MEM_AXI_AWID" \
"AWADDR:MEM_AXI_AWADDR" \
"AWLEN:MEM_AXI_AWLEN" \
"AWSIZE:MEM_AXI_AWSIZE" \
"AWBURST:MEM_AXI_AWBURST" \
"AWLOCK:MEM_AXI_AWLOCK" \
"AWCACHE:MEM_AXI_AWCACHE" \
"AWPROT:MEM_AXI_AWPROT" \
"AWQOS:MEM_AXI_AWQOS" \
"AWVALID:MEM_AXI_AWVALID" \
"AWREADY:MEM_AXI_AWREADY" \
"WDATA:MEM_AXI_WDATA" \
"WSTRB:MEM_AXI_WSTRB" \
"WLAST:MEM_AXI_WLAST" \
"WVALID:MEM_AXI_WVALID" \
"WREADY:MEM_AXI_WREADY" \
"BID:MEM_AXI_BID" \
"BRESP:MEM_AXI_BRESP" \
"BVALID:MEM_AXI_BVALID" \
"BREADY:MEM_AXI_BREADY" \
"ARID:MEM_AXI_ARID" \
"ARADDR:MEM_AXI_ARADDR" \
"ARLEN:MEM_AXI_ARLEN" \
"ARSIZE:MEM_AXI_ARSIZE" \
"ARBURST:MEM_AXI_ARBURST" \
"ARLOCK:MEM_AXI_ARLOCK" \
"ARCACHE:MEM_AXI_ARCACHE" \
"ARPROT:MEM_AXI_ARPROT" \
"ARQOS:MEM_AXI_ARQOS" \
"ARVALID:MEM_AXI_ARVALID" \
"ARREADY:MEM_AXI_ARREADY" \
"RID:MEM_AXI_RID" \
"RDATA:MEM_AXI_RDATA" \
"RRESP:MEM_AXI_RRESP" \
"RLAST:MEM_AXI_RLAST" \
"RVALID:MEM_AXI_RVALID" \
"RREADY:MEM_AXI_RREADY" }

# Fase 7c: u_stream_dma's AXI4 read-only master, bubbled up the same way
# MEM_AXI_* is above -- a second, independent fabric-master path into DDR
# (FIC_2_AXI4_TARGET at the MPFS_DISCOVERY_KIT top), no AW/W/B channels
# since stream_dma.v never writes DDR.
sd_create_scalar_port -sd_name ${sd_name} -port_name {DMA_AXI_ARVALID} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {DMA_AXI_ARREADY} -port_direction {IN}
sd_create_scalar_port -sd_name ${sd_name} -port_name {DMA_AXI_RVALID} -port_direction {IN}
sd_create_scalar_port -sd_name ${sd_name} -port_name {DMA_AXI_RREADY} -port_direction {OUT}
sd_create_scalar_port -sd_name ${sd_name} -port_name {DMA_AXI_RLAST} -port_direction {IN}

# Create top level Bus Ports
sd_create_bus_port -sd_name ${sd_name} -port_name {APB_MMASTER_in_paddr} -port_direction {IN} -port_range {[31:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {APB_MMASTER_in_pwdata} -port_direction {IN} -port_range {[31:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {PLL0_SW_DRI_RDATA} -port_direction {IN} -port_range {[32:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {PSTRB} -port_direction {IN} -port_range {[3:0]}

sd_create_bus_port -sd_name ${sd_name} -port_name {APB_MMASTER_in_prdata} -port_direction {OUT} -port_range {[31:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {GPIO_OUT} -port_direction {OUT} -port_range {[6:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {PLL0_SW_DRI_CTRL} -port_direction {OUT} -port_range {[10:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {Q0_LANE0_DRI_DRI_WDATA} -port_direction {OUT} -port_range {[32:0]}

sd_create_bus_port -sd_name ${sd_name} -port_name {DMA_AXI_ARID} -port_direction {OUT} -port_range {[3:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {DMA_AXI_ARADDR} -port_direction {OUT} -port_range {[37:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {DMA_AXI_ARLEN} -port_direction {OUT} -port_range {[7:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {DMA_AXI_ARSIZE} -port_direction {OUT} -port_range {[2:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {DMA_AXI_ARBURST} -port_direction {OUT} -port_range {[1:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {DMA_AXI_RID} -port_direction {IN} -port_range {[3:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {DMA_AXI_RDATA} -port_direction {IN} -port_range {[63:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {DMA_AXI_RRESP} -port_direction {IN} -port_range {[1:0]}

# AXI4 sideband signals actually implemented by MSS_WRAPPER's
# FIC_1_AXI4_TARGET (see rtl/mpeg2/mem2axi_bridge.v's port list comment).
# AWREGION/ARREGION and all *USER signals are NOT implemented there (not
# even present as ports on MSS_WRAPPER, confirmed against MSS_WRAPPER.tcl)
# -- same reduced subset the working FIC_0_AXI4_TARGET connection uses.
# MEM_AXI_AWLOCK/AWCACHE/AWPROT/AWQOS/ARLOCK/ARCACHE/ARPROT/ARQOS are now
# created as part of the MEM_AXI_MIRROREDSLAVE bif above (matching
# FIC_1_AXI4_TARGET's own mapping exactly), not declared separately here.
sd_create_scalar_port -sd_name ${sd_name} -port_name {DMA_AXI_ARLOCK} -port_direction {OUT}
sd_create_bus_port -sd_name ${sd_name} -port_name {DMA_AXI_ARCACHE} -port_direction {OUT} -port_range {[3:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {DMA_AXI_ARPROT} -port_direction {OUT} -port_range {[2:0]}
sd_create_bus_port -sd_name ${sd_name} -port_name {DMA_AXI_ARQOS} -port_direction {OUT} -port_range {[3:0]}

# Create top level Bus interface Ports
sd_create_bif_port -sd_name ${sd_name} -port_name {PLL0_SW_DRI} -port_bif_vlnv {Actel:busdef.dri:PF_DRI:1.0} -port_bif_role {mirroredSlave} -port_bif_mapping {\
"DRI_CLK:Q0_LANE0_DRI_DRI_CLK" \
"DRI_ARST_N:Q0_LANE0_DRI_DRI_ARST_N" \
"DRI_CTRL:PLL0_SW_DRI_CTRL" \
"DRI_RDATA:PLL0_SW_DRI_RDATA" \
"DRI_WDATA:Q0_LANE0_DRI_DRI_WDATA" \
"DRI_INTERRUPT:PLL0_SW_DRI_INTERRUPT" }

sd_create_bif_port -sd_name ${sd_name} -port_name {APB_MMASTER} -port_bif_vlnv {AMBA:AMBA2:APB:r0p0} -port_bif_role {mirroredMaster} -port_bif_mapping {\
"PADDR:APB_MMASTER_in_paddr" \
"PSELx:APB_MMASTER_in_psel" \
"PENABLE:APB_MMASTER_in_penable" \
"PWRITE:APB_MMASTER_in_pwrite" \
"PRDATA:APB_MMASTER_in_prdata" \
"PWDATA:APB_MMASTER_in_pwdata" \
"PREADY:APB_MMASTER_in_pready" \
"PSLVERR:APB_MMASTER_in_pslverr" }

# Note: mem2axi_bridge's AXI4 master (Fase 6b) was originally NOT wrapped
# in an sd_create_bif_port here -- an earlier attempt to declare
# MPEG2FPGA_APB_PERIPHERAL_0:mem_axi_bif via hdl_core_add_bif reportedly
# got "not compatible" against every role tried (master/mirroredMaster/
# mirroredSlave) when connecting to a boundary bif port of the same
# AMBA:AMBA4:AXI4:r0p0_0 busdef, for reasons that were never pinned down.
# Fase 7a (2026-08-23): retrying with role mirroredSlave (matching the
# working catalog-IP precedent, FIC_0_PERIPHERALS.tcl's AXI4mslave0, whose
# port directions -- AWVALID out/AWREADY in, same as MEM_AXI_* here -- also
# use mirroredSlave, not mirroredMaster) via MEM_AXI_MIRROREDSLAVE above.
# If this still reports "not compatible", the original comment's claim of
# having tried every role stands and the incompatibility is unrelated to
# role choice; if it works, the original attempt likely used the wrong role.
# u_stream_dma's DMA_AXI_* below is unrelated and still per-signal.

# Add CORE_I2C_C0_0_WRAPPER_1 instance
sd_instantiate_component -sd_name ${sd_name} -component_name {CORE_I2C_C0_0_WRAPPER} -instance_name {CORE_I2C_C0_0_WRAPPER_1}



# Add COREGPIO_C0 instance
sd_instantiate_component -sd_name ${sd_name} -component_name {GPIO} -instance_name {COREGPIO_C0}
sd_mark_pins_unused -sd_name ${sd_name} -pin_names {COREGPIO_C0:INT}
sd_connect_pins_to_constant -sd_name ${sd_name} -pin_names {COREGPIO_C0:GPIO_IN} -value {GND}



# Add CoreUARTapb_C0_0 instance
sd_instantiate_component -sd_name ${sd_name} -component_name {CoreUARTapb_C0} -instance_name {CoreUARTapb_C0_0}



# Add FIC_3_ADDRESS_GENERATION_1 instance
sd_instantiate_component -sd_name ${sd_name} -component_name {FIC_3_ADDRESS_GENERATION} -instance_name {FIC_3_ADDRESS_GENERATION_1}



# Add MIV_IHC_C0_0 instance
sd_instantiate_component -sd_name ${sd_name} -component_name {MIV_IHC_C0} -instance_name {MIV_IHC_C0_0}



# Add PWM instance
sd_instantiate_component -sd_name ${sd_name} -component_name {corepwm_C0} -instance_name {PWM}
sd_create_pin_slices -sd_name ${sd_name} -pin_name {PWM:PWM} -pin_slices {[0:0]}



# Add RECONFIGURATION_INTERFACE_0 instance
sd_instantiate_component -sd_name ${sd_name} -component_name {RECONFIGURATION_INTERFACE} -instance_name {RECONFIGURATION_INTERFACE_0}
sd_mark_pins_unused -sd_name ${sd_name} -pin_names {RECONFIGURATION_INTERFACE_0:PINTERRUPT}
sd_mark_pins_unused -sd_name ${sd_name} -pin_names {RECONFIGURATION_INTERFACE_0:PTIMEOUT}
sd_mark_pins_unused -sd_name ${sd_name} -pin_names {RECONFIGURATION_INTERFACE_0:BUSERROR}



# Add MPEG2FPGA_APB_PERIPHERAL_0 instance (Fase 5b: replaces the Discovery
# Kit's 7-segment display SPI, unused by this project, at the same FIC_3
# APB address slot -- see docs/bringup/05_mss_apb_bridge_tdd.md)
sd_instantiate_hdl_core -sd_name ${sd_name} -hdl_core_name {mpeg2fpga_apb_peripheral} -instance_name {MPEG2FPGA_APB_PERIPHERAL_0}
# BUSER/RUSER are AXI4 *inputs* mem2axi_bridge never reads (see
# rtl/mpeg2/mem2axi_bridge.v's port list comment) -- MSS_WRAPPER's
# FIC_1_AXI4_TARGET doesn't implement them at all, so they're never
# promoted past this level (unlike the AWREGION/ARREGION/AWUSER/WUSER/
# ARUSER *outputs*, which Libero is happy to leave floating).
sd_connect_pins_to_constant -sd_name ${sd_name} -pin_names {MPEG2FPGA_APB_PERIPHERAL_0:m_axi_buser} -value {GND}
sd_connect_pins_to_constant -sd_name ${sd_name} -pin_names {MPEG2FPGA_APB_PERIPHERAL_0:m_axi_ruser} -value {GND}
# Fase 7c: same reasoning, dma_axi_ruser (no dma_axi_buser -- read-only master)
sd_connect_pins_to_constant -sd_name ${sd_name} -pin_names {MPEG2FPGA_APB_PERIPHERAL_0:dma_axi_ruser} -value {GND}



# Add scalar net connections
sd_connect_pins -sd_name ${sd_name} -pin_names {"COREGPIO_C0:PCLK" "CORE_I2C_C0_0_WRAPPER_1:PCLK" "CoreUARTapb_C0_0:PCLK" "MIV_IHC_C0_0:APB_0_PCLK" "MIV_IHC_C0_0:CORE_CLK" "PCLK" "PWM:PCLK" "RECONFIGURATION_INTERFACE_0:PCLK" "MPEG2FPGA_APB_PERIPHERAL_0:PCLK" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"COREGPIO_C0:PRESETN" "CORE_I2C_C0_0_WRAPPER_1:PRESETN" "CoreUARTapb_C0_0:PRESETN" "MIV_IHC_C0_0:APB_0_PRESETN" "MIV_IHC_C0_0:CORE_RESETN" "PRESETN" "PWM:PRESETN" "RECONFIGURATION_INTERFACE_0:PRESETN" "MPEG2FPGA_APB_PERIPHERAL_0:PRESETn" "MPEG2FPGA_APB_PERIPHERAL_0:rst_n" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"MPEG2FPGA_APB_PERIPHERAL_0:ref_clk" "REF_CLK_MPEG2FPGA" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"COREI2C_C0_SCL" "CORE_I2C_C0_0_WRAPPER_1:COREI2C_C0_SCL" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"COREI2C_C0_SDA" "CORE_I2C_C0_0_WRAPPER_1:COREI2C_C0_SDA" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"CORE_I2C_C0_0_WRAPPER_1:INT" "CORE_I2C_C0_INT" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"CoreUARTapb_C0_0:FRAMING_ERR" "FRAMING_ERR" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"CoreUARTapb_C0_0:OVERFLOW" "OVERFLOW" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"CoreUARTapb_C0_0:PARITY_ERR" "PARITY_ERR" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"CoreUARTapb_C0_0:RXRDY" "RXRDY" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"CoreUARTapb_C0_0:TXRDY" "TXRDY" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"CoreUARTapb_C0_0:RX" "CoreUARTapb_RX" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"CoreUARTapb_C0_0:TX" "CoreUARTapb_TX" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"IHC_MP_APP_E51_IRQ" "MIV_IHC_C0_0:APP_IRQ_H0" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"IHC_MP_APP_U54_1_IRQ" "MIV_IHC_C0_0:APP_IRQ_H1" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"IHC_MP_APP_U54_2_IRQ" "MIV_IHC_C0_0:APP_IRQ_H2" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"IHC_MP_APP_U54_3_IRQ" "MIV_IHC_C0_0:APP_IRQ_H3" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"IHC_MP_APP_U54_4_IRQ" "MIV_IHC_C0_0:APP_IRQ_H4" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"PWM:PWM[0:0]" "PWM_0" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"MPEG2FPGA_INTERRUPT" "MPEG2FPGA_APB_PERIPHERAL_0:interrupt" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"MEM_CLK_MPEG2FPGA" "MPEG2FPGA_APB_PERIPHERAL_0:mem_clk_out" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"CORE_CLK_MPEG2FPGA" "MPEG2FPGA_APB_PERIPHERAL_0:clk_out" }

# Add bus net connections
sd_connect_pins -sd_name ${sd_name} -pin_names {"COREGPIO_C0:GPIO_OUT" "GPIO_OUT" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"PSTRB" "RECONFIGURATION_INTERFACE_0:PSTRB" }
# Fase 7c PWDATA investigation: PSTRB is a broadcast signal (same value for
# every APB slave regardless of which is selected, exactly like PWDATA
# itself -- it reflects the CPU/AXI write's byte-lane intent, not anything
# address-decoded), so fan it out here directly rather than trying to plumb
# it through FIC_3_ADDRESS_GENERATION_1/CoreAPB3's decode chain -- CoreAPB3
# (Actel:DirectCore:CoreAPB3:4.2.100, see FIC_3_0x4000_0xxx.tcl) has no
# PSTRB port at all, so routing it "properly" through the existing
# bus-interface (bif) connections isn't even possible; this bypasses that
# chain the same way RECONFIGURATION_INTERFACE_0 above already does.
sd_connect_pins -sd_name ${sd_name} -pin_names {"PSTRB" "MPEG2FPGA_APB_PERIPHERAL_0:PSTRB" }

# Add bus interface net connections
sd_connect_pins -sd_name ${sd_name} -pin_names {"APB_MMASTER" "FIC_3_ADDRESS_GENERATION_1:APB_MMASTER" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"COREGPIO_C0:APB_bif" "FIC_3_ADDRESS_GENERATION_1:FIC_3_0x4000_01xx" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"CORE_I2C_C0_0_WRAPPER_1:APBslave" "FIC_3_ADDRESS_GENERATION_1:FIC_3_0x4000_02xx" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"CoreUARTapb_C0_0:APB_bif" "FIC_3_ADDRESS_GENERATION_1:FIC_3_0x4000_03xx" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"FIC_3_ADDRESS_GENERATION_1:FIC_3_0x4000_00xx" "PWM:APBslave" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"FIC_3_ADDRESS_GENERATION_1:FIC_3_0x4000_04xx" "MPEG2FPGA_APB_PERIPHERAL_0:APB_bif" }
# Fase 7a (2026-08-23) EXPERIMENT: mem2axi_bridge's AXI4 master, now a
# single bif-to-bif connect (was per-signal -- see the comment on
# MEM_AXI_MIRROREDSLAVE above for why).
sd_connect_pins -sd_name ${sd_name} -pin_names {"MPEG2FPGA_APB_PERIPHERAL_0:mem_axi_bif" "MEM_AXI_MIRROREDSLAVE" }
# Fase 7c: u_stream_dma's AXI4 read-only master, per-signal (same reasoning
# as MEM_AXI_* above -- no bif, plain sd_connect_pins).
sd_connect_pins -sd_name ${sd_name} -pin_names {"DMA_AXI_ARID" "MPEG2FPGA_APB_PERIPHERAL_0:dma_axi_arid" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"DMA_AXI_ARADDR" "MPEG2FPGA_APB_PERIPHERAL_0:dma_axi_araddr" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"DMA_AXI_ARLEN" "MPEG2FPGA_APB_PERIPHERAL_0:dma_axi_arlen" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"DMA_AXI_ARSIZE" "MPEG2FPGA_APB_PERIPHERAL_0:dma_axi_arsize" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"DMA_AXI_ARBURST" "MPEG2FPGA_APB_PERIPHERAL_0:dma_axi_arburst" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"DMA_AXI_ARLOCK" "MPEG2FPGA_APB_PERIPHERAL_0:dma_axi_arlock" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"DMA_AXI_ARCACHE" "MPEG2FPGA_APB_PERIPHERAL_0:dma_axi_arcache" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"DMA_AXI_ARPROT" "MPEG2FPGA_APB_PERIPHERAL_0:dma_axi_arprot" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"DMA_AXI_ARQOS" "MPEG2FPGA_APB_PERIPHERAL_0:dma_axi_arqos" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"DMA_AXI_ARVALID" "MPEG2FPGA_APB_PERIPHERAL_0:dma_axi_arvalid" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"DMA_AXI_ARREADY" "MPEG2FPGA_APB_PERIPHERAL_0:dma_axi_arready" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"DMA_AXI_RID" "MPEG2FPGA_APB_PERIPHERAL_0:dma_axi_rid" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"DMA_AXI_RDATA" "MPEG2FPGA_APB_PERIPHERAL_0:dma_axi_rdata" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"DMA_AXI_RRESP" "MPEG2FPGA_APB_PERIPHERAL_0:dma_axi_rresp" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"DMA_AXI_RLAST" "MPEG2FPGA_APB_PERIPHERAL_0:dma_axi_rlast" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"DMA_AXI_RVALID" "MPEG2FPGA_APB_PERIPHERAL_0:dma_axi_rvalid" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"DMA_AXI_RREADY" "MPEG2FPGA_APB_PERIPHERAL_0:dma_axi_rready" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"FIC_3_ADDRESS_GENERATION_1:FIC_3_0x43xx_xxxx_0x48xx_xxxx" "RECONFIGURATION_INTERFACE_0:APBS_SLAVE" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"FIC_3_ADDRESS_GENERATION_1:FIC_3_0x5xxx_xxxx" "MIV_IHC_C0_0:APB_0_M_INITIATOR" }
sd_connect_pins -sd_name ${sd_name} -pin_names {"PLL0_SW_DRI" "RECONFIGURATION_INTERFACE_0:PLL0_SW_DRI" }

# Re-enable auto promotion of pins of type 'pad'
auto_promote_pad_pins -promote_all 1
# Save the smartDesign
save_smartdesign -sd_name ${sd_name}
# Generate SmartDesign FIC_3_PERIPHERALS
generate_component -component_name ${sd_name}
