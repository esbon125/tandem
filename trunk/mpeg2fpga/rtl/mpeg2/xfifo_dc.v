//Wrapper for generic_fifo_dc and microchip FIFO (COREFIFO)

/*
 * Reset-domain fix (2026-08-26, mem_req_wr_almost_full real-hardware stall
 * investigation -- see docs/bringup and fase7a_size_zero_vld_stall):
 * used to take a single `rst`, fed unchanged into both COREFIFO's WRESET_N
 * and RRESET_N below. COREFIFO's own async/corefifo_async.v -- read with
 * this project's actual params (SYNC:0, SYNC_RESET:1) -- reduces
 * sresetn_wclk/sresetn_rclk to WRESET_N/RRESET_N *directly*, sampled as a
 * plain synchronous condition by every flop in each clock domain (the
 * write-pointer register on wclk, the read-pointer register on rclk, their
 * cross-domain Gray-code synchronizers, etc.) -- there is no internal
 * re-synchronization stage in this configuration (the resetsync submodule
 * instances that would do that are dead/commented-out code in the
 * generated COREFIFO.v for this param set). So RRESET_N must already be
 * synchronous to RCLOCK, and WRESET_N to WCLOCK, when they arrive here --
 * every caller in this codebase only ever had ONE reset, synchronized to
 * clk (mpeg2video's sync_rst), which is only correct for whichever side of
 * a given instance happens to sit on clk. For fifo_mem_req_dc_88x64
 * (WCLOCK=clk, RCLOCK=mem_clk), RRESET_N was being driven by a clk-domain
 * signal sampled synchronously by mem_clk-domain flops -- a textbook CDC
 * violation: sync_rst's release edge has no defined timing relationship to
 * mem_clk, so the read-pointer register (and everything downstream of it,
 * including whatever feeds AFULL/prog_full) can end up in an inconsistent
 * state after reset, independent of the FIFO's actual occupancy -- matching
 * the observed symptom (mem_req_wr_almost_full stuck true forever,
 * unrelated to how many requests are actually in flight -- see the
 * dbg_mem_req_wr_push_cnt/dbg_mem_req_rd_pop_cnt instrumentation added
 * alongside this fix). Now takes wr_rst (must be synchronous to wr_clk)
 * and rd_rst (must be synchronous to rd_clk) separately -- callers must
 * supply the correctly-domain-matched reset for each (framestore.v now
 * has a real mem_rst input for exactly this).
 */
