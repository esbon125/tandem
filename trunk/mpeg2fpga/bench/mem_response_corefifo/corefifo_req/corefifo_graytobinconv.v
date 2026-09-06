// ********************************************************************/
// Microchip Corporation Proprietary and Confidential
// Copyright 2023 Microchip Corporation.  All rights reserved.
//
// ANY USE OR REDISTRIBUTION IN PART OR IN WHOLE MUST BE HANDLED IN
// ACCORDANCE WITH THE MICROCHIP LICENSE AGREEMENT AND MUST BE APPROVED
// IN ADVANCE IN WRITING.
//
// IP Core:      COREFIFO
//
// SVN Revision Information:
// SVN $Revision:  $
// SVN $Date:  $
//
//
// *********************************************************************/

`timescale 1ns / 100ps

module fifo_mem_req_dc_88x64_fifo_mem_req_dc_88x64_0_corefifo_graytobinconv(
                                         gray_in,
                                         bin_out
                                        );

   // --------------------------------------------------------------------------
   // Parameter Declaration
   // --------------------------------------------------------------------------
   parameter ADDRWIDTH  = 3;
  // parameter SYNC_RESET = 0;   

   // --------------------------------------------------------------------------
   // I/O Declaration
   // --------------------------------------------------------------------------

   //--------
   // Inputs
   //--------
   input [ADDRWIDTH:0]    gray_in;

   //---------
   // Outputs
   //---------
   output [ADDRWIDTH:0] bin_out;

   // --------------------------------------------------------------------------
   // Internal signals
   // --------------------------------------------------------------------------
   reg [ADDRWIDTH:0]      bin_out;   
   integer                i;
   

   // --------------------------------------------------------------------------
   //                               Start - of - Code
   // --------------------------------------------------------------------------


   // --------------------------------------------------------------------------
   // Logic to Convert the Gray code to Binary
   // --------------------------------------------------------------------------
   always @(*) begin

      bin_out[ADDRWIDTH]  = gray_in[ADDRWIDTH];      

      for(i=ADDRWIDTH;i>0;i = i-1) begin
         bin_out[i-1]     = (bin_out[i] ^ gray_in[i-1]);
      end

   end

endmodule // corefifo_grayToBinConv

// --------------------------------------------------------------------------
//                             End - of - Code
// --------------------------------------------------------------------------
