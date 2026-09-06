#
# Use: make [all|test|clean]
#
# Unit test for apb3_mpeg2fpga_bridge.v against fake_regfile.v (a test
# double for regfile.v's reg_addr/reg_wr_en/reg_rd_en interface). Does not
# instantiate mpeg2video or Libero -- see Fase 5a in the plan.
#

SRCS = \
  testbench.v \
  fake_regfile.v \
  ../../rtl/mpeg2/apb3_mpeg2fpga_bridge.v

INCDIR = -I../../rtl/mpeg2

all: test

test: testbench.vvp
	vvp testbench.vvp

testbench.vvp: $(SRCS)
	iverilog -g2005 -o testbench.vvp $(INCDIR) $(SRCS)

clean:
	rm -f testbench.vvp
