/*
 * mem_ctl_latency.v
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
 * Latency-modeling variant of mem_ctl.v (2026-08-23, real-hardware stall
 * investigation, see docs/bringup on the docs branch): plain mem_ctl.v
 * responds to every request same-cycle/next-cycle, unconditionally --
 * mem2axi_bridge.v (the real AXI4 write master used on hardware, never
 * exercised by bench/iverilog at all -- it isn't in the Makefile's SRCS)
 * is a single-outstanding-transaction state machine (S_IDLE -> S_LATCH ->
 * S_WRITE/S_ARADDR -> S_BRESP/S_RDATA -> back to S_IDLE, no pipelining,
 * one request fully completes before the next is even popped).
 *
 * This module keeps mem_ctl.v's pop/response protocol (mem_req_rd_en/
 * mem_req_rd_valid, mem_res_wr_en/mem_res_wr_dta/mem_res_wr_almost_full)
 * bit-for-bit identical -- same S_IDLE/S_LATCH structure as
 * mem2axi_bridge.v -- but replaces the real AXI4 handshake wait (on
 * awready/wready/bvalid/arready/rvalid) with a fixed LATENCY-cycle counter,
 * to see whether a single-outstanding, non-zero-latency memory model alone
 * is enough to reproduce the STATE_CLEAR/mem_req_wr_almost_full deadlock
 * seen on real hardware (see [[fase7a_size_zero_vld_stall]] point 16) --
 * as opposed to needing to also model the specific orphaned-stream_dma-
 * AXI4-read-transaction wedge hypothesized separately.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

`undef DUMP_FRAMESTORE
`define DUMP_FRAMESTORE 1

`undef DUMP_FRAMESTORE_OFTEN
`define DUMP_FRAMESTORE_OFTEN 1

module mem_ctl(
  clk, rst,
  mem_req_rd_cmd, mem_req_rd_addr, mem_req_rd_dta, mem_req_rd_en, mem_req_rd_valid,
  mem_res_wr_dta, mem_res_wr_en, mem_res_wr_almost_full
  );

  /* Cycles a single, non-pipelined read or write transaction takes to
   * complete, mem_clk-domain (162 MHz in this testbench) -- stands in for
   * mem2axi_bridge.v's real AXI4 AWREADY/WREADY/BVALID/ARREADY/RVALID
   * round trip. Override from the command line, e.g.
   * `iverilog ... -Ptestbench.mem_ctl.LATENCY=40`. 0 reproduces plain
   * mem_ctl.v's same-cycle behavior exactly (still single-outstanding,
   * unlike mem_ctl.v, so even LATENCY=0 here is not quite identical). */
  parameter LATENCY = 24;

  input            clk;
  input            rst;
  input       [1:0]mem_req_rd_cmd;
  input      [21:0]mem_req_rd_addr;
  input      [63:0]mem_req_rd_dta;
  output reg       mem_req_rd_en;
  input            mem_req_rd_valid;
  output reg [63:0]mem_res_wr_dta;
  output reg       mem_res_wr_en;
  input            mem_res_wr_almost_full;

