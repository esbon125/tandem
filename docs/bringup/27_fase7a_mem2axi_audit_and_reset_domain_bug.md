# Fase 7a: mem2axi_bridge audit, the stale-FWFT-copy correction, and the reset-domain bug

2026-08-26 night through 2026-08-27 morning. Continuation of the `tcela-17.bits` DMA-push
stall investigation (see docs 24-26). User went to sleep with standing authorization to
keep investigating, verify fixes in simulation, and deploy to real hardware autonomously
if simulation passed, so results would be ready to check in the morning.

## Recap of state entering this session

Two real bugs in `mem2axi_bridge.v` had already been found and *sim*-confirmed the previous
phase (doc 26): `mem_req_rd_en` held unconditionally high through all of `S_IDLE` (wedges
CoreFIFO's EMPTY flag once RE outlives a single cycle) and a "double-pop race" (RE could
re-assert on two consecutive cycles before the first pop's `valid` arrived, silently
dropping the second popped word). The RE-gating-only fix had been built and retested on
real hardware and found **not sufficient** (`dbg_mem_req_rd_pop_cnt` still read exactly 0).

## Stale FWFT copy invalidated the earlier "confirmed" simulation

Before resuming, a sharp user question ("la fifo esta bien configurada para lo que espera
el core de mpeg2?") led to discovering `bench/mem_response_corefifo/corefifo_req/
fifo_mem_req_dc_88x64.v` and `corefifo/fifo_mem_rsp_dc_64x128.v` still had `FWFT:true`
hardcoded, copied from a session that predated the project-wide `FWFT:true`→`false` fix.
**Every simulation conclusion drawn from that testbench before this point was invalid** --
including the original bug reproduction and the first "60/60 PASS" of the `mem_req_rd_empty`
fix. Regenerated both directories from the current `soc_build/.../component/work/...` output
(commit `2358ff8`'s predecessor work). Re-running against the *corrected* CoreFIFO showed the
`mem_req_rd_empty`-only fix reached only 31/60, not 60/60 -- this is what led to finding and
fixing the double-pop race as a *second*, independent bug (add `&& !mem_req_rd_en` self-gate
to make the pop pulse strictly one cycle). With both fixes, `e2e_fix_test` passed 60/60
against the corrected real CoreFIFO. Commit `2358ff8`, pushed.

The user correctly pushed back on an overclaim at this point: I had suggested the double-pop
race explained why `mem_response_fifo` reads entirely empty on hardware. The race is
symmetric between reads and writes (fires at the S_IDLE re-entry boundary regardless of
command type), so it cannot alone explain an exclusively-empty-reads outcome. Retracted.

## effort-max pass on mem2axi_bridge.v itself (per explicit user request)

Read the entire current `mem2axi_bridge.v` file end to end hunting for a deterministic,
read-path-specific bug (not a race) that would explain "no CMD_READ response has ever
reached `mem_response_fifo`, ever, ~100% of the time." Two leads were investigated and both
turned out to be dead ends, honestly reported rather than oversold:

- **framestore_response.v's STATE_FLUSH** holds `mem_res_rd_en` high unconditionally for
  65536 cycles at boot (on an always-empty fifo), and this path only runs on real hardware
  (`ifdef SIMULATION_ONLY`, driven by iverilog's own `-D__IVERILOG__`, always takes the
  `STATE_WAIT` shortcut in every Icarus testbench -- this code had *never* been exercised in
  simulation before). Looked exactly like the already-fixed root-cause-#1 pattern. Built a
  dedicated test (`res_flush_test` in `bench/mem_response_corefifo/testbench.v`) against the
  real, FWFT-corrected `fifo_mem_rsp_dc_64x128` CoreFIFO: a bounded RE-high-while-empty
  window that's later released does **not** wedge the fifo (PASS, 10/10 words delivered).
  Hypothesis retracted. Kept the gating change anyway (harmless, more consistent), commit
  `1a13505`, pushed. The same test run also independently re-confirmed, under the corrected
  model, that permanent RE-tie-high (`req_fifo_test2`, matching the *original* unfixed
  `mem2axi_bridge.v` S_IDLE behavior) still wedges at 3/60 -- reinforcing that root causes
  #1/#2 are real and the already-committed fix is sound.

## Real hardware retest: mem2axi_bridge.v fixes alone did not resolve the stall

Killed the user's own stale (but no-longer-in-use, confirmed via `ps`) Libero/SmartDebug
processes with explicit permission, then did a full clean rebuild (SYNTHESIZE → PLACEROUTE →
GENERATE_PROGRAMMING_DATA → PROGRAM, ~50 min) with the corrected `mem2axi_bridge.v` (both
root causes) and re-tested against `tcela-17.bits`:

```
dbg_mem_req_wr_push_cnt=60   dbg_mem_req_rd_pop_cnt=0   mem_res_valid_cnt=0
DMA push still times out at bytes_done=1385 (same as always)
```

Identical to the pre-fix symptom. `mem2axi_bridge.v`'s own pop logic is now fairly
thoroughly exonerated: correct in simulation against the real corrected CoreFIFO, and still
not sufficient on real silicon. The bug is upstream of it.

## Root cause found: mem_rst's reset-domain coupling to a dead dot_clk

Added two zero-risk debug bits (`dot_heartbeat` = `cnt_dot[0]`, mpeg2video.v's existing
free-running, `syn_noprune`-protected dot_clk counter, and `mem_rst`'s own level) into
`arbiter_flags[31:30]`, 2-FF synchronized into `clk` (same established CDC pattern as
`dbg_mem_req_rd_pop_cnt`), needing no probe insertion / `GENERATEDEBUGDATA`. Commit `5c8f29d`.
Rebuilt and reprogrammed. Result, read directly off live hardware:

```
dot_heartbeat=0 (stable across hundreds of samples, watchdog on and off, 10+ real seconds)
mem_rst=0 (asserted -- stuck)
```

`reset.v`'s `mem_rst` derives from `global_rst = clk_rst_1 && mem_rst_1 && dot_rst_1` -- a
3-way AND across *all three* clock domains, inherited from the original Xilinx FIFO18/36 hard
primitives' requirement that a reset be held >=3 cycles in every domain simultaneously. This
port no longer uses those primitives anywhere (`FIFO_XILINX=0`, CoreFIFO-based `xfifo_dc.v`
instead) -- the 3-way coupling is vestigial. Worse, it's actively harmful: `mem_rst` gates
`mem_request_fifo`'s read-side reset and `mem_response_fifo`'s write-side reset
(`framestore.v`), so it can only release once `dot_clk` (video/DVI output, logically
unrelated to decode/memory) also synchronizes. With no display attached, `dot_clk` never
ticks; `dot_rst_1` (a `sync_reset`'s async-cleared output) then never gets the clock edges
needed to synchronously release, holding `global_rst` -- and therefore `mem_rst` -- asserted
forever. `mem2axi_bridge.v`'s own `mem_hard_rst`/`mem_watchdog_rst` already sidestepped this
exact problem (synced directly from `clk_rst_0`/`clk_watchdog_0`, dot_clk-independent) --
which is exactly why *it* runs fine (real AXI4 writes complete,
`dbg_last_write_awaddr_issued` shows real DDR addresses) while `mem_request_fifo`'s read side
never budges.

**Fix** (`reset.v`, commit `1fd4a7a`): `clk_rst`/`mem_rst` now resync off
`clkmem_rst = clk_rst_1 && mem_rst_1`, dropping `dot_rst_1` from their own gate (still >=3
cycles in both domains that actually matter to them). `dot_rst` itself is untouched, since
dot_clk-domain logic legitimately does need dot_clk running.

## Unresolved: the fix's effect on hardware is not yet cleanly confirmed

Rebuilt and reprogrammed with the `reset.v` fix. First readback still showed `mem_rst=0`.
Added two more debug bits to investigate the apparent contradiction (`sync_rst`/`clk_rst`
itself, directly, and a `mem_clk` heartbeat `cnt_mem[0]`) -- commit `7c69891`. This *should*
have been a strictly additive, zero-risk change (no logic altered, only new OR'd-in read-only
bits), but the next rebuild+reprogram cycle showed a confusing regression: `clk_rst` now also
reads stuck, and `dbg_mem_req_wr_push_cnt` read **255** on a *fresh boot before any DMA push
was attempted* (should read 0 fresh out of reset) -- inconsistent with the immediately prior
build, which showed a clean `push_cnt=60` after real activity. `GENERATE_PROGRAMMING_DATA`
also failed once with an opaque `run_tool` error on this same rebuild cycle (no specific
cause captured in the log) and had to be retried, which succeeded -- worth noting in case it
is a symptom of the same underlying flakiness rather than pure EDA-tool transient noise.

This was the point the investigation was stopped for the night, rather than continuing to
iterate blindly on debug-bit interpretation (each rebuild cycle costs ~50 minutes, and
returns had stopped converging). **Do not trust the `arbiter_flags[31:27]` debug bits from
the last build (commit `7c69891`) without independently re-verifying them** -- something
about that specific build looks off in a way not yet understood (possibly a real hardware/
synthesis issue triggered by the added fan-out on `sync_rst`, possibly an unrelated resource/
tooling flake coinciding with it, possibly something else). The `reset.v` fix itself
(commit `1fd4a7a`, the `clkmem_rst` decoupling) is architecturally sound and independently
justified regardless of this open question, and is recommended to keep -- but its actual
effect on the real DMA-push stall has **not** been cleanly confirmed on hardware yet.

## What's proven solid vs. still open, going into the next session

**Proven, hardware-confirmed, keep as-is:**
- Graceful-abort reset fix (`stream_dma.v`/`mem2axi_bridge.v`) -- AXI4 wedge resolved.
- CoreFIFO dual-clock reset CDC fix (`wr_rst`/`rd_rst` split).
- `mem2axi_bridge.v`'s `mem_req_rd_empty` gating + double-pop self-gate -- both proven
  correct against the FWFT-corrected real CoreFIFO in simulation (60/60), and independently
  reinforced by `req_fifo_test2` still reproducing the *original* bug under the same
  corrected model. Real hardware retest shows these are not sufficient *alone*, but nothing
  suggests they are wrong -- they were addressing genuine, distinct bugs.
- `reset.v`'s `mem_rst`/`clk_rst` decoupling from `dot_rst_1` -- architecturally correct fix
  for a real, confirmed-on-hardware bug (`mem_rst` stuck low with a dead `dot_clk`).

**Still open:**
- Whether the `reset.v` fix actually resolves `dbg_mem_req_rd_pop_cnt`/the DMA stall --
  needs a clean re-test, ideally *without* the two just-added, possibly-implicated debug taps
  (`sync_rst` direct read + `mem_hb`), to isolate whether they are the source of the last
  build's confusing readings.
- Why `dot_clk` doesn't tick at all -- confirmed dead via `cnt_dot[0]` heartbeat across
  hundreds of samples and 10+ real seconds, independent of watchdog activity. `PF_CCC_C0`'s
  generated netlist shows `OUT2` (dot_clk) configured symmetrically with `OUT0`/`OUT1`
  (same `DIV_VAL`, same `EN`), so the cause isn't visible at the CCC-parameter level from the
  generated Verilog alone -- worth checking in Libero's SmartDesign GUI / IO Editor, or
  whether a display genuinely needs to be attached for `PLL_LOCK_0` (currently unused/
  unmonitored anywhere in the design) to reach lock on the OUT2 tap specifically.
- The opaque one-time `GENERATE_PROGRAMMING_DATA` `run_tool` failure on the last rebuild --
  retried successfully, not investigated further.
- Whether `mem2axi_bridge.v`'s fixes plus the `reset.v` fix, *together*, resolve the stall --
  genuinely not yet known.

## Recommended next step

Rebuild+reprogram once cleanly with **only** the `reset.v` `clkmem_rst` fix and the
mem2axi_bridge.v fixes in place (i.e., revert or bypass the last commit's two additional
debug taps, or at minimum re-verify them in isolation) before drawing further conclusions
about whether the reset-domain fix resolves the stall. If it does not, the next most
promising lead is `dot_clk`'s failure to tick at all, independent of anything already
touched tonight.
