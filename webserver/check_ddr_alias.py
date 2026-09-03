"""Prove (or disprove) that the three u-dma-buf regions are one buffer.

Run this after any change to the device tree, the MSS DDR segment config, or
DDR_BASE/STAGING_BASE. It is the test that settled the Fase 7a SIZE=0
investigation, and the naive version of it gave the wrong answer for weeks.

The trap: PolarFire SoC's L2 is a MEMORY-SIDE cache selected by ADDRESS
WINDOW, not by page-table attribute. Accesses to 0x8xxxxxxx go through L2;
0xCxxxxxxx and 0xDxxxxxxx bypass it. So a plain write/readback between the
cached and non-cached windows reports "independent" in BOTH directions even
though they are the same DRAM:

    write 0x88000000 -> sits dirty in L2; read 0xc8000000 -> DRAM, stale.
    write 0xc8000000 -> goes to DRAM;     read 0x88000000 -> stale L2 line.

mmap'ing with O_SYNC does not help, and neither does u-dma-buf's
sync_for_cpu/sync_for_device on its own -- those act on the CPU's own caches,
not on the memory-side L2. Two things do work, and this script uses both:

  * compare the two NON-cached windows against each other (neither is cached)
  * force real eviction by streaming >L2 (2 MB) of other cached addresses
    between the write and the read

Expected result on the current Discovery Kit reference design: ALIASED
everywhere. Keep the decoder disabled (CORE_ENABLE=0) while running this --
it writes into the framestore.
"""
import mmap
import os
import struct

SIZE = 32 * 1024 * 1024
L2_THRASH = 8 * 1024 * 1024      # >> 2 MB L2
THRASH_BASE = 0x1000000          # 16 MB in, clear of the test offsets

OFF_A = 0x600000                 # cached -> non-cached
OFF_B = 0x700000                 # non-cached -> cached
OFF_C = 0x800000                 # non-cached -> non-cached WCB
OFF_CONTROL = 0x900000           # never written; must not change


class Buf:
    def __init__(self, path):
        self.path = path
        self.fd = os.open(path, os.O_RDWR)
        self.mm = mmap.mmap(self.fd, SIZE, mmap.MAP_SHARED,
                            mmap.PROT_READ | mmap.PROT_WRITE)

    def r(self, off):
        return struct.unpack_from("<Q", self.mm, off)[0]

    def w(self, off, val):
        struct.pack_into("<Q", self.mm, off, val)

    def close(self):
        self.mm.close()
        os.close(self.fd)


def main():
    c0 = Buf("/dev/udmabuf-ddr-c0")            # 0x88000000, cached
    nc0 = Buf("/dev/udmabuf-ddr-nc0")          # 0xc8000000, non-cached
    wcb = Buf("/dev/udmabuf-ddr-nc-wcb0")      # 0xd8000000, non-cached WCB

    def evict():
        """Stream 8 MB of CACHED addresses to push everything else out of L2."""
        acc = 0
        mv = memoryview(c0.mm)
        for off in range(THRASH_BASE, THRASH_BASE + L2_THRASH, 64):
            acc ^= mv[off]
        return acc

    control = {b.path: b.r(OFF_CONTROL) for b in (c0, nc0, wcb)}
    aliased = []

    def check(label, src, dst, off, magic, need_evict):
        src.w(off, magic)
        if need_evict:
            evict()
        got = dst.r(off)
        hit = got == magic
        aliased.append(hit)
        print(f"  {label}: wrote {magic:016x} -> read {got:016x}  "
              f"{'ALIASED' if hit else 'independent'}")

    print("alias check (decoder must be disabled -- this writes the framestore)")
    check("c0  -> nc0 (evicted)", c0, nc0, OFF_A, 0xDEADBEEFCAFE0001, True)
    check("nc0 -> c0  (evicted)", nc0, c0, OFF_B, 0xFEEDFACE5A5A0002, True)
    check("nc0 -> wcb (no cache in path)", nc0, wcb, OFF_C, 0x0FF1CE5500000003, False)

    print("\ncontrol -- an offset nothing wrote must be unchanged:")
    ok = True
    for b in (c0, nc0, wcb):
        now = b.r(OFF_CONTROL)
        same = now == control[b.path]
        ok &= same
        print(f"  {b.path}: {now:016x}  {'ok' if same else '!! CHANGED !!'}")

    for b in (c0, nc0, wcb):
        b.close()

    if not ok:
        print("\nCONTROL FAILED -- something else is writing this DRAM; result is void.")
    elif all(aliased):
        print("\nALIASED: the three devices are one 32 MB buffer. Software must keep "
              "the staging offset clear of the framestore (see dma_push.py).")
    elif any(aliased):
        print("\nMIXED result -- re-run; a partial alias should not happen.")
    else:
        print("\nINDEPENDENT: the memory map changed. Re-check dma_push.STAGE_OFFSET; "
              "the offset may no longer be needed.")


if __name__ == "__main__":
    main()
