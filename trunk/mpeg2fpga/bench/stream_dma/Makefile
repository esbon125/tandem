#
# Use: make [all|test|clean]
#
# Unit test for stream_dma.v against fake_axi_ddr_ro.v (a test double for
# the FIC_2/staging-buffer AXI4 slave). Does not instantiate mpeg2video or
# Libero -- see Fase 7c in the plan.
#

SRCS = \
  testbench.v \
  fake_axi_ddr_ro.v \
  ../../rtl/mpeg2/stream_dma.v

INCDIR = -I../../rtl/mpeg2

all: test

test: testbench.vvp
	vvp testbench.vvp

testbench.vvp: $(SRCS)
	iverilog -g2005 -D__IVERILOG__ -o testbench.vvp $(INCDIR) $(SRCS)

clean:
	rm -f testbench.vvp
