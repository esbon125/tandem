#
# Use: make [all|test|clean]
#
# Unit test for mem2axi_bridge.v + the REAL mem_response_fifo (CoreFIFO
# instance Libero generates, copied from soc_build/.../fifo_mem_rsp_dc_64x128,
# RAM1K20 replaced with a verified-equivalent behavioral stand-in -- see
# corefifo/*_ram_wrapper.v's header comment) against fake_axi_ddr.v.
#
# Fase 7a (2026-08-22): reproduces the real hardware symptom -- writes
# complete, but no read response ever crosses mem_response_fifo's mem_clk
# -> clk boundary -- using the actual CoreFIFO control logic instead of the
# generic_fifo_dc stand-in bench/iverilog and bench/mem_axi_bridge use.
#

SRCS = \
  testbench.v \
  fake_axi_ddr.v \
  ../../rtl/mpeg2/mem2axi_bridge.v \
  ../../rtl/mpeg2/wrappers.v \
  ../../rtl/mpeg2/xfifo_dc.v \
  ../../rtl/mpeg2/xfifo_sc.v \
  corefifo/fifo_mem_rsp_dc_64x128.v \
  corefifo/COREFIFO.v \
  corefifo/corefifo_async.v \
  corefifo/corefifo_sync.v \
  corefifo/corefifo_sync_scntr.v \
  corefifo/corefifo_nstagessync.v \
  corefifo/corefifo_graytobinconv.v \
  corefifo/corefifo_fwft.v \
  corefifo/fifo_mem_rsp_dc_64x128_fifo_mem_rsp_dc_64x128_0_ram_wrapper.v \
  corefifo_req/fifo_mem_req_dc_88x64.v \
  corefifo_req/COREFIFO.v \
  corefifo_req/corefifo_async.v \
  corefifo_req/corefifo_sync.v \
  corefifo_req/corefifo_sync_scntr.v \
  corefifo_req/corefifo_nstagessync.v \
  corefifo_req/corefifo_graytobinconv.v \
  corefifo_req/corefifo_fwft.v \
  corefifo_req/fifo_mem_req_dc_88x64_fifo_mem_req_dc_88x64_0_ram_wrapper.v

INCDIR = -I../../rtl/mpeg2

all: test

test: testbench.vvp
	vvp testbench.vvp

testbench.vvp: $(SRCS)
	iverilog -g2005 -o testbench.vvp $(INCDIR) $(SRCS)

clean:
	rm -f testbench.vvp