`include "mem_codes.v"

  reg [63:0]mem[0:END_OF_MEM]; /* memory, 64-bit wide. Simulation only, not synthesizable. */

  localparam [1:0]
    S_IDLE  = 2'd0,   // popping mem_req_rd; mem_req_rd_en asserted
    S_LATCH = 2'd1,   // mem_req_rd_valid seen last cycle; cmd_r/addr_r/dta_r valid
    S_BUSY  = 2'd2,   // modeling the real AXI4 round trip -- LATENCY cycles, single-outstanding
    S_RESP  = 2'd3;   // pushing mem_res_wr, respecting mem_res_wr_almost_full

  reg  [1:0]state, next;
  reg  [1:0]cmd_r;
  reg [21:0]addr_r;
  reg [63:0]dta_r;
  reg [31:0]cnt;

  always @* begin
    case (state)
      S_IDLE:  next = mem_req_rd_valid ? S_LATCH : S_IDLE;
      S_LATCH: case (cmd_r)
                 CMD_WRITE: next = S_BUSY;
                 CMD_READ:  next = S_BUSY;
                 default:   next = S_IDLE;  // CMD_NOOP / CMD_REFRESH: no transaction
               endcase
      S_BUSY:  next = (cnt == 32'd0) ? ((cmd_r == CMD_READ) ? S_RESP : S_IDLE) : S_BUSY;
      S_RESP:  next = mem_res_wr_almost_full ? S_RESP : S_IDLE;
      default: next = S_IDLE;
    endcase
  end

  always @(posedge clk)
    if (~rst) state <= S_IDLE;
    else state <= next;

`ifdef MEM_CTL_LATENCY_TRACE
  /* Change-gated, not per-cycle: a full $strobe every cycle was too
   * expensive to cover enough simulated time in a reasonable wall-clock
   * budget (2026-08-23 -- real-hardware stall investigation, see
   * fase7a_size_zero_vld_stall on the docs branch). Only print when
   * something actually moves. */
  reg [10:0] fq_state_prev;
  reg [21:0] vbuf_wr_addr_prev;
  reg [21:0] vbuf_rd_addr_prev;
  reg        wr_almost_full_prev;
  reg [31:0] mb_addr_prev;
  reg        wait_state_prev;
  reg        vld_en_prev;
  reg        getbits_valid_prev;
  reg        rld_wr_almost_full_prev;
  reg        mvec_wr_almost_full_prev;
  reg        motcomp_busy_prev;
  reg  [7:0] vld_state_prev;
  reg        gb_state_prev;
  reg  [7:0] gb_cursor_prev;
  reg        vbr_rd_valid_prev;
  reg  [2:0] fresp_state_prev;
  reg        tag_rd_valid_prev;
  reg        mem_res_rd_valid_prev;
  reg        vbr_wr_en_prev;
  reg [63:0] vbr_wr_dta_prev;

  initial begin
    fq_state_prev = 11'bx;
    vbuf_wr_addr_prev = 22'bx;
    vbuf_rd_addr_prev = 22'bx;
    wr_almost_full_prev = 1'bx;
    mb_addr_prev = 32'bx;
    wait_state_prev = 1'bx;
    vld_en_prev = 1'bx;
    getbits_valid_prev = 1'bx;
    rld_wr_almost_full_prev = 1'bx;
    mvec_wr_almost_full_prev = 1'bx;
    motcomp_busy_prev = 1'bx;
    vld_state_prev = 8'bx;
    gb_state_prev = 1'bx;
    gb_cursor_prev = 8'bx;
    vbr_rd_valid_prev = 1'bx;
    fresp_state_prev = 3'bx;
    tag_rd_valid_prev = 1'bx;
    mem_res_rd_valid_prev = 1'bx;
    vbr_wr_en_prev = 1'bx;
    vbr_wr_dta_prev = 64'bx;
  end

  always @(posedge clk) begin
    if (testbench.mpeg2.framestore.framestore_request.state !== fq_state_prev) begin
      $display("t=%0t framestore_request.state: %b -> %b", $time, fq_state_prev, testbench.mpeg2.framestore.framestore_request.state);
      fq_state_prev <= testbench.mpeg2.framestore.framestore_request.state;
    end
    if (testbench.mpeg2.framestore.framestore_request.vbuf_wr_addr !== vbuf_wr_addr_prev) begin
      $display("t=%0t vbuf_wr_addr: %h -> %h", $time, vbuf_wr_addr_prev, testbench.mpeg2.framestore.framestore_request.vbuf_wr_addr);
      vbuf_wr_addr_prev <= testbench.mpeg2.framestore.framestore_request.vbuf_wr_addr;
    end
    if (testbench.mpeg2.framestore.framestore_request.vbuf_rd_addr !== vbuf_rd_addr_prev) begin
      $display("t=%0t vbuf_rd_addr: %h -> %h", $time, vbuf_rd_addr_prev, testbench.mpeg2.framestore.framestore_request.vbuf_rd_addr);
      vbuf_rd_addr_prev <= testbench.mpeg2.framestore.framestore_request.vbuf_rd_addr;
    end
    if (testbench.mpeg2.framestore.mem_req_wr_almost_full !== wr_almost_full_prev) begin
      $display("t=%0t mem_req_wr_almost_full: %b -> %b", $time, wr_almost_full_prev, testbench.mpeg2.framestore.mem_req_wr_almost_full);
      wr_almost_full_prev <= testbench.mpeg2.framestore.mem_req_wr_almost_full;
    end
    if (testbench.mpeg2.macroblock_address !== mb_addr_prev) begin
      $display("t=%0t macroblock_address: %0d -> %0d", $time, mb_addr_prev, testbench.mpeg2.macroblock_address);
      mb_addr_prev <= testbench.mpeg2.macroblock_address;
    end
    /* front-end pipeline: is getbits/vld itself stuck, or is it being
     * frozen by backpressure from a downstream consumer (rld/motcomp)? */
    if (testbench.mpeg2.wait_state !== wait_state_prev) begin
      $display("t=%0t wait_state: %b -> %b", $time, wait_state_prev, testbench.mpeg2.wait_state);
      wait_state_prev <= testbench.mpeg2.wait_state;
    end
    if (testbench.mpeg2.vld_en !== vld_en_prev) begin
      $display("t=%0t vld_en: %b -> %b", $time, vld_en_prev, testbench.mpeg2.vld_en);
      vld_en_prev <= testbench.mpeg2.vld_en;
    end
    if (testbench.mpeg2.getbits_valid !== getbits_valid_prev) begin
      $display("t=%0t getbits_valid: %b -> %b", $time, getbits_valid_prev, testbench.mpeg2.getbits_valid);
      getbits_valid_prev <= testbench.mpeg2.getbits_valid;
    end
    if (testbench.mpeg2.rld_wr_almost_full !== rld_wr_almost_full_prev) begin
      $display("t=%0t rld_wr_almost_full: %b -> %b", $time, rld_wr_almost_full_prev, testbench.mpeg2.rld_wr_almost_full);
      rld_wr_almost_full_prev <= testbench.mpeg2.rld_wr_almost_full;
    end
    if (testbench.mpeg2.mvec_wr_almost_full !== mvec_wr_almost_full_prev) begin
      $display("t=%0t mvec_wr_almost_full: %b -> %b", $time, mvec_wr_almost_full_prev, testbench.mpeg2.mvec_wr_almost_full);
      mvec_wr_almost_full_prev <= testbench.mpeg2.mvec_wr_almost_full;
    end
    if (testbench.mpeg2.motcomp_busy !== motcomp_busy_prev) begin
      $display("t=%0t motcomp_busy: %b -> %b", $time, motcomp_busy_prev, testbench.mpeg2.motcomp_busy);
      motcomp_busy_prev <= testbench.mpeg2.motcomp_busy;
    end
    if (testbench.mpeg2.vld.state !== vld_state_prev) begin
      $display("t=%0t vld.state: 0x%02h -> 0x%02h getbits=0x%06h clk_en=%b vld_err=%b",
                $time, vld_state_prev, testbench.mpeg2.vld.state,
                testbench.mpeg2.vld.getbits, testbench.mpeg2.vld.clk_en,
                testbench.mpeg2.vld.vld_err);
      vld_state_prev <= testbench.mpeg2.vld.state;
    end
    if (testbench.mpeg2.getbits_fifo.state !== gb_state_prev) begin
      $display("t=%0t getbits_fifo.state: %b -> %b cursor=%0d vid_in_rd_en=%b vid_in_rd_valid=%b vbr_rd_valid=%b vbr_rd_dta=0x%016h",
                $time, gb_state_prev, testbench.mpeg2.getbits_fifo.state,
                testbench.mpeg2.getbits_fifo.cursor,
                testbench.mpeg2.getbits_fifo.vid_in_rd_en,
                testbench.mpeg2.getbits_fifo.vid_in_rd_valid,
                testbench.mpeg2.vbr_rd_valid, testbench.mpeg2.vbr_rd_dta);
      gb_state_prev <= testbench.mpeg2.getbits_fifo.state;
    end
    if (testbench.mpeg2.getbits_fifo.cursor !== gb_cursor_prev) begin
      $display("t=%0t gb_cursor: %0d -> %0d", $time, gb_cursor_prev, testbench.mpeg2.getbits_fifo.cursor);
      gb_cursor_prev <= testbench.mpeg2.getbits_fifo.cursor;
    end
    if (testbench.mpeg2.vbr_rd_valid !== vbr_rd_valid_prev) begin
      $display("t=%0t vbr_rd_valid: %b -> %b vbr_rd_dta=0x%016h", $time, vbr_rd_valid_prev, testbench.mpeg2.vbr_rd_valid, testbench.mpeg2.vbr_rd_dta);
      vbr_rd_valid_prev <= testbench.mpeg2.vbr_rd_valid;
    end
    if (testbench.mpeg2.framestore.framestore_response.state !== fresp_state_prev) begin
      $display("t=%0t fresp.state: %0d -> %0d tag_rd_valid=%b tag_rd_dta=%0d mem_res_rd_valid=%b mem_res_rd_dta=0x%016h",
                $time, fresp_state_prev, testbench.mpeg2.framestore.framestore_response.state,
                testbench.mpeg2.framestore.framestore_response.tag_rd_valid,
                testbench.mpeg2.framestore.framestore_response.tag_rd_dta,
                testbench.mpeg2.framestore.framestore_response.mem_res_rd_valid,
                testbench.mpeg2.framestore.framestore_response.mem_res_rd_dta);
      fresp_state_prev <= testbench.mpeg2.framestore.framestore_response.state;
    end
    if (testbench.mpeg2.framestore.framestore_response.tag_rd_valid !== tag_rd_valid_prev) begin
      $display("t=%0t tag_rd_valid: %b -> %b tag_rd_dta=%0d", $time, tag_rd_valid_prev, testbench.mpeg2.framestore.framestore_response.tag_rd_valid, testbench.mpeg2.framestore.framestore_response.tag_rd_dta);
      tag_rd_valid_prev <= testbench.mpeg2.framestore.framestore_response.tag_rd_valid;
    end
    if (testbench.mpeg2.framestore.framestore_response.mem_res_rd_valid !== mem_res_rd_valid_prev) begin
      $display("t=%0t mem_res_rd_valid: %b -> %b mem_res_rd_dta=0x%016h", $time, mem_res_rd_valid_prev, testbench.mpeg2.framestore.framestore_response.mem_res_rd_valid, testbench.mpeg2.framestore.framestore_response.mem_res_rd_dta);
      mem_res_rd_valid_prev <= testbench.mpeg2.framestore.framestore_response.mem_res_rd_valid;
    end
    if (testbench.mpeg2.framestore.framestore_response.vbr_wr_en !== vbr_wr_en_prev) begin
      $display("t=%0t vbr_wr_en: %b -> %b vbr_wr_dta=0x%016h", $time, vbr_wr_en_prev, testbench.mpeg2.framestore.framestore_response.vbr_wr_en, testbench.mpeg2.framestore.framestore_response.vbr_wr_dta);
      vbr_wr_en_prev <= testbench.mpeg2.framestore.framestore_response.vbr_wr_en;
    end
    if (testbench.mpeg2.framestore.framestore_response.vbr_wr_dta !== vbr_wr_dta_prev) begin
      $display("t=%0t vbr_wr_dta: 0x%016h -> 0x%016h", $time, vbr_wr_dta_prev, testbench.mpeg2.framestore.framestore_response.vbr_wr_dta);
      vbr_wr_dta_prev <= testbench.mpeg2.framestore.framestore_response.vbr_wr_dta;
    end
  end
