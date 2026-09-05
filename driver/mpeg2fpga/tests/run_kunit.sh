#!/usr/bin/env bash
# Runs the mpeg2fpga_core KUnit suite under UML against a cloned kernel tree.
#
# KUnit's kunit_tool only knows how to build tests that live inside the
# kernel tree's own Kbuild graph, so this script syncs our out-of-tree
# source (driver/mpeg2fpga/) into drivers/misc/mpeg2fpga/ of the kernel
# clone, wires it into drivers/misc/{Kconfig,Makefile}, and invokes
# kunit.py. The repo copy under driver/mpeg2fpga/ stays the source of
# truth; nothing is written back here.
#
# KERNEL_SRC must be a *clean* tree: kunit.py builds with O=.kunit, and an
# O= build refuses to run if the source tree has in-tree build artifacts. Do
# not run `make mrproper` on the tree used to cross-build the real module --
# that would destroy the .config/Module.symvers the out-of-tree build needs.
# Use a second checkout instead:
#
#   git -C <kernel> worktree add --detach ~/kernel-src/kunit-worktree HEAD
#
# Usage: KERNEL_SRC=/path/to/clean/linux ./run_kunit.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER_DIR="$(dirname "$SCRIPT_DIR")"

: "${KERNEL_SRC:?Set KERNEL_SRC to a linux4microchip/linux checkout (branch linux-6.18-mchp)}"

DEST="$KERNEL_SRC/drivers/misc/mpeg2fpga"
mkdir -p "$DEST/tests"

cp "$DRIVER_DIR"/mpeg2fpga_core.c "$DEST/"
cp "$DRIVER_DIR"/mpeg2fpga_core.h "$DEST/"
cp "$DRIVER_DIR"/mpeg2fpga_regs.h "$DEST/"
cp "$DRIVER_DIR"/tests/mpeg2fpga_core_test.c "$DEST/tests/"

cat > "$DEST/Kconfig" <<'EOF'
config MPEG2FPGA_KUNIT_TEST
	tristate "KUnit tests for the mpeg2fpga register core" if !KUNIT_ALL_TESTS
	depends on KUNIT
	default KUNIT_ALL_TESTS
	help
	  Pure-logic KUnit tests for mpeg2fpga_core.c (status parsing,
	  IRQ mask shadowing, watchdog configuration) against a fake
	  in-memory register backend. No hardware required.
EOF

cat > "$DEST/Makefile" <<'EOF'
obj-$(CONFIG_MPEG2FPGA_KUNIT_TEST) += mpeg2fpga_core.o tests/mpeg2fpga_core_test.o
EOF

# Wire the new subdir into drivers/misc, idempotently.
KCONFIG="$KERNEL_SRC/drivers/misc/Kconfig"
MAKEFILE="$KERNEL_SRC/drivers/misc/Makefile"

grep -q 'mpeg2fpga/Kconfig' "$KCONFIG" || \
	sed -i '/^endmenu/i source "drivers/misc/mpeg2fpga/Kconfig"' "$KCONFIG"

grep -q 'mpeg2fpga/' "$MAKEFILE" || \
	echo 'obj-y				+= mpeg2fpga/' >> "$MAKEFILE"

cat > "$KERNEL_SRC/.kunitconfig" <<'EOF'
CONFIG_KUNIT=y
CONFIG_MPEG2FPGA_KUNIT_TEST=y
EOF

# linux4microchip-2026.04.1 does not build for UML as shipped: UML has no
# asm/unwind_user.h, so kernel/fork.c pulls in the x86 one and fails on
# regs->flags / X86_VM_MASK. Route it to the generic header.
UM_KBUILD="$KERNEL_SRC/arch/um/include/asm/Kbuild"
grep -q 'unwind_user.h' "$UM_KBUILD" || \
	echo 'generic-y += unwind_user.h' >> "$UM_KBUILD"

cd "$KERNEL_SRC"
# kunit.py uses walrus operators etc. that require Python >= 3.8; this host's
# default `python3` is 3.6, so pin an explicit modern interpreter if present.
KUNIT_PYTHON="python3"
for candidate in python3.12 python3.11 python3.10 python3.9 python3.8; do
	command -v "$candidate" >/dev/null 2>&1 && KUNIT_PYTHON="$candidate" && break
done
"$KUNIT_PYTHON" tools/testing/kunit/kunit.py run --arch=um
