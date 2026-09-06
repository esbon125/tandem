/* 
 * mem_ctl.v
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
 * Dummy memory controller, used for simulation.
 * Useful as template for writing your own memory controller.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

// initialize memory
`undef MEMORY_INIT
//`define MAGIC_NUMBER 1

/*
 * Framestore dumping.
 *
 * `DUMP_FRAMESTORE` provides the hierarchical taps (width, mb_width, ...) and the
 * dump tasks; it does not by itself write anything. Which dump is written, and
 * when, is selected by the three switches below. Define them from the Makefile
 * (`make DUMPFLAGS=-DDUMP_FRAMESTORE_PPM ...`) rather than editing this file.
 *
 * DUMP_FRAMESTORE_RAW    write the framestore to 'fs_NNNN.bin' (raw little-endian
 *                        64-bit words, byte-identical to what a DDR dump of the
 *                        same region looks like on hardware) plus a metadata
 *                        sidecar 'fs_NNNN.txt', every time the picture buffers
 *                        are updated. This is the dump tools/framecmp reads; it
 *                        deliberately uses the same on-disk format for sim and
 *                        for hardware so a single extractor serves both.
 * DUMP_FRAMESTORE_PPM    write the human-readable 'framestore_NNNN.ppm' stack of
 *                        all four frames + OSD every time a frame's Y base is
 *                        written. ~45 mbyte of ascii per dump; debugging only.
 * DUMP_FRAMESTORE_OFTEN  as DUMP_FRAMESTORE_PPM, but every 200 macroblocks.
 */
`undef DUMP_FRAMESTORE
`define DUMP_FRAMESTORE 1

`ifndef DUMP_FRAMESTORE_PPM
`ifndef DUMP_FRAMESTORE_OFTEN
`ifndef DUMP_FRAMESTORE_RAW
`define DUMP_FRAMESTORE_RAW 1
`endif
`endif
`endif

// number of raw dumps to write before giving up. Each is a dozen mbyte.
`define DUMP_FRAMESTORE_RAW_MAX 8

module mem_ctl(
  clk, rst,
  mem_req_rd_cmd, mem_req_rd_addr, mem_req_rd_dta, mem_req_rd_en, mem_req_rd_valid,
  mem_res_wr_dta, mem_res_wr_en, mem_res_wr_almost_full
  );

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

  reg [63:0]mem[0:END_OF_MEM]; /* memory, 64-bit wide. Simulation only, not synthesizable. Size depends upon mpeg2 profile. Up to 32 mbyte large */

  always @(posedge clk)
    if (~rst) mem_req_rd_en <= 1'b0;
    else mem_req_rd_en <= ~mem_res_wr_almost_full;

  /* timing simulation: add #2 = 2 ns hold time to mem_res_wr_en and mem_res_wr_dta */

  always @(posedge clk)
    if (~rst) mem_res_wr_en <= #2 1'b0;
    else if (mem_req_rd_valid)
      case (mem_req_rd_cmd)
        CMD_NOOP:    mem_res_wr_en <= #2 1'b0;
        CMD_REFRESH: mem_res_wr_en <= #2 1'b0;
        CMD_READ:    mem_res_wr_en <= #2 1'b1;
        CMD_WRITE:   mem_res_wr_en <= #2 1'b0;
        default      mem_res_wr_en <= #2 1'b0;
      endcase
    else mem_res_wr_en <= #2 1'b0;
  
  /*
   * Memory read 
   */
  always @(posedge clk)
    if (~rst) mem_res_wr_dta <= #2 63'b0;
    else if (mem_req_rd_valid)
      case (mem_req_rd_cmd)
        CMD_NOOP:    mem_res_wr_dta <= #2 63'b0;
        CMD_REFRESH: mem_res_wr_dta <= #2 63'b0;
        CMD_READ:    mem_res_wr_dta <= #2 mem[mem_req_rd_addr];
        CMD_WRITE:   mem_res_wr_dta <= #2 63'b0;
        default      mem_res_wr_dta <= #2 63'b0;
      endcase
    else mem_res_wr_dta <= #2 63'b0;

  /*
   * Memory write 
   */
  always @(posedge clk)
    if (mem_req_rd_valid && (mem_req_rd_cmd == CMD_WRITE)) mem[mem_req_rd_addr] <= mem_req_rd_dta;

  /*
   * Trap error address
   */
  always @(posedge clk)
    if (mem_req_rd_valid && ((mem_req_rd_cmd == CMD_WRITE) || (mem_req_rd_cmd == CMD_READ))
                         && (mem_req_rd_addr == ADDR_ERR)) 
			 begin
			   $display("%m *** error: access to ADDR_ERR ***");