`endif

  /* latch the popped request as soon as it is presented */
  always @(posedge clk)
    if (~rst) begin
      cmd_r  <= CMD_NOOP;
      addr_r <= 22'b0;
      dta_r  <= 64'b0;
    end else if ((state == S_IDLE) && mem_req_rd_valid) begin
      cmd_r  <= mem_req_rd_cmd;
      addr_r <= mem_req_rd_addr;
      dta_r  <= mem_req_rd_dta;
    end

  /* pop mem_req_rd fifo: hold rd_en while idle, same protocol as
   * mem2axi_bridge.v, so a request is captured the cycle it becomes valid. */
  always @(posedge clk)
    if (~rst) mem_req_rd_en <= 1'b0;
    else mem_req_rd_en <= (next == S_IDLE);

  always @(posedge clk)
    if (~rst) cnt <= 32'd0;
    else if (state == S_LATCH) cnt <= LATENCY;
    else if ((state == S_BUSY) && (cnt != 32'd0)) cnt <= cnt - 32'd1;

  /*
   * Memory write -- commits at the end of the modeled latency, not
   * immediately like plain mem_ctl.v.
   */
  always @(posedge clk)
    if ((state == S_BUSY) && (cnt == 32'd0) && (cmd_r == CMD_WRITE))
      mem[addr_r] <= dta_r;

  /*
   * Memory read -- data captured at the end of the modeled latency,
   * presented (mem_res_wr_en) once in S_RESP, respecting
   * mem_res_wr_almost_full exactly like mem2axi_bridge.v's S_RESP state.
   */
  always @(posedge clk)
    if (~rst) mem_res_wr_dta <= 64'b0;
    else if ((state == S_BUSY) && (cnt == 32'd0) && (cmd_r == CMD_READ))
      mem_res_wr_dta <= mem[addr_r];

  always @(posedge clk)
    if (~rst) mem_res_wr_en <= 1'b0;
    else mem_res_wr_en <= (state == S_RESP) && ~mem_res_wr_almost_full;

  /*
   * Trap error address
   */
  always @(posedge clk)
    if ((state == S_LATCH) && ((cmd_r == CMD_WRITE) || (cmd_r == CMD_READ))
                            && (addr_r == ADDR_ERR))
      begin
        $display("%m *** error: access to ADDR_ERR ***");
`ifdef DUMP_FRAMESTORE
        write_framestore;
