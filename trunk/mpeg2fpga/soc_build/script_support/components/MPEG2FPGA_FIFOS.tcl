# Recreate the three COREFIFO instances that xfifo_dc.v (rtl/mpeg2/xfifo_dc.v,
# Fase 0 -- FIFO_XILINX=0 path) instantiates by name: fifo_pixel_stream_dc_35x1024,
# fifo_mem_req_dc_88x64, fifo_mem_rsp_dc_64x128. Exact params copied from the
# "Component Description (Tcl)" comment Libero embeds in each originally
# SmartGen-generated wrapper under trunk/mpeg2fpga/mpeg2fpga/component/work/,
# so behavior matches the Fase 0 solo work exactly.

create_and_configure_core -core_vlnv {Actel:DirectCore:COREFIFO:3.1.101} -component_name {fifo_pixel_stream_dc_35x1024} -params {\
"AE_STATIC_EN:true"  \
"AEVAL:4"  \
"AF_STATIC_EN:true"  \
"AFVAL:1020"  \
"CTRL_TYPE:2"  \
"DIE_SIZE:10"  \
"ECC:0"  \
"ESTOP:true"  \
"FSTOP:true"  \
"FWFT:true"  \
"NUM_STAGES:2"  \
"OVERFLOW_EN:true"  \
"PIPE:1"  \
"PREFETCH:false"  \
"RAM_OPT:0"  \
"RDCNT_EN:false"  \
"RDEPTH:1024"  \
"RE_POLARITY:0"  \
"READ_DVALID:true"  \
"RWIDTH:35"  \
"SYNC:0"  \
"SYNC_RESET:1"  \
"UNDERFLOW_EN:true"  \
"WDEPTH:1024"  \
"WE_POLARITY:0"  \
"WRCNT_EN:false"  \
"WRITE_ACK:true"  \
"WWIDTH:35"   }

create_and_configure_core -core_vlnv {Actel:DirectCore:COREFIFO:3.1.101} -component_name {fifo_mem_req_dc_88x64} -params {\
"AE_STATIC_EN:true"  \
"AEVAL:4"  \
"AF_STATIC_EN:true"  \
"AFVAL:60"  \
"CTRL_TYPE:2"  \
"DIE_SIZE:10"  \
"ECC:0"  \
"ESTOP:true"  \
"FSTOP:true"  \
"FWFT:true"  \
"NUM_STAGES:2"  \
"OVERFLOW_EN:true"  \
"PIPE:1"  \
"PREFETCH:false"  \
"RAM_OPT:0"  \
"RDCNT_EN:false"  \
"RDEPTH:64"  \
"RE_POLARITY:0"  \
"READ_DVALID:true"  \
"RWIDTH:88"  \
"SYNC:0"  \
"SYNC_RESET:1"  \
"UNDERFLOW_EN:true"  \
"WDEPTH:64"  \
"WE_POLARITY:0"  \
"WRCNT_EN:false"  \
"WRITE_ACK:true"  \
"WWIDTH:88"   }

create_and_configure_core -core_vlnv {Actel:DirectCore:COREFIFO:3.1.101} -component_name {fifo_mem_rsp_dc_64x128} -params {\
"AE_STATIC_EN:true"  \
"AEVAL:4"  \
"AF_STATIC_EN:true"  \
"AFVAL:124"  \
"CTRL_TYPE:2"  \
"DIE_SIZE:10"  \
"ECC:0"  \
"ESTOP:true"  \
"FSTOP:true"  \
"FWFT:true"  \
"NUM_STAGES:2"  \
"OVERFLOW_EN:true"  \
"PIPE:1"  \
"PREFETCH:false"  \
"RAM_OPT:0"  \
"RDCNT_EN:false"  \
"RDEPTH:128"  \
"RE_POLARITY:0"  \
"READ_DVALID:true"  \
"RWIDTH:64"  \
"SYNC:0"  \
"SYNC_RESET:1"  \
"UNDERFLOW_EN:true"  \
"WDEPTH:128"  \
"WE_POLARITY:0"  \
"WRCNT_EN:false"  \
"WRITE_ACK:true"  \
"WWIDTH:64"   }