`ifdef DUMP_FRAMESTORE_PPM
			   write_framestore;
`endif
			   //$stop;
			 end


`ifdef DEBUG
  always @(posedge clk)
    if (mem_req_rd_valid)
      case (mem_req_rd_cmd)
        CMD_NOOP:    #0 $display("%m\tCMD_NOOP    ");
        CMD_REFRESH: #0 $display("%m\tCMD_REFRESH ");
        CMD_READ:    #0 $display("%m\tCMD_READ    mem[%6h] : %h", mem_req_rd_addr, mem[mem_req_rd_addr]);
        CMD_WRITE:   #0 $display("%m\tCMD_WRITE   mem[%6h] = %h", mem_req_rd_addr, mem_req_rd_dta);
        default      #0 $display("%m\t*** Error: unknown command %d ***", mem_req_rd_cmd);
      endcase

`endif

`ifdef MEMORY_INIT
  /* 
   Initialize memory at powerup. Optional.
   */

  integer addr;

  initial
    begin
      for ( addr = 0; addr < END_OF_MEM; addr = addr + 1)
        mem[addr] = {8{8'd128}}; // initialize memory to all zeroes in yuv; all zeroes in yuv is a dull green
    end
`endif

  /*
    write all of memory to stdout
   */

  task mem_dump;
  /*
   * Dump memory.
   * Used in testbench.
   */
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

  /*
   * count frames
   */

  integer frame_number = 0;

  always @(posedge update_picture_buffers)
    frame_number <= frame_number + 1;

  /*
   * Create a bitmap file of the framestore.  Bitmap is in Portable Pixmap format (ppm).
   * This is a task used in debugging.
   */

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
	  /* new filename */
	  fname = {"framestore_", fname_cnt, ".ppm"};
          /* implement a counter for string "fname_cnt" */
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
          // open new file
          fp=$fopen(fname, "w");
          if (fp == 0) 
            begin
              $display ("%m\t*** error opening file ***");
              $finish;
            end
          $fwrite(fp, "P3\n"); // Portable pixmap, ascii.
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

    input integer fp;            // file pointer to write to 
    input  [2:0]blocks;        // blocks per macroblock
    input [21:0]base_address;  // base address of lumi/chromi region in memory
    input [15:0]mb_width;      // width in macroblocks
    input [15:0]mb_height;     // height in macroblocks

    reg [63:0]row;
   
    reg  [7:0]pixel_0;
    reg  [7:0]pixel_1;
    reg  [7:0]pixel_2;
    reg  [7:0]pixel_3;
    reg  [7:0]pixel_4;
    reg  [7:0]pixel_5;
    reg  [7:0]pixel_6;
    reg  [7:0]pixel_7;
 
//    integer   fp;
    integer   h;
    integer   f;
    integer   r;
    integer   s;
    integer   w;
    reg [21:0]addr;
 
    begin
      /* white separator line */
      for (w = 0; w < 2 * mb_width; w = w + 1) 
        begin
          for (s = 0; s < 24; s = s + 1)
            $fwrite(fp, " 255");
          $fwrite(fp, "\n");
        end
      /* this code needs to be kept synchronized to memory_address */
      addr = base_address;
      case (blocks)
        4:
          for (h = 0; h < 16 * mb_height; h = h + 1)
            begin
              for (w = 0; w < 2 * mb_width; w = w + 1) 
                begin
                  write_row (fp, addr); /* block 0 */
                  addr = addr + 1;
                end
            end
        1:
          for (h = 0; h < 8 * mb_height; h = h + 1)
            begin
              for (w = 0; w < mb_width; w = w + 1) 
                begin
                  write_row (fp, addr); /* block 0 */
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
      /* white separator line */
      for (w = 0; w < 2 * mb_width; w = w + 1) 
        begin
          for (s = 0; s < 24; s = s + 1)
            $fwrite(fp, " 255");
          $fwrite(fp, "\n");
        end
    end
  endtask        

  task write_row;

    input integer fp;       // file pointer to write to 
    input [21:0]address;  // address of block row

    reg  [63:0]dta;