module xfifo_dc (
		 wr_rst,
		 rd_rst,
		 wr_clk,
		 din,
		 wr_en,
		 full,
		 wr_ack,
		 overflow,
		 prog_full,
		 rd_clk,
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

   parameter USE_GENERIC = 1'b0; //Use generic_fifo_dc from OpenCores, deprecated
   parameter check_valid=1;    /* assign x's to fifo output when valid is not asserted */
   
   input          wr_rst;      /* low active sync master reset, wr_clk domain */
   input          rd_rst;      /* low active sync master reset, rd_clk domain */
   /* read port */
   input          rd_clk;      /* read clock. positive edge active */
   output [dta_width-1:0] dout; /* data output */
   input 		  rd_en;       /* read enable */
   output 		  empty;       /* asserted if fifo is empty; no additional reads can be performed */
   output 		  valid;       /* valid (read acknowledge): indicates rd_en was asserted during previous clock cycle and data was succesfully read from fifo and placed on dout */
   output 		  underflow;   /* underflow (read error): indicates rd_en was asserted during previous clock cycle but no data was read from fifo because fifo was empty */
   output 		  prog_empty;  /* indicates the fifo has prog_thresh entries, or less. threshold for asserting prog_empty is prog_thresh */
   /* write port */
   input 		  wr_clk;      /* write clock. positive edge active */
   input [dta_width-1:0]  din;  /* data input */
   input 		  wr_en;       /* write enable */
   output 		  full;        /* asserted if fifo is full; no additional writes can be performed */
   output 		  overflow;    /* overflow (write error): indicates wr_en was asserted during previous clock cycle but no data was written to fifo because fifo was full */
   output 		  wr_ack;      /* write acknowledge: indicates wr_en was asserted during previous clock cycle and data was succesfully written to fifo */
   output 		  prog_full;   /* indicates the fifo has prog_thresh free entries, or less, left. threshold for asserting prog_full is 2^addr_width - prog_thresh  */
   
   /* Writing when the fifo is full, or reading while the fifo is empty, does not destroy the contents of the fifo. */
   
   /* Implementation using opencores generic_fifo */
   wire 		  fifo_full;
   wire 		  fifo_empty;
   wire 		  fifo_full_n;
   wire 		  fifo_empty_n;

   reg 			  fifo_valid;
   reg 			  fifo_underflow;
   reg 			  fifo_wr_ack;
   reg 			  fifo_overflow;

   /* Fase 7a fix (2026-08-22): these were unconditional assigns, but
    * fifo_empty/fifo_full/fifo_empty_n/fifo_full_n/fifo_valid/fifo_underflow/
    * fifo_wr_ack/fifo_overflow are only ever driven inside the
    * USE_GENERIC==1'b1 branch below (generic_fifo_dc path). With
    * USE_GENERIC==0 (the real CoreFIFO path used for dta_width 35/64/88),
    * those regs/wires are never assigned -- fifo_valid/fifo_underflow/
    * fifo_wr_ack/fifo_overflow stay at their power-up 'bx forever -- while
    * the CoreFIFO instance below *also* drives valid/underflow/wr_ack/
    * overflow directly via .DVLD/.UNDERFLOW/.WACK/.OVERFLOW on the very same
    * nets. That's two drivers on one wire (a real, constant X vs the FIFO's
    * real value), which is undefined behavior. Gating these assigns behind
    * the same generate condition as their sources makes each net have
    * exactly one driver in either configuration -- in the USE_GENERIC==0
    * case, the CoreFIFO instance's own port connections are the sole driver,
    * same as empty/full/prog_empty/prog_full already effectively were
    * (fifo_empty/fifo_full/etc float at Z when unused, which don't contend). */
   generate
   if (USE_GENERIC == 1'b1) begin
      assign empty = fifo_empty;
      assign full = fifo_full;
      assign prog_empty = fifo_empty_n;
      assign prog_full = fifo_full_n;
      assign valid = fifo_valid;
      assign underflow = fifo_underflow;
      assign wr_ack = fifo_wr_ack;
      assign overflow = fifo_overflow;

      always @(posedge rd_clk)
	if (~rd_rst) fifo_valid <= 1'b0;
	else fifo_valid <= rd_en && ~fifo_empty;

   always @(posedge rd_clk)
     if (~rd_rst) fifo_underflow <= 1'b0;
     else fifo_underflow <= rd_en && fifo_empty;

   always @(posedge wr_clk)
     if (~wr_rst) fifo_wr_ack <= 1'b0;
     else fifo_wr_ack <= wr_en && ~fifo_full;

   always @(posedge wr_clk)
     if (~wr_rst) fifo_overflow <= 1'b0;
     else fifo_overflow <= wr_en && fifo_full;
   end
   endgenerate

   generate
      if (USE_GENERIC == 1'b1)
	begin
	   generic_fifo_dc
	     #(.aw(addr_width),
	       .dw(dta_width),
	       .n(prog_thresh))
	   gfifo_dc (
		     .rd_clk(rd_clk),
		     .wr_clk(wr_clk),
		     .rst(wr_rst),
		     .clr(1'b0), 
		     .din(din), 
		     .we(wr_en && ~fifo_full), 
		     .dout(dout), 
		     .re(rd_en && ~fifo_empty), 
		     .full(fifo_full), 
		     .empty(fifo_empty), 
		     .full_n(fifo_full_n), 
		     .empty_n(fifo_empty_n), 
		     .level()
		     );
	end
      else
	begin
	   if (dta_width == 35) begin
	      fifo_pixel_stream_dc_35x1024 
		pixel_fifo_dc(
			      //Inputs
			      .DATA(din),
			      .RCLOCK(rd_clk),
			      .RE(rd_en),
			      .RRESET_N(rd_rst),
			      .WCLOCK(wr_clk),
			      .WE(wr_en),
			      .WRESET_N(wr_rst),
			      // Outputs
			      .AEMPTY(prog_empty),
			      .AFULL(prog_full),
			      .DVLD(valid),
			      .EMPTY(empty),
			      .FULL(full),
			      .OVERFLOW(overflow),
			      .Q(dout),
			      .UNDERFLOW(underflow),
			      .WACK(wr_ack)
			      );
	      
	   end
	   if (dta_width == 64) begin
	      fifo_mem_rsp_dc_64x128
		mem_rsp_fifo_dc(
				//Inputs
				.DATA(din),
				.RCLOCK(rd_clk),
				.RE(rd_en),
				.RRESET_N(rd_rst),
				.WCLOCK(wr_clk),
				.WE(wr_en),
				.WRESET_N(wr_rst),
				// Outputs
				.AEMPTY(prog_empty),
				.AFULL(prog_full),
				.DVLD(valid),
				.EMPTY(empty),
				.FULL(full),
				.OVERFLOW(overflow),
				.Q(dout),
				.UNDERFLOW(underflow),
				.WACK(wr_ack)
				);

	   end
	   if (dta_width == 88) begin
	      fifo_mem_req_dc_88x64
		mem_req_fifo_dc(
				//Inputs
				.DATA(din),
				.RCLOCK(rd_clk),
				.RE(rd_en),
				.RRESET_N(rd_rst),
				.WCLOCK(wr_clk),
				.WE(wr_en),
				.WRESET_N(wr_rst),
				// Outputs
				.AEMPTY(prog_empty),
				.AFULL(prog_full),
				.DVLD(valid),
				.EMPTY(empty),
				.FULL(full),
				.OVERFLOW(overflow),
				.Q(dout),
				.UNDERFLOW(underflow),
				.WACK(wr_ack)
				);
	   end 
	end
   endgenerate
`ifdef DEBUG
   always @(posedge rd_clk)
     $strobe("%m\tread: %h dout: %h", fifo_valid, dout);
`endif

`ifdef CHECK_FIFO_PARAMS
   initial #0
     begin
        if (prog_thresh > (1<<addr_width))
          begin
	     #0 $display ("%m\t*** error: inconsistent fifo parameters. addr_width: %d prog_thresh: %d. ***", addr_width, prog_thresh);
	     $finish;
          end
     end

   always @(posedge wr_clk)
     if (fifo_overflow) 
       begin
          #0 $display ("%m\t*** error: fifo overflow. ***");
       end
   /*
    always @(posedge rd_clk)
    if (fifo_underflow) 
    begin
    #0 $display ("%m\t*** warning: fifo underflow. ***");
      end
    */
`endif
endmodule
