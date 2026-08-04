# Out-of-tree Kbuild for the real mpeg2fpga platform driver.
#
# Usage:
#   make -C $(KERNEL_SRC) ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- M=$(PWD) modules
#
# KERNEL_SRC must be a linux4microchip/linux checkout with modules_prepare
# (or a full build) already run -- see docs/bringup/04_driver_tdd_environment_discovery_kit.md.

obj-m += mpeg2fpga.o
mpeg2fpga-objs := mpeg2fpga_core.o mpeg2fpga_platform.o