//    integer     fp;

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

      /* check for undefined pixels, replace with green to draw attention */
      if (^pixval_0 === 1'bx) $fwrite(fp, "   0  127    0 "); else $fwrite(fp, "%4d %4d %4d ", pixval_0, pixval_0, pixval_0);
      if (^pixval_1 === 1'bx) $fwrite(fp, "   0  127    0 "); else $fwrite(fp, "%4d %4d %4d ", pixval_1, pixval_1, pixval_1);
      if (^pixval_2 === 1'bx) $fwrite(fp, "   0  127    0 "); else $fwrite(fp, "%4d %4d %4d ", pixval_2, pixval_2, pixval_2);
      if (^pixval_3 === 1'bx) $fwrite(fp, "   0  127    0 "); else $fwrite(fp, "%4d %4d %4d ", pixval_3, pixval_3, pixval_3);
      if (^pixval_4 === 1'bx) $fwrite(fp, "   0  127    0 "); else $fwrite(fp, "%4d %4d %4d ", pixval_4, pixval_4, pixval_4);
      if (^pixval_5 === 1'bx) $fwrite(fp, "   0  127    0 "); else $fwrite(fp, "%4d %4d %4d ", pixval_5, pixval_5, pixval_5);
      if (^pixval_6 === 1'bx) $fwrite(fp, "   0  127    0 "); else $fwrite(fp, "%4d %4d %4d ", pixval_6, pixval_6, pixval_6);
      if (^pixval_7 === 1'bx) $fwrite(fp, "   0  127    0 "); else $fwrite(fp, "%4d %4d %4d ", pixval_7, pixval_7, pixval_7);
//      $fwrite(fp, "# mem[%6h]: %8h", address, dta); /* Some ppm picture viewers do not accept comment in mid-image */
      $fwrite(fp, "\n");

    end
  endtask

`ifdef DUMP_FRAMESTORE_PPM
  /* trigger framestore dump when updating picture buffers */

/*
  always @(posedge update_picture_buffers)
    write_framestore;
*/

  always @(posedge clk)
    if (mem_req_rd_valid && (mem_req_rd_cmd == CMD_WRITE)
                         && ((mem_req_rd_addr == FRAME_0_Y) || (mem_req_rd_addr == FRAME_1_Y) || (mem_req_rd_addr == FRAME_2_Y) || (mem_req_rd_addr == FRAME_3_Y)))
      write_framestore;
`endif

`ifdef DUMP_FRAMESTORE_OFTEN
  /* trigger framestore dump every 200 macroblocks */
  always @(macroblock_address)
    if ((^macroblock_address !== 1'bx) && (macroblock_address % 200) == 0) write_framestore;
`endif

`ifdef DUMP_FRAMESTORE_RAW

  /*
   * Raw framestore dump.
   *
   * Writes memory words [FRAME_0_Y, OSD) to 'fs_NNNN.bin' as raw little-endian
   * 64-bit words: word w lands at file offset 8*w, and within that word bit [7:0]
   * is the first byte written. That is exactly the byte order a hardware dump of
   * the same DDR region has, so tools/framecmp/framecmp.py extracts sim and
   * hardware frames with the same code path -- the point being that the
   * extraction rules (signed offset-128 pixels, reversed pixel order inside a
   * word, plane strides) get validated once, in simulation, against the
   * reference decoder, and are then reused verbatim on hardware.
   *
   * The companion 'fs_NNNN.txt' records everything the extractor needs that is
   * not in the bits: image geometry, base addresses, and which frame buffer the
   * display path is about to read.
   */

  reg [31:0]raw_fname_cnt = "0000";
  integer   raw_dump_count = 0;

  task write_framestore_raw;

    reg [32*8:1]fname;
    integer fp;
    integer addr;
    reg [63:0]dta;

    `include "vld_codes.v"

    begin
      if ((^mb_width === 1'bx) || (^mb_height === 1'bx))
        $display("%m\traw framestore dump skipped: image size not valid yet");
      else if (raw_dump_count >= `DUMP_FRAMESTORE_RAW_MAX)
        ; /* already wrote as many as asked for */
      else
        begin
          raw_dump_count = raw_dump_count + 1;

          /* metadata sidecar */
          fname = {"fs_", raw_fname_cnt, ".txt"};
          fp = $fopen(fname, "w");
          if (fp == 0)
            begin
              $display ("%m\t*** error opening file ***");
              $finish;
            end
          $fwrite(fp, "# mpeg2fpga raw framestore dump\n");
          $fwrite(fp, "source simulation\n");
          $timeformat(-3, 2, " ms", 8);
          $fwrite(fp, "time %0t\n", $time);
          $timeformat(-9, 2, " ns", 20);
          $fwrite(fp, "dump %0d\n", raw_dump_count - 1);
          $fwrite(fp, "frame_number %0d\n", frame_number);
          $fwrite(fp, "horizontal_size %0d\n", width);
          $fwrite(fp, "vertical_size %0d\n", height);
          $fwrite(fp, "display_horizontal_size %0d\n", display_horizontal_size);
          $fwrite(fp, "display_vertical_size %0d\n", display_vertical_size);
          $fwrite(fp, "mb_width %0d\n", mb_width);
          $fwrite(fp, "mb_height %0d\n", mb_height);
          $fwrite(fp, "picture_structure %0d\n", picture_structure);
          $fwrite(fp, "frame_picture %0d\n", (picture_structure == FRAME_PICTURE) ? 1 : 0);
          $fwrite(fp, "chroma_format %0d\n", chroma_format);
          $fwrite(fp, "output_frame %0d\n", testbench.mpeg2.motcomp.output_frame);
          /* file offset 0 corresponds to this memory word address */
          $fwrite(fp, "base_word_address %0d\n", FRAME_0_Y);
          $fwrite(fp, "word_count %0d\n", OSD - FRAME_0_Y);
          $fwrite(fp, "word_bytes 8\n");
          $fwrite(fp, "byteorder little\n");
          $fclose(fp);

          /* the framestore itself */
          fname = {"fs_", raw_fname_cnt, ".bin"};
          fp = $fopen(fname, "wb");
          if (fp == 0)
            begin
              $display ("%m\t*** error opening file ***");
              $finish;
            end
          $display("%m\tdumping raw framestore to %0s @ %0t", fname, $time);
          for (addr = FRAME_0_Y; addr < OSD; addr = addr + 1)
            begin
              dta = mem[addr];
              $fwrite(fp, "%u", dta[31:0]);
              $fwrite(fp, "%u", dta[63:32]);
            end
          $fclose(fp);

          /* implement a counter for string "raw_fname_cnt" */
          if (raw_fname_cnt[7:0] != "9")
            raw_fname_cnt[7:0] = raw_fname_cnt[7:0] + 1;
          else
            begin
              raw_fname_cnt[7:0] = "0";
              if (raw_fname_cnt[15:8] != "9")
                raw_fname_cnt[15:8] = raw_fname_cnt[15:8] + 1;
              else
                begin
                  raw_fname_cnt[15:8] = "0";
                  if (raw_fname_cnt[23:16] != "9")
                    raw_fname_cnt[23:16] = raw_fname_cnt[23:16] + 1;
                  else
                    begin
                      raw_fname_cnt[23:16] = "0";
                      raw_fname_cnt[31:24] = raw_fname_cnt[31:24] + 1;
                    end
                end
            end
        end
    end
  endtask

  /*
   * When to dump.
   *
   * update_picture_buffers marks the end of a picture at the *vld*. It is not a
   * safe moment to read the framestore: the reconstruction path behind it (mvec
   * fifo -> picbuf -> dst fifo -> recon -> framestore_request) still has a good
   * part of that picture in flight, and dumping there yields a torn frame --
   * which then shows up as a large MAD and gets misread as a decoder bug.
   *
   * So update_picture_buffers only *arms* a dump; the dump happens once the
   * framestore has gone quiet, i.e. no write to the frame region for
   * RAW_SETTLE_CYCLES consecutive clocks.
   */

  parameter RAW_SETTLE_CYCLES = 20000;

  reg        raw_dump_armed = 1'b0;
  reg        raw_upb_delayed = 1'b0;
  integer    raw_idle_count = 0;
  wire       framestore_written = mem_req_rd_valid && (mem_req_rd_cmd == CMD_WRITE) && (mem_req_rd_addr < OSD);

  always @(posedge clk)
    begin
      raw_upb_delayed <= update_picture_buffers;

      if (update_picture_buffers && ~raw_upb_delayed)
        begin
          /* rising edge of update_picture_buffers: arm, and restart the timer */
          raw_dump_armed <= 1'b1;
          raw_idle_count <= 0;
        end
      else if (framestore_written)
        raw_idle_count <= 0;
      else if (raw_idle_count < RAW_SETTLE_CYCLES)
        begin
          raw_idle_count <= raw_idle_count + 1;
          if (raw_dump_armed && (raw_idle_count == RAW_SETTLE_CYCLES - 1))
            begin
              raw_dump_armed <= 1'b0;
              write_framestore_raw;
            end
        end
    end

`endif

  always @(macroblock_address)
    if (^macroblock_address !== 1'bx)
      $strobe("%m\tmacroblock_address: %d", macroblock_address);

`endif

endmodule
/* not truncated */
