//Wrapper for generic_fifo_dc and microchip FIFO (COREFIFO)

module xfifo_dc (
		 rst,
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
   
   input          rst;         /* low active sync master reset */
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

   assign empty = fifo_empty;
   assign full = fifo_full;
   assign prog_empty = fifo_empty_n;
   assign prog_full = fifo_full_n;
   assign valid = fifo_valid;
   assign underflow = fifo_underflow;
   assign wr_ack = fifo_wr_ack;
   assign overflow = fifo_overflow;

   if (USE_GENERIC == 1'b1
       ) begin
      always @(posedge rd_clk)
	if (~rst) fifo_valid <= 1'b0;
	else fifo_valid <= rd_en && ~fifo_empty;

   always @(posedge rd_clk)
     if (~rst) fifo_underflow <= 1'b0;
     else fifo_underflow <= rd_en && fifo_empty;

   always @(posedge wr_clk)
     if (~rst) fifo_wr_ack <= 1'b0;
     else fifo_wr_ack <= wr_en && ~fifo_full;

   always @(posedge wr_clk)
     if (~rst) fifo_overflow <= 1'b0;
     else fifo_overflow <= wr_en && fifo_full;
end 

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
		     .rst(rst), 
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
			      .RRESET_N(rst),
			      .WCLOCK(wr_clk),
			      .WE(wr_en),
			      .WRESET_N(rst),
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
				.RRESET_N(rst),
				.WCLOCK(wr_clk),
				.WE(wr_en),
				.WRESET_N(rst),
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
				.RRESET_N(rst),
				.WCLOCK(wr_clk),
				.WE(wr_en),
				.WRESET_N(rst),
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
