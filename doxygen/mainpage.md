# mpeg2fpga Reference Manual {#mainpage}

Technical reference for the software side of the mpeg2fpga MPEG-2 decoder on the
PolarFire SoC Discovery Kit. Using the product is covered by the user guide
and the network protocol by `api/PROTOCOL-v1.md`; this is for whoever reads
or changes the code.

| Component | Where | Runs on | Language |
|---|---|---|---|
| Kernel driver `mpeg2fpga.ko` | `driver/mpeg2fpga/` | board (Linux) | C |
| Frame converter `libm2fconv.so` | `daemon/native/` | board | C |
| Service `mpeg2fpgad` | `daemon/mpeg2fpgad/` | board | Python |
| Client library `mpeg2fpga` | `api/python/src/mpeg2fpga/` | host | Python |

## Driver

The driver is split so the logic can be unit-tested without hardware:

- `mpeg2fpga_core.c` / `mpeg2fpga_core.h`: everything that touches the
  decoder's registers, through the callbacks in `struct mpeg2fpga_regops`.
  The KUnit suite in `driver/mpeg2fpga/tests/` runs it against a fake
  register array.
- `mpeg2fpga_platform.c`: the platform driver (device tree match, ioremap,
  interrupt, sysfs attributes and the `/dev/mpeg2fpga` character device).
- `mpeg2fpga_regs.h`: the register map. Below 0x10 the decoder's own banks
  (read and write mode are different registers at the same address); 0x10
  and up, the APB bridge's flat map.
- `mpeg2fpga_uapi.h`: the event records `read()` returns, one per finished
  picture.

## Service and library

`mpeg2fpgad` owns the decoder: it takes elementary streams over HTTP(S),
hands them to the DMA through the driver, and streams back decoded pictures
as I420 records (`session.py`, `server.py`). The client library wraps that
protocol: `mpeg2fpga.Client` and `mpeg2fpga.Frame` are the entry points.

The kernel's comment conventions (kernel-doc) are translated for Doxygen by
`doxygen/kerneldoc_filter.py`; the sources are not changed for it.
