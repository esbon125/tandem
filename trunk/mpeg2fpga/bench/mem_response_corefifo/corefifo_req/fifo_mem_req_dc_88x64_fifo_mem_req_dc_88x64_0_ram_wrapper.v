// Simulation-only stand-in for the real ram_wrapper.v (RAM1K20 hard macro,
// no Icarus model available) -- same reasoning and verified-safe approach
// as corefifo/fifo_mem_rsp_dc_64x128_fifo_mem_rsp_dc_64x128_0_ram_wrapper.v
// (see its header comment). Used here to test whether fifo_mem_req_dc_88x64
// (the *other* real dual-clock CoreFIFO instance, framestore.v's
// mem_request_fifo) shows the same internal-reset-stuck symptom as
// fifo_mem_rsp_dc_64x128 did -- if the bug is in wrappers.v's fifo_dc
// wrapper (shared by both), it should reproduce identically here despite
// completely independent copied CoreFIFO source files.
module fifo_mem_req_dc_88x64_fifo_mem_req_dc_88x64_0_ram_wrapper(
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
