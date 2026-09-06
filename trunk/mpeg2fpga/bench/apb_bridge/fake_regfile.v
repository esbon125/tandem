/*
 * fake_regfile.v
 *
 * Test double for regfile.v's reg_addr/reg_wr_en/reg_dta_in/reg_rd_en/reg_dta_out
 * interface, used to unit-test apb3_mpeg2fpga_bridge.v in isolation without
 * instantiating the full mpeg2video core -- same dependency-injection idea as
 * the fake register backend used for the driver's KUnit tests
 * (driver/mpeg2fpga/tests/mpeg2fpga_core_test.c on firmware_development).
 *
 * Read-mode and write-mode are independent 16-word banks, as in real
 * hardware (doc/mpeg2fpga.txt sec. 1.4): a write to address N does not
 * change what a read from address N returns. reg_dta_out is a registered
 * output, valid one core_clk cycle after reg_rd_en is sampled high --
 * matches regfile.v's actual timing (see the "reading registers" always
 * block in regfile.v), which is exactly the timing the bridge has to
 * respect.
 */

`include "timescale.v"

module fake_regfile (
    core_clk, core_rst_n,
    reg_addr, reg_wr_en, reg_dta_in, reg_rd_en, reg_dta_out
);

  input             core_clk;
  input             core_rst_n;
  input       [3:0] reg_addr;
  input             reg_wr_en;
  input      [31:0] reg_dta_in;
  input             reg_rd_en;
  output reg [31:0] reg_dta_out;

  /* Testbench pokes read_mem directly (hierarchical reference) to preload
   * "read-mode" register content; write_mem is inspected the same way to
   * check what the bridge actually wrote.
   */
  reg [31:0] write_mem [0:15];
  reg [31:0] read_mem  [0:15];

  integer i;

  always @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      reg_dta_out <= 32'b0;
      for (i = 0; i < 16; i = i + 1)
        write_mem[i] <= 32'b0;
    end else begin
      if (reg_wr_en)
        write_mem[reg_addr] <= reg_dta_in;
      if (reg_rd_en)
        reg_dta_out <= read_mem[reg_addr];
    end
  end

endmodule
/* not truncated */
