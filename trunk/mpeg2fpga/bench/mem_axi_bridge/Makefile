#
# Use: make [all|test|clean]
#
# Unit test for mem2axi_bridge.v against fake_axi_ddr.v (a test double for
# the FIC_0/DDR4 AXI4 slave). Does not instantiate mpeg2video or Libero --
# see Fase 6a in the plan.
#

SRCS = \
  testbench.v \
  fake_axi_ddr.v \
  ../../rtl/mpeg2/mem2axi_bridge.v

INCDIR = -I../../rtl/mpeg2

all: test

test: testbench.vvp
	vvp testbench.vvp

testbench.vvp: $(SRCS)
	iverilog -g2005 -o testbench.vvp $(INCDIR) $(SRCS)

clean:
	rm -f testbench.vvp
