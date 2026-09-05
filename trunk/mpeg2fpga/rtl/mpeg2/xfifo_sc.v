/* 
 * fifo_sc.v
 * 
 * Copyright (c) 2007 Koen De Vleeschauwer. 
 * 
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND 
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
 * ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE 
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL 
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS 
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) 
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY 
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF 
 * SUCH DAMAGE.
 */

/*
 * fifo with common clock for read and write port.
 */

`include "timescale.v"

module xfifo_sc (dbg,
	clk,
	rst,
	din,
	wr_en,
	full,
	wr_ack,
	overflow,
	prog_full,
	dout,
	rd_en,
	empty,
	valid,
	underflow,
	prog_empty
        );

  parameter [8:0]dta_width=9'd8;      /* Data bus width */
  parameter [8:0]addr_width=9'd8;     /* Address bus width, determines fifo size by evaluating 2^addr_width */
  parameter [8:0]prog_thresh=9'd1;    /* Programmable threshold constant for prog_empty and prog_full */
  
  input          clk;
  input          rst;         /* low active sync master reset */
  /* read port */
  output reg [dta_width-1:0]dout; /* data output */
  input          rd_en;       /* read enable */
  output reg     empty;       /* asserted if fifo is empty; no additional reads can be performed */
  output reg     valid;       /* valid (read acknowledge): indicates rd_en was asserted during previous clock cycle and data was succesfully read from fifo and placed on dout */
  output reg     underflow;   /* underflow (read error): indicates rd_en was asserted during previous clock cycle but no data was read from fifo because fifo was empty */
  output reg     prog_empty;  /* indicates the fifo has prog_thresh entries, or less. threshold for asserting prog_empty is prog_thresh */
  output    [255:0]dbg;       /* debug only, see the block at the end of this module */

  /* write port */
  input  [dta_width-1:0]din;  /* data input */
  input          wr_en;       /* write enable */
  output reg     full;        /* asserted if fifo is full; no additional writes can be performed */
  output reg     overflow;    /* overflow (write error): indicates wr_en was asserted during previous clock cycle but no data was written to fifo because fifo was full */
  output reg     wr_ack;      /* write acknowledge: indicates wr_en was asserted during previous clock cycle and data was succesfully written to fifo */
  output reg     prog_full;   /* indicates the fifo has prog_thresh free entries, or less, left. threshold for asserting prog_full is 2^addr_width - prog_thresh */

  /* Writing when the fifo is full, or reading while the fifo is empty, does not destroy the contents of the fifo. */

  /*
   * read and write addresses 
   */

  reg  [addr_width:0]wr_addr;
  reg  [addr_width:0]rd_addr;
  reg  [addr_width:0]next_wr_addr;
  reg  [addr_width:0]next_rd_addr;

  always @*
    if (wr_en && ~full) next_wr_addr = wr_addr + 1'b1;
    else next_wr_addr = wr_addr;

  always @*
    if (rd_en && ~empty) next_rd_addr = rd_addr + 1'b1;
    else next_rd_addr = rd_addr;

  always @(posedge clk)
    if (~rst) wr_addr <= 1'b0;
    else wr_addr <= next_wr_addr;

  always @(posedge clk)
    if (~rst) rd_addr <= 1'b0;
    else rd_addr <= next_rd_addr;

  /*
   * empty and full
   */

  always @(posedge clk)
    if (~rst) empty <= 1'b1;
    else empty <= (next_wr_addr == next_rd_addr);

  always @(posedge clk)
    if (~rst) full <= 1'b0;
    else full <= (next_wr_addr[addr_width-1:0] == next_rd_addr[addr_width-1:0]) && (next_wr_addr[addr_width] != next_rd_addr[addr_width]);

  /*
   * valid and wr_ack
   */

  always @(posedge clk)
    if (~rst) valid <= 1'b0;
    else valid <= rd_en && ~empty;

  always @(posedge clk)
    if (~rst) wr_ack <= 1'b0;
    else wr_ack <= wr_en && ~full;

  /*
   * underflow and overflow
   */

  always @(posedge clk)
    if (~rst) underflow <= 1'b0;
    else underflow <= rd_en && empty;

  always @(posedge clk)
    if (~rst) overflow <= 1'b0;
    else overflow <= wr_en && full;

  /*
   * prog_empty and prog_full
   */

  wire [addr_width:0]next_count = next_wr_addr - next_rd_addr;
  wire [addr_width:0]lower_threshold = prog_thresh + 1'b1;
  wire [addr_width:0]max_count = 1'b1 << addr_width;
  wire [addr_width:0]upper_threshold = max_count - lower_threshold;

  always @(posedge clk)
    if (~rst) prog_empty <= 1'b1;
    else prog_empty <= (next_count < lower_threshold);

  always @(posedge clk)
    if (~rst) prog_full <= 1'b0;
    else prog_full <= (next_count > upper_threshold);

  /*
   * dual-port ram w/registered output
   */

  reg    [dta_width-1:0]ram[(1 << addr_width)-1:0];

  always @(posedge clk)
    if (~rst) dout <= 0;
    else if (~empty) dout <= ram[rd_addr[addr_width-1:0]];
    else dout <= dout;

  always @(posedge clk)
    if (wr_en && ~full) ram[wr_addr[addr_width-1:0]] <= din;

  /*
   * Debug instrumentation (2026-09-05, Fase 7a).
   *
   * Measurement so far (docs/bringup 35): the first 64-bit word is correct
   * going INTO vbuf_read_fifo and corrupt coming out towards getbits, 10/10.
   * The first explanation tried -- a same-address read/write collision on the
   * RAM below -- was WRONG and is retracted: empty, wr_addr and rd_addr all
   * update on the same edge, so ~empty implies wr_addr != rd_addr, and equal
   * low bits with differing full addresses is exactly the `full` condition,
   * which blocks the write. The addresses can never collide during a write.
   * (Synthesis emits FX107 "no read/write conflict check" for this RAM, but it
   * emits it for 41 RAMs including Microchip's own IP -- it is a cannot-prove
   * warning, not a defect report. It was misread as evidence.)
   *
   * So the mechanism is unknown and this captures the raw facts at the FIFO's
   * own two boundaries, one level deeper than framestore.v's probes:
   *   - the first word written and the first word read, so "corrupt inside
   *     this FIFO" no longer depends on where the outer probes sampled
   *   - the pointers and flags at each of those moments
   *   - writes that landed while the FIFO was held in reset. The RAM write
   *     below is NOT gated by rst and `full` resets to 0, so a write during
   *     reset would land at the frozen wr_addr. vbuf_read_fifo also runs off
   *     its own reset chain (mpeg2video.v's vbuf_rst, separate from sync_rst),
   *     so the two can release on different cycles.
   *
   * Read-only, and unconnected on the nine instances that are not being
   * investigated.
   */

  reg   [dta_width-1:0]dbg_first_din;
  reg   [dta_width-1:0]dbg_first_dout;
  reg                  dbg_first_wr_seen;
  reg                  dbg_first_rd_seen;
  reg    [addr_width:0]dbg_wr_at_first_wr, dbg_rd_at_first_wr;
  reg    [addr_width:0]dbg_wr_at_first_rd, dbg_rd_at_first_rd;
  reg                  dbg_full_at_first_wr, dbg_empty_at_first_rd;
  reg           [15:0]dbg_wr_count, dbg_rd_count;

  always @(posedge clk)
    if (~rst)
      begin
        dbg_first_din        <= 0;
        dbg_first_wr_seen    <= 1'b0;
        dbg_wr_at_first_wr   <= 0;
        dbg_rd_at_first_wr   <= 0;
        dbg_full_at_first_wr <= 1'b0;
        dbg_wr_count         <= 16'b0;
      end
    else if (wr_en && ~full)
      begin
        if (~&dbg_wr_count) dbg_wr_count <= dbg_wr_count + 16'd1;
        if (~dbg_first_wr_seen)
          begin
            dbg_first_din        <= din;
            dbg_wr_at_first_wr   <= wr_addr;
            dbg_rd_at_first_wr   <= rd_addr;
            dbg_full_at_first_wr <= full;
            dbg_first_wr_seen    <= 1'b1;
          end
      end

  always @(posedge clk)
    if (~rst)
      begin
        dbg_first_dout        <= 0;
        dbg_first_rd_seen     <= 1'b0;
        dbg_wr_at_first_rd    <= 0;
        dbg_rd_at_first_rd    <= 0;
        dbg_empty_at_first_rd <= 1'b0;
        dbg_rd_count          <= 16'b0;
      end
    else if (rd_en && ~empty)
      begin
        if (~&dbg_rd_count) dbg_rd_count <= dbg_rd_count + 16'd1;
        if (~dbg_first_rd_seen)
          begin
            dbg_first_dout        <= ram[rd_addr[addr_width-1:0]];
            dbg_wr_at_first_rd    <= wr_addr;
            dbg_rd_at_first_rd    <= rd_addr;
            dbg_empty_at_first_rd <= empty;
            dbg_first_rd_seen     <= 1'b1;
          end
      end

  /* Writes that landed while the FIFO was held in reset, latched at release
   * so the count describes the reset episode that just ended. Deliberately
   * NOT cleared by rst -- that is the whole point. */
  reg        dbg_rst_d;
  reg  [7:0] dbg_wr_in_rst;
  reg  [7:0] dbg_wr_in_rst_latched;

  always @(posedge clk)
    begin
      dbg_rst_d <= rst;
      if (rst && ~dbg_rst_d)
        begin
          dbg_wr_in_rst_latched <= dbg_wr_in_rst;
          dbg_wr_in_rst         <= 8'b0;
        end
      else if (~rst && wr_en && ~&dbg_wr_in_rst)
        dbg_wr_in_rst <= dbg_wr_in_rst + 8'd1;
    end

  /* Fixed-width views so the software side never has to know dta_width or
   * addr_width. Plain assignment, NOT a padded concatenation: some fifo_sc
   * instances are wider than 64 bits (the motion-vector fifos), and
   * {{(64-dta_width){1'b0}}, ...} underflows to a huge unsigned replication
   * count there -- iverilog dies with std::bad_alloc trying to build it.
   * Verilog zero-extends or truncates an assignment on its own. */
  wire [63:0]dbg_din_64  = dbg_first_din;
  wire [63:0]dbg_dout_64 = dbg_first_dout;
  wire [15:0]dbg_wwr_16  = dbg_wr_at_first_wr;
  wire [15:0]dbg_rwr_16  = dbg_rd_at_first_wr;
  wire [15:0]dbg_wrd_16  = dbg_wr_at_first_rd;
  wire [15:0]dbg_rrd_16  = dbg_rd_at_first_rd;

  assign dbg = {
      /* word 7 */ dbg_rd_count, dbg_wr_count,
      /* word 6 */ 8'b0, dbg_wr_in_rst_latched, 12'b0, dbg_first_rd_seen,
                   dbg_first_wr_seen, dbg_empty_at_first_rd, dbg_full_at_first_wr,
      /* word 5 */ dbg_rrd_16, dbg_wrd_16,
      /* word 4 */ dbg_rwr_16, dbg_wwr_16,
      /* words 3,2 */ dbg_dout_64,
      /* words 1,0 */ dbg_din_64
      };

endmodule
/* not truncated */
