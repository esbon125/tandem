//////////////////////////////////////////////////////////////////////
// Created by SmartDesign Sat Aug 22 16:34:43 2026
// Version: 2025.2 2025.2.0.14
//////////////////////////////////////////////////////////////////////

`timescale 1ns / 100ps

//////////////////////////////////////////////////////////////////////
// Component Description (Tcl) 
//////////////////////////////////////////////////////////////////////
/*
# Exporting Component Description of fifo_mem_rsp_dc_64x128 to TCL
# Family: PolarFireSoC
# Part Number: MPFS095T-1FCSG325E
# Create and Configure the core component fifo_mem_rsp_dc_64x128
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
# Exporting Component Description of fifo_mem_rsp_dc_64x128 to TCL done
*/

// fifo_mem_rsp_dc_64x128
module fifo_mem_rsp_dc_64x128(
    // Inputs
    DATA,
    RCLOCK,
    RE,
    RRESET_N,
    WCLOCK,
    WE,
    WRESET_N,
    // Outputs
    AEMPTY,
    AFULL,
    DVLD,
    EMPTY,
    FULL,
    OVERFLOW,
    Q,
    UNDERFLOW,
    WACK
);

//--------------------------------------------------------------------
// Input
//--------------------------------------------------------------------
input  [63:0] DATA;
input         RCLOCK;
input         RE;
input         RRESET_N;
input         WCLOCK;
input         WE;
input         WRESET_N;
//--------------------------------------------------------------------
// Output
//--------------------------------------------------------------------
output        AEMPTY;
output        AFULL;
output        DVLD;
output        EMPTY;
output        FULL;
output        OVERFLOW;
output [63:0] Q;
output        UNDERFLOW;
output        WACK;
//--------------------------------------------------------------------
// Nets
//--------------------------------------------------------------------
wire          AEMPTY_net_0;
wire          AFULL_net_0;
wire   [63:0] DATA;
wire          DVLD_net_0;
wire          EMPTY_net_0;
wire          FULL_net_0;
wire          OVERFLOW_net_0;
wire   [63:0] Q_net_0;
wire          RCLOCK;
wire          RE;
wire          RRESET_N;
wire          UNDERFLOW_net_0;
wire          WACK_net_0;
wire          WCLOCK;
wire          WE;
wire          WRESET_N;
wire   [63:0] Q_net_1;
wire          FULL_net_1;
wire          EMPTY_net_1;
wire          AFULL_net_1;
wire          AEMPTY_net_1;
wire          OVERFLOW_net_1;
wire          UNDERFLOW_net_1;
wire          WACK_net_1;
wire          DVLD_net_1;
//--------------------------------------------------------------------
// TiedOff Nets
//--------------------------------------------------------------------
wire          GND_net;
wire   [63:0] MEMRD_const_net_0;
//--------------------------------------------------------------------
// Constant assignments
//--------------------------------------------------------------------
assign GND_net           = 1'b0;
assign MEMRD_const_net_0 = 64'h0000000000000000;
//--------------------------------------------------------------------
// Top level output port assignments
//--------------------------------------------------------------------
assign Q_net_1         = Q_net_0;
assign Q[63:0]         = Q_net_1;
assign FULL_net_1      = FULL_net_0;
assign FULL            = FULL_net_1;
assign EMPTY_net_1     = EMPTY_net_0;
assign EMPTY           = EMPTY_net_1;
assign AFULL_net_1     = AFULL_net_0;
assign AFULL           = AFULL_net_1;
assign AEMPTY_net_1    = AEMPTY_net_0;
assign AEMPTY          = AEMPTY_net_1;
assign OVERFLOW_net_1  = OVERFLOW_net_0;
assign OVERFLOW        = OVERFLOW_net_1;
assign UNDERFLOW_net_1 = UNDERFLOW_net_0;
assign UNDERFLOW       = UNDERFLOW_net_1;
assign WACK_net_1      = WACK_net_0;
assign WACK            = WACK_net_1;
assign DVLD_net_1      = DVLD_net_0;
assign DVLD            = DVLD_net_1;
//--------------------------------------------------------------------
// Component instances
//--------------------------------------------------------------------
//--------fifo_mem_rsp_dc_64x128_fifo_mem_rsp_dc_64x128_0_COREFIFO   -   Actel:DirectCore:COREFIFO:3.1.101
fifo_mem_rsp_dc_64x128_fifo_mem_rsp_dc_64x128_0_COREFIFO #( 
        .AE_STATIC_EN ( 1 ),
        .AEVAL        ( 4 ),
        .AF_STATIC_EN ( 1 ),
        .AFVAL        ( 124 ),
        .CTRL_TYPE    ( 2 ),
        .DIE_SIZE     ( 10 ),
        .ECC          ( 0 ),
        .ESTOP        ( 1 ),
        .FAMILY       ( 27 ),
        .FSTOP        ( 1 ),
        .FWFT         ( 1 ),
        .NUM_STAGES   ( 2 ),
        .OVERFLOW_EN  ( 1 ),
        .PIPE         ( 1 ),
        .PREFETCH     ( 0 ),
        .RAM_OPT      ( 0 ),
        .RDCNT_EN     ( 0 ),
        .RDEPTH       ( 128 ),
        .RE_POLARITY  ( 0 ),
        .READ_DVALID  ( 1 ),
        .RWIDTH       ( 64 ),
        .SYNC         ( 0 ),
        .SYNC_RESET   ( 1 ),
        .UNDERFLOW_EN ( 1 ),
        .WDEPTH       ( 128 ),
        .WE_POLARITY  ( 0 ),
        .WRCNT_EN     ( 0 ),
        .WRITE_ACK    ( 1 ),
        .WWIDTH       ( 64 ) )
fifo_mem_rsp_dc_64x128_0(
        // Inputs
        .CLK        ( GND_net ), // tied to 1'b0 from definition
        .WCLOCK     ( WCLOCK ),
        .RCLOCK     ( RCLOCK ),
        .RESET_N    ( GND_net ), // tied to 1'b0 from definition
        .WRESET_N   ( WRESET_N ),
        .RRESET_N   ( RRESET_N ),
        .DATA       ( DATA ),
        .WE         ( WE ),
        .RE         ( RE ),
        .MEMRD      ( MEMRD_const_net_0 ), // tied to 64'h0000000000000000 from definition
        // Outputs
        .Q          ( Q_net_0 ),
        .FULL       ( FULL_net_0 ),
        .EMPTY      ( EMPTY_net_0 ),
        .AFULL      ( AFULL_net_0 ),
        .AEMPTY     ( AEMPTY_net_0 ),
        .OVERFLOW   ( OVERFLOW_net_0 ),
        .UNDERFLOW  ( UNDERFLOW_net_0 ),
        .WACK       ( WACK_net_0 ),
        .DVLD       ( DVLD_net_0 ),
        .WRCNT      (  ),
        .RDCNT      (  ),
        .MEMWE      (  ),
        .MEMRE      (  ),
        .MEMWADDR   (  ),
        .MEMRADDR   (  ),
        .MEMWD      (  ),
        .SB_CORRECT (  ),
        .DB_DETECT  (  ) 
        );


endmodule
