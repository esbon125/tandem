# Baseline: hardware_development@c069e3b, tek60 (704x480)

Frozen hardware measurement, kept so a future RTL change can be scored
against this exact baseline without reprogramming the board with the old
bitstream every time. See `docs/bringup/41_pipelining_lecturas_en_mem2axi_bridge.md`
(docs branch) for how this was produced and why (mem2axi_bridge read
pipelining, 2026-09-06).

## Provenance

- commit: `c069e3b` (hardware_development) — `mem2axi_bridge.v` single-outstanding,
  single-beat AXI4 (the state before the read-pipelining change in this repo's
  history)
- board: MPFS_DISCOVERY_KIT (`E2009O0C3E`)
- stream: `stream.bits` in this directory (= `tek60.bits`, 704x480, 60 pictures,
  `frame_rate_code 4` i.e. 29.97 fps) — not derived from any stream already in
  `tools/streams/`, so it is committed here rather than referenced
- `hw_framestore.bin`/`.txt`: raw framestore dump from
  `webserver/capture_framestore.py` (firmware_development), same format
  `bench/iverilog/mem_ctl.v` writes in simulation — see `framecmp_method`
  session memory for the extraction rules this depends on

## Timing

Measured via `webserver/decode_stream.py`'s `POST /decode` (steady-state,
`reset: false` — i.e. not counting the one-time core-reset/poison setup):

| metric | value |
|---|---|
| decode (`capture_seconds`, 60 pictures) | 8.0 s |
| decode rate | **7.2 fps** |
| DMA-to-framestore-settled (`capture_framestore.py`'s own timer) | 4.8 s |
| `error` / `watchdog` | false / false |

## Correctness (`framecmp compare` against `tools/mpeg2dec`)

| buffer | best reference frame | MAD(Y) | PSNR(Y) | peak | chroma MAD (U/V) |
|---|---|---|---|---|---|
| 0 | frame_59_out_ | 0.004 | 71.70 | 1 | 0.003 / 0.003 |
| 1 | frame_57_out_ | 1.098 | 41.93 | 26 | 0.358 / 0.263 |
| 2 | frame_58_out_ | 0.661 | 45.85 | 17 | 0.242 / 0.217 |
| 3 | frame_56_out_ | 1.069 | 42.58 | 23 | 0.403 / 0.331 |

Buffers 1 and 3 exceed `framecmp`'s default MAD threshold of 1.0 — this is
the pre-existing, upstream (not-this-port) prediction-error discrepancy
already tracked in the `plan_general_action_items` session memory (item 1),
present in the Icarus simulation too. **Any future comparison should expect
these same two buffers to fail by roughly this much** — a *new* discrepancy
(different buffers, much larger MAD, or a buffer 0 regression) would mean an
actual regression, not this known issue.

## How to compare a new bitstream against this baseline

No need to reprogram the board with `c069e3b` again — just run the new
bitstream against the same stream and diff by hand, or point `framecmp`
straight at this directory's dump:

```sh
cd trunk/mpeg2fpga

# regenerate the reference frames (fast, deterministic — not committed)
python3 tools/framecmp/framecmp.py ref tools/framecmp/baselines/c069e3b_tek60/stream.bits -o /tmp/ref

# reproduce this baseline's own numbers (sanity check the dump is still readable)
python3 tools/framecmp/framecmp.py compare tools/framecmp/baselines/c069e3b_tek60/hw_framestore.bin /tmp/ref

# on the board, with the NEW bitstream programmed:
#   python3 capture_framestore.py tools/framecmp/baselines/c069e3b_tek60/stream.bits -o new.bin
# then, back on the host:
python3 tools/framecmp/framecmp.py compare new.bin /tmp/ref
```

Timing: push the same `stream.bits` through `POST /decode` (or
`capture_framestore.py`, whose own DMA timer is even simpler to read) and
compare `capture_seconds`/fps against the table above.
