/* 
 * reset.v
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
 * Generate reset signals.
 *   Accepts an asynchronous reset signal, and generates reset signals in the clk, mem_clk and dot_clk domains
 *   which are at least three clock cycles long. 
 *
 * Xilinx FIFO18/FIFO36 primitives:
 * "The reset signal must be high for at least three read clock and three write clock cycles."
 *
 */

`include "timescale.v"

module reset (clk, mem_clk, dot_clk, async_rst, watchdog_rst,
              clk_rst, mem_rst, dot_rst, hard_rst,
              mem_hard_rst, mem_watchdog_rst);

  input clk;                  /* decoder clock */
  input mem_clk;              /* memory clock */
  input dot_clk;              /* pixel clock */
  input async_rst;            /* global reset, asynchronous. */
  input watchdog_rst;         /* watchdog-generated reset, synchronous with clk. Goes low when watchdog timer expires. */
  output clk_rst;             /* global reset, synchronized to decoder clock. Goes low when "async_rst" or "watchdog_rst" goes low. */
  output mem_rst;             /* global reset, synchronized to memory clock. Goes low when "async_rst" or "watchdog_rst" goes low. */
  output dot_rst;             /* global reset, synchronized to pixel clock. Goes low when "async_rst" or "watchdog_rst" goes low. */
  output hard_rst;            /* "hard" reset signal. Goes low when "async_rst" input pin goes low. */

  /* mem_hard_rst/mem_watchdog_rst (2026-08-26, mem2axi_bridge.v write-side
   * AXI4-interconnect-wedge fix): mem_clk-domain analogues of hard_rst
   * (async_rst-only) and of the raw watchdog_rst input (watchdog-only),
   * kept separate the same reason core_rst_out/stream_dma.v's watchdog_rst
   * port needed a raw-vs-watchdog split in the clk domain -- a module that
   * resets instantly on the shared, non-resetting fabric's watchdog can
   * abandon an outstanding AXI4 transaction. mem2axi_bridge.v is the first
   * consumer: it needs the *unstretched-by-watchdog* mem_rst (i.e. just
   * async_rst, safe to apply instantly since a real external reset also
   * resets FIC_1/the DDR controller) plus a separately-visible watchdog
   * pulse (synchronized here, not usable directly from mpeg2video's clk-
   * domain watchdog_rst output) so it can defer applying a watchdog-only
   * reset until any outstanding AW/W/B or AR/R obligation drains. */
  output mem_hard_rst;
  output mem_watchdog_rst;

  /* synchronize async_rst and watchdog with clk */

  wire clk_rst_0;
  wire clk_watchdog_0;

  sync_reset clk_sreset_0 (
    .clk(clk), 
    .asyncrst(async_rst),
    .syncrst(clk_rst_0)
    );

  sync_reset clk_swatchdog_0 (
    .clk(clk), 
    .asyncrst(watchdog_rst),
    .syncrst(clk_watchdog_0)
    );

  /* combine async_rst and watchdog into a common reset signal */
  wire comm_rst = clk_rst_0 && clk_watchdog_0;

  /* synchronize common reset signal to the three system clocks */
  wire clk_rst_1;
  wire mem_rst_1;
  wire dot_rst_1;

  sync_reset clk_sreset_1 (
    .clk(clk), 
    .asyncrst(comm_rst),
    .syncrst(clk_rst_1)
    );

  sync_reset mem_sreset_1 (
    .clk(mem_clk), 
    .asyncrst(comm_rst),
    .syncrst(mem_rst_1) 
    );

  sync_reset dot_sreset_1 (
    .clk(dot_clk), 
    .asyncrst(comm_rst),
    .syncrst(dot_rst_1) 
    );

  /*
   * combine all three resets - this produces a reset which is at least three clock cycles long in any clock domain
   */

  wire global_rst = clk_rst_1 && mem_rst_1 && dot_rst_1;

  /* 2026-08-27: clk_rst/mem_rst used to both resync off the full 3-domain
   * global_rst above. That 3-way AND exists so a reset is guaranteed >=3
   * cycles long in *every* domain simultaneously -- a requirement inherited
   * from the original Xilinx hard FIFO18/36 primitives (see this file's own
   * header comment), which needed exactly that. This port no longer uses
   * those primitives anywhere (FIFO_XILINX=0, xfifo_dc.v/CoreFIFO instead,
   * see wrappers.v) -- so the 3-way coupling is vestigial, and actively
   * harmful: it makes mem_rst (which gates mem_request_fifo's read-side and
   * mem_response_fifo's write-side reset, see framestore.v) depend on
   * dot_rst_1, i.e. on dot_clk (the video/DVI output clock) also
   * synchronizing -- even though decode/memory and video output are
   * logically independent subsystems. Confirmed on real hardware
   * (2026-08-27): with no display attached, dot_clk never ticks, dot_rst_1
   * never releases (a sync_reset's async clear holds it at 0 with no clock
   * edges to march the release through), so global_rst -- and therefore
   * mem_rst -- stays asserted forever, while clk_rst (decode-domain,
   * confirmed alive: dbg_mem_req_wr_push_cnt reaches 60) is unaffected.
   * mem2axi_bridge.v's mem_hard_rst/mem_watchdog_rst already sidestep this
   * exact problem the same way, for the same reason (see their comments
   * below) -- clk_rst/mem_rst get the analogous fix here: drop dot_rst_1
   * from their own gate, keeping only the two domains that actually matter
   * to them (clk_rst_1 && mem_rst_1, still >=3 cycles in both). dot_rst
   * itself is untouched -- it legitimately only matters to dot_clk-domain
   * (video output) logic, which does need dot_clk running regardless.
   */
  wire clkmem_rst = clk_rst_1 && mem_rst_1;

  /*
   * Now synchronize the reset back to the individual clocks
   */

  sync_reset clk_sreset_2 (
    .clk(clk),
    .asyncrst(clkmem_rst),
    .syncrst(clk_rst)
    );

  sync_reset mem_sreset_2 (
    .clk(mem_clk),
    .asyncrst(clkmem_rst),
    .syncrst(mem_rst)
    );

  sync_reset dot_sreset_2 (
    .clk(dot_clk),
    .asyncrst(global_rst),
    .syncrst(dot_rst)
    );

  /*
   * "Hard" reset signal. Goes low when the "rst" input pin goes low.
   * Use two synchronizers so delay from async_rst to hard_rst is the same as the delay from async_rst to clk_rst.
   */

  wire hard_rst_1;

  sync_reset hard_sreset_1 (
    .clk(clk), 
    .asyncrst(clk_rst_0),
    .syncrst(hard_rst_1)
    );

  sync_reset hard_sreset_2 (
    .clk(clk),
    .asyncrst(hard_rst_1),
    .syncrst(hard_rst)
    );

  /*
   * mem_hard_rst: same two-stage pattern as hard_rst above, but synchronized
   * to mem_clk instead of clk -- feeding clk_rst_0 (already a clk-domain
   * signal) into a mem_clk sync_reset chain as "asyncrst" is the same idiom
   * comm_rst already uses to cross into mem_sreset_1 below.
   */

  wire mem_hard_rst_1;

  sync_reset mem_hard_sreset_1 (
    .clk(mem_clk),
    .asyncrst(clk_rst_0),
    .syncrst(mem_hard_rst_1)
    );

  sync_reset mem_hard_sreset_2 (
    .clk(mem_clk),
    .asyncrst(mem_hard_rst_1),
    .syncrst(mem_hard_rst)
    );

  /*
   * mem_watchdog_rst: same pattern, fed from clk_watchdog_0 (the clk-domain
   * synchronized, already-stretched watchdog pulse) instead -- a proper
   * mem_clk-domain version of "watchdog fired", independent of async_rst.
   */

  wire mem_watchdog_rst_1;

  sync_reset mem_watchdog_sreset_1 (
    .clk(mem_clk),
    .asyncrst(clk_watchdog_0),
    .syncrst(mem_watchdog_rst_1)
    );

  sync_reset mem_watchdog_sreset_2 (
    .clk(mem_clk),
    .asyncrst(mem_watchdog_rst_1),
    .syncrst(mem_watchdog_rst)
    );

endmodule
/* not truncated */

