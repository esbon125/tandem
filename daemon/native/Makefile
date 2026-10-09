# libm2fconv.so for the board (riscv64) and for the host tests.
#   make            -> riscv64/libm2fconv.so (cross, freestanding)
#   make host       -> host/libm2fconv.so
CROSS ?= riscv64-linux-gnu-
CFLAGS = -O2 -shared -fPIC -nostdlib -ffreestanding -Wall -Wextra

riscv64/libm2fconv.so: m2fconv.c
	mkdir -p riscv64
	$(CROSS)gcc $(CFLAGS) -o $@ $<

host: host/libm2fconv.so
host/libm2fconv.so: m2fconv.c
	mkdir -p host
	gcc $(CFLAGS) -o $@ $<

clean:
	rm -rf riscv64 host
.PHONY: host clean
