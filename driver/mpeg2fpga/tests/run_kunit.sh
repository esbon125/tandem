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
# Usage: KERNEL_SRC=/path/to/linux4microchip-linux ./run_kunit.sh

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

cd "$KERNEL_SRC"
# kunit.py uses walrus operators etc. that require Python >= 3.8; this host's
# default `python3` is 3.6, so pin an explicit modern interpreter if present.
KUNIT_PYTHON="python3"
for candidate in python3.12 python3.11 python3.10 python3.9 python3.8; do
	command -v "$candidate" >/dev/null 2>&1 && KUNIT_PYTHON="$candidate" && break
done
"$KUNIT_PYTHON" tools/testing/kunit/kunit.py run --arch=um