`endif
      end

`ifdef DEBUG
  always @(posedge clk)
    if ((state == S_LATCH))
      case (cmd_r)
        CMD_NOOP:    #0 $display("%m\tCMD_NOOP    ");
        CMD_REFRESH: #0 $display("%m\tCMD_REFRESH ");
        CMD_READ:    #0 $display("%m\tCMD_READ    mem[%6h] (latency %0d)", addr_r, LATENCY);
        CMD_WRITE:   #0 $display("%m\tCMD_WRITE   mem[%6h] = %h (latency %0d)", addr_r, dta_r, LATENCY);
        default      #0 $display("%m\t*** Error: unknown command %d ***", cmd_r);
      endcase
`endif

  /*
    write all of memory to stdout
   */

  task mem_dump;
  integer mem_dump;

    begin
      $display("%m\t\tmemory dump: begin");
      for (mem_dump = 22'h0; mem_dump <= 22'h3fffff; mem_dump = mem_dump + 1)
        if (mem[mem_dump] !== 64'bx)
          begin
            $display("%m\t\tmemory dump: %5h: %8h", mem_dump, mem[mem_dump]);
          end
      $display("%m\t\tmemory dump: end");
    end
  endtask

`ifdef DUMP_FRAMESTORE

  wire [13:0]width;
  wire [13:0]height;
  reg  [13:0]mb_width;
  reg  [13:0]mb_height;
  wire [13:0]display_horizontal_size;
  wire [13:0]display_vertical_size;
  wire  [1:0]picture_structure;
  wire  [1:0]chroma_format;
  wire       update_picture_buffers;
  wire [12:0]macroblock_address;

  assign width                   = testbench.mpeg2.vld.horizontal_size;
  assign height                  = testbench.mpeg2.vld.vertical_size;
  assign display_horizontal_size = testbench.mpeg2.vld.display_horizontal_size;
  assign display_vertical_size   = testbench.mpeg2.vld.display_vertical_size;
  assign picture_structure       = testbench.mpeg2.vld.picture_structure;
  assign chroma_format           = testbench.mpeg2.vld.chroma_format;
  assign update_picture_buffers  = testbench.mpeg2.update_picture_buffers;
  assign macroblock_address      = testbench.mpeg2.macroblock_address;

  always @*
    begin
      mb_width  <= (width  + 15) >> 4;
      mb_height <= (height + 15) >> 4;
    end

  integer frame_number = 0;

  always @(posedge update_picture_buffers)
    frame_number <= frame_number + 1;

  reg [31:0]fname_cnt = "0000";

  task write_framestore;

    reg [32*8:1]fname;
    integer fp;
    integer w;
    integer h;

    `include "vld_codes.v"

    begin
      if ((^mb_width !== 1'bx) && (^mb_height !== 1'bx)) // check image size valid
        begin
          fname = {"framestore_", fname_cnt, ".ppm"};
          if (fname_cnt[7:0] != "9")
            fname_cnt[7:0] = fname_cnt[7:0] + 1;
          else
            begin
              fname_cnt[7:0] = "0";
              if (fname_cnt[15:8] != "9")
                fname_cnt[15:8] = fname_cnt[15:8] + 1;
              else
                begin
                  fname_cnt[15:8] = "0";
                  if (fname_cnt[23:16] != "9")
                    fname_cnt[23:16] = fname_cnt[23:16] + 1;
                  else
                    begin
                      fname_cnt[23:16] = "0";
                      if (fname_cnt[31:24] != "9")
                        fname_cnt[31:24] = fname_cnt[31:24] + 1;
                      else
                        fname_cnt[31:24] = "0";
                    end
                end
            end
          fp=$fopen(fname, "w");
          if (fp == 0)
            begin
              $display ("%m\t*** error opening file ***");
              $finish;
            end
          $fwrite(fp, "P3\n");
          $timeformat(-3, 2, " ms", 8);
          $fwrite(fp, "# mpeg2 framestore dump @ %t\n", $time);
          $display("%m\tdumping framestore to %s @ %t", fname, $time);
          $timeformat(-9, 2, " ns", 20);
          $fwrite(fp, "# frame number %d\n", frame_number);
          $fwrite(fp, "# horizontal_size %d\n", width);
          $fwrite(fp, "# vertical_size %d\n", height);
          $fwrite(fp, "# display_horizontal_size %d\n", display_horizontal_size);
          $fwrite(fp, "# display_vertical_size %d\n", display_vertical_size);
          $fwrite(fp, "# mb_width %d\n", mb_width);
          $fwrite(fp, "# mb_height %d\n", mb_height);
          if (picture_structure==FRAME_PICTURE)
            $fwrite(fp, "# picture_structure frame picture\n");
          else
            $fwrite(fp, "# picture_structure field picture\n");

          if (chroma_format == CHROMA420)
            $fwrite(fp, "# chroma_format 4:2:0\n");
          else
            $fwrite(fp, "# chroma_format %d\n", chroma_format);

          $fwrite(fp, "%d %d 255\n", width, height * 9 + 26);

          write_mb (fp, 4, FRAME_0_Y,  mb_width, mb_height);
          write_mb (fp, 1, FRAME_0_CR, mb_width, mb_height);
          write_mb (fp, 1, FRAME_0_CB, mb_width, mb_height);

          write_mb (fp, 4, FRAME_1_Y,  mb_width, mb_height);
          write_mb (fp, 1, FRAME_1_CR, mb_width, mb_height);
          write_mb (fp, 1, FRAME_1_CB, mb_width, mb_height);

          write_mb (fp, 4, FRAME_2_Y,  mb_width, mb_height);
          write_mb (fp, 1, FRAME_2_CR, mb_width, mb_height);
          write_mb (fp, 1, FRAME_2_CB, mb_width, mb_height);

          write_mb (fp, 4, FRAME_3_Y,  mb_width, mb_height);
          write_mb (fp, 1, FRAME_3_CR, mb_width, mb_height);
          write_mb (fp, 1, FRAME_3_CB, mb_width, mb_height);

          write_mb (fp, 4, OSD,        mb_width, mb_height);
          $fwrite(fp, "# not truncated\n");
          $fclose(fp);
        end
    end
  endtask

  task write_mb;

    input integer fp;
    input  [2:0]blocks;
    input [21:0]base_address;
    input [15:0]mb_width;
    input [15:0]mb_height;

    reg [63:0]row;

    integer   h;
    integer   f;
    integer   r;
    integer   s;
    integer   w;
    reg [21:0]addr;

    begin
      for (w = 0; w < 2 * mb_width; w = w + 1)
        begin
          for (s = 0; s < 24; s = s + 1)
            $fwrite(fp, " 255");
          $fwrite(fp, "\n");
        end
      addr = base_address;
      case (blocks)
        4:
          for (h = 0; h < 16 * mb_height; h = h + 1)
            begin
              for (w = 0; w < 2 * mb_width; w = w + 1)
                begin
                  write_row (fp, addr);
                  addr = addr + 1;
                end
            end
        1:
          for (h = 0; h < 8 * mb_height; h = h + 1)
            begin
              for (w = 0; w < mb_width; w = w + 1)
                begin
                  write_row (fp, addr);
                  addr = addr + 1;
                end
              for (w = 0; w < mb_width; w = w + 1)
                begin
                  for (s = 0; s < 24; s = s + 1)
                    $fwrite(fp, " 255");
                  $fwrite(fp, "\n");
                end
            end
        default
            begin
              $display("%m\tchroma format not implemented\n");
            end
      endcase
      for (w = 0; w < 2 * mb_width; w = w + 1)
        begin
          for (s = 0; s < 24; s = s + 1)
            $fwrite(fp, " 255");
          $fwrite(fp, "\n");
        end
    end
  endtask

  task write_row;

    input integer fp;
    input [21:0]address;

    reg  [63:0]dta;

    reg  signed [7:0]pixel_0;
    reg  signed [7:0]pixel_1;
    reg  signed [7:0]pixel_2;
    reg  signed [7:0]pixel_3;
    reg  signed [7:0]pixel_4;
    reg  signed [7:0]pixel_5;
    reg  signed [7:0]pixel_6;
    reg  signed [7:0]pixel_7;

    reg  signed [8:0]pixval_0;
    reg  signed [8:0]pixval_1;
    reg  signed [8:0]pixval_2;
    reg  signed [8:0]pixval_3;
    reg  signed [8:0]pixval_4;
    reg  signed [8:0]pixval_5;
    reg  signed [8:0]pixval_6;
    reg  signed [8:0]pixval_7;

    begin
      dta = mem[address];

      {pixel_0, pixel_1, pixel_2, pixel_3, pixel_4, pixel_5, pixel_6, pixel_7} = dta;

      pixval_0 = {pixel_0[7], pixel_0};
      pixval_1 = {pixel_1[7], pixel_1};
      pixval_2 = {pixel_2[7], pixel_2};
      pixval_3 = {pixel_3[7], pixel_3};
      pixval_4 = {pixel_4[7], pixel_4};
      pixval_5 = {pixel_5[7], pixel_5};
      pixval_6 = {pixel_6[7], pixel_6};
      pixval_7 = {pixel_7[7], pixel_7};

      pixval_0 = pixval_0 + 9'sd128;
      pixval_1 = pixval_1 + 9'sd128;
      pixval_2 = pixval_2 + 9'sd128;
      pixval_3 = pixval_3 + 9'sd128;
      pixval_4 = pixval_4 + 9'sd128;
      pixval_5 = pixval_5 + 9'sd128;
      pixval_6 = pixval_6 + 9'sd128;
      pixval_7 = pixval_7 + 9'sd128;

      if (^pixval_0 === 1'bx) $fwrite(fp, "   0  127    0 "); else $fwrite(fp, "%4d %4d %4d ", pixval_0, pixval_0, pixval_0);
      if (^pixval_1 === 1'bx) $fwrite(fp, "   0  127    0 "); else $fwrite(fp, "%4d %4d %4d ", pixval_1, pixval_1, pixval_1);
      if (^pixval_2 === 1'bx) $fwrite(fp, "   0  127    0 "); else $fwrite(fp, "%4d %4d %4d ", pixval_2, pixval_2, pixval_2);
      if (^pixval_3 === 1'bx) $fwrite(fp, "   0  127    0 "); else $fwrite(fp, "%4d %4d %4d ", pixval_3, pixval_3, pixval_3);
      if (^pixval_4 === 1'bx) $fwrite(fp, "   0  127    0 "); else $fwrite(fp, "%4d %4d %4d ", pixval_4, pixval_4, pixval_4);
      if (^pixval_5 === 1'bx) $fwrite(fp, "   0  127    0 "); else $fwrite(fp, "%4d %4d %4d ", pixval_5, pixval_5, pixval_5);
      if (^pixval_6 === 1'bx) $fwrite(fp, "   0  127    0 "); else $fwrite(fp, "%4d %4d %4d ", pixval_6, pixval_6, pixval_6);
      if (^pixval_7 === 1'bx) $fwrite(fp, "   0  127    0 "); else $fwrite(fp, "%4d %4d %4d ", pixval_7, pixval_7, pixval_7);
      $fwrite(fp, "\n");

    end
  endtask

`ifndef DUMP_FRAMESTORE_OFTEN
  always @(posedge clk)
    if ((state == S_LATCH) && (cmd_r == CMD_WRITE)
                            && ((addr_r == FRAME_0_Y) || (addr_r == FRAME_1_Y) || (addr_r == FRAME_2_Y) || (addr_r == FRAME_3_Y)))
      write_framestore;
`endif

`ifdef DUMP_FRAMESTORE_OFTEN
  always @(macroblock_address)
    if ((^macroblock_address !== 1'bx) && (macroblock_address % 200) == 0) write_framestore;
`endif

  always @(macroblock_address)
    if (^macroblock_address !== 1'bx)
      $strobe("%m\tmacroblock_address: %d", macroblock_address);

`endif

endmodule
/* not truncated */
