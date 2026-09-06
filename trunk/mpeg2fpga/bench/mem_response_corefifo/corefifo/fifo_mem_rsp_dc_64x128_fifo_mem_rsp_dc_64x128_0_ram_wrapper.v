// Simulation-only stand-in for the real ram_wrapper.v, which instantiates
// PolarFire's RAM1K20 hard macro (no Icarus-compatible model available on
// this machine -- Microchip ships only precompiled ModelSim/QuestaSim
// libraries, .qdb/.qtl, not usable by Icarus).
//
// Port list and parameter names copied verbatim from the real
// ram_wrapper.v so it drops into COREFIFO.v's instantiation unchanged.
// Confirmed via COREFIFO.v (line ~1251-1252) that RDEPTH/WDEPTH are
// overridden to ceil_log2t(actual_depth) at the call site -- i.e. WADDR/
// RADDR really are plain binary addresses (7 bits for our 128-deep fifo),
// not the 128-bit bus the *declared* default parameter value would
// otherwise suggest. Real PolarFire LSRAM behavior: synchronous
// (registered) read on RCLOCK, synchronous write on WCLOCK, reset only
// clears the read-data output register (not the underlying array) --
// matches real hard-macro BRAM semantics.
//
// This stub intentionally only models plain read/write timing -- CTRL_TYPE,
// RAM_OPT, PIPE, SYNC, SYNC_RESET are accepted as parameters (to match the
// call site) but not used to alter behavior; ECC is disabled in our config
// (ECC:0) so A_SB_CORRECT/B_SB_CORRECT/A_DB_DETECT/B_DB_DETECT are tied low.
module fifo_mem_rsp_dc_64x128_fifo_mem_rsp_dc_64x128_0_ram_wrapper(
WDATA,
WADDR,
WEN,
REN,
RDATA,
RADDR,
RESET_N,
CLOCK,
WCLOCK,
A_SB_CORRECT,
B_SB_CORRECT,
A_DB_DETECT,
B_DB_DETECT,
RCLOCK
);

parameter                RWIDTH        = 32;
parameter                WWIDTH        = 32;
parameter                RDEPTH        = 128;
parameter                WDEPTH        = 128;
parameter                SYNC          = 0;
parameter                PIPE          = 1;
parameter                CTRL_TYPE     = 1;
parameter                SYNC_RESET     = 0;
parameter                RAM_OPT     = 0;

input [WWIDTH - 1 : 0]   WDATA;
input [(WDEPTH - 1) : 0] WADDR;
input                    WEN;
input                    REN;
output reg [RWIDTH - 1 : 0]  RDATA;
input [(RDEPTH - 1) : 0] RADDR;
input                    RESET_N;
input                    WCLOCK;
input                    RCLOCK;
output                    A_SB_CORRECT;
output                    B_SB_CORRECT;
output                    A_DB_DETECT;
output                    B_DB_DETECT;
input                    CLOCK;

assign A_SB_CORRECT = 1'b0;
assign B_SB_CORRECT = 1'b0;
assign A_DB_DETECT  = 1'b0;
assign B_DB_DETECT  = 1'b0;

reg [WWIDTH-1:0] mem [0:(1<<WDEPTH)-1];

always @(posedge WCLOCK)
  if (WEN) mem[WADDR] <= WDATA;

always @(posedge RCLOCK)
  if (~RESET_N) RDATA <= {RWIDTH{1'b0}};
  else if (REN) RDATA <= mem[RADDR];

endmodule
