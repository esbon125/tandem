#
# IEEE 1180-1990 IDCT accuracy test, run against the REAL rtl/mpeg2/idct.v.
#
# Use: make            build everything
#      make test       run the full six-condition series (~27 min)
#      make quick      one condition, 500 iterations (~15 s), for a fast check
#      make clean
#
# Why this exists: tools/ieee1180/ is upstream's harness, and it carries its
# OWN copy of idct.v which has drifted from rtl/mpeg2/idct.v. Building against
# that copy tests the wrong file -- the same "local copy diverges" trap that
# bench/iverilog's wrappers.v already sprang on this project. This Makefile
# always builds the real one.
#
# Koen's own reference results are in tools/ieee1180/ieee-1180-results.
# Ours are in results-mpfs.txt; they agree to the fourth decimal.
#

RTL      = ../../rtl/mpeg2
UPSTREAM = ../../tools/ieee1180/ieee1180
IVL      = iverilog

# idct.v pulls in fifo_sc/dpram_sc from wrappers.v, which in turn needs both
# soft fifo implementations.
VSRCS = $(UPSTREAM)/tst.v $(RTL)/idct.v $(RTL)/wrappers.v $(RTL)/xfifo_sc.v \
        $(RTL)/xfifo_dc.v $(UPSTREAM)/generic_dpram.v ../iverilog/generic_fifo_dc.v

all: idct-verilog ieeetest

idct-verilog: $(VSRCS)
	$(IVL) -I $(RTL) -o $@ $(VSRCS)

ieeetest: $(UPSTREAM)/ieeetest.c $(UPSTREAM)/jrevdct.c $(UPSTREAM)/dct.h
	$(CC) -O -I $(UPSTREAM) -o $@ $(UPSTREAM)/ieeetest.c $(UPSTREAM)/jrevdct.c -lm

# jrevdct.c here is Koen's glue, not the IJG routine: its j_rev_dct() writes
# idct-in, runs ./idct-verilog, and reads idct-out back.
test: all
	$(UPSTREAM)/doieee ./ieeetest 2>&1 | tee results-mpfs.txt
	@echo
	@grep -c "meets spec" results-mpfs.txt | xargs echo "checks passed:"
	@grep -c "exceeds"    results-mpfs.txt | xargs echo "checks FAILED:"

quick: all
	./ieeetest -256 255 1 500

clean:
	rm -f idct-verilog ieeetest idct-in idct-out

.PHONY: all test quick clean
