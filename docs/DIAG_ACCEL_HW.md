# Diagnosing the L1/drain build's hardware glitches

Status: **open**. Written 2026-08-30 for a fresh session, by the session
that built the thing. Fix nothing before reading "Triage first".

## The symptom

Firmware `219ac46` / host `994372e` (branch `acceleration`, both), the
first hardware run of: the L1 icache front (turbo, ~26x), the five-
iteration timing closure (WNS +0.089, hold +0.055), and the DMA line
drain. Sim-clean across the entire suite. On hardware, mostly
functional but:

- Total Replay: gets through some slideshow screens, sometimes with
  **visible glitching in the screens**, then eventually a **lockup**.
- Nox: booted fine once; on another boot, **right when the Mockingboard
  music was about to start**, screen glitching, then lockup.

Intermittent, workload-correlated, "actually pretty close".

## Triage first - cheap, on hardware, before any code

The goal is to split three very different failures apart:

1. **After a lockup, is the MACHINE dead or the host/display?** Try
   Ctrl-6 (the runtime menu). Read `swctl status` from the Pi (NOT
   while the machine is busy-looping - see the swctl-stall memory) and
   watch whether `acycles`/`aturbo`/`afast` still advance. Also
   `build/report.sh` on the workstation - the card's own UART report
   (L=4 there means a malformed link message). Core advancing + display
   frozen = host/link problem; core frozen = card problem; link counters
   wedged = the old FT601 family.
2. **Read every fault counter at/after a glitch**: `aovf` (merge
   overflows - MUST be 0; a nonzero here means fast WRITE words were
   dropped and the mirror/display corruption is explained), `aretry`,
   `ahold`, `mlate`, `mdrops`, `mmismatch` (mode-2 monitor),
   `mirror_gaps`/`mirror_lost`, ring-full counts, `hd` busy/execs
   (a stuck-busy hd = the drain wedged), and ACCEL_STAT's state nibble
   (where the sequencer sits: S_DECIDE=1/S_FAST=2/S_BUS=3/S_HELD=4).
3. **Bisect by mode, no rebuild**: does mode 1 glitch? mode 0? a
   governed mode 2 at 4.0 (does the failure scale with speed - timing
   smell - or exist at any accel - logic smell)? Slideshow behavior
   with the floppy vs the hard disk isolates the drain.
4. **Capture a sparse trace of a failure** (`pi.sh trace` / swtrace):
   a trace up to the lockup can be replayed through mmu_trace_check
   and read by hand; it is the single best artifact.

## The prime suspects, in order

1. **IRQ under turbo - NEVER SIMULATED.** The Nox failure fires exactly
   when the Mockingboard's first VIA IRQ would. Every sim that
   exercises turbo ties `irq_n` high (accel_tb), and cpu_irq_tb runs at
   bus pace only. The interrupt hijack (`take_int` at a turbo-served
   SYNC, `int_pc_hold`, the BRK sequence's stack/vector D-ops through
   the dispatcher, `i_steer`'s hold leg during entry) has zero coverage
   at 1 clock/fetch. **First repro attempt: an IRQ generator + handler
   in accel.s (or the Mockingboard TB under accel) with interrupts
   firing INTO turbo runs, including mid-claim and at page-cross
   stalls.** Also review `mb_irq`'s synchronity into `irq_n`.
2. **The drain against the REAL pipeline - NEVER CO-SIMULATED.**
   hd_card_tb proved the drain against STUBS (t2/dq/inv/snoop/fb2/ev).
   The real mem_cache li FSM, the real merge, the real turbo running
   concurrently, map changes mid-drain - none of it has run together.
   Total Replay's slideshow is exactly block-drain + decompress-store
   storm + display. **Second repro: hd_card wired into accel_tb (or
   mem_integ_tb) with a drain-under-turbo phase and the TB's reference
   checking every byte and the event stream.**
3. **Merge pressure dropping fast WRITES.** Turbo events are shed at
   the source (fev_room) but fast-op words push unguarded: if the FIFO
   is ever full when a 9-clock-path WRITE emits, that word is DROPPED
   (counted in aovf) and the host mirror + display shadow silently
   diverge -> pixel glitches, and corrupt later hdwrites (blocks come
   FROM the mirror). Re-derive the room math with the real DEPTH (check
   the card_link instantiation: default 16 vs the historical 8) against
   worst bursts (bus + fast + turbo + drain in one clock). aovf != 0 in
   triage confirms this class instantly.
4. **A drain wedge = the lockup shape.** Known hole found while writing
   this: `D_EMIT` waits on `dma_ev_take` forever if the capture is
   disabled after the line sampled `ev_enabled` - fix defensively
   (escape to D_WRITE when !ev_enabled) regardless of whether it is
   THE bug. Same review for D_WRITE/D_INV/D_SNOOP waits (dq_ready,
   inv_line_rdy under a busy pipeline, snoop2 vs a cl-snoop storm) and
   for `outstanding` decrement racing `take_exec` at drain end.
5. **Map-change/page-register races under turbo.** The slideshow flips
   PAGE2/HIRES constantly (map_changed -> TLB+lp flush). The flush is
   same-edge by design, but the accel_tb program's switch traffic is
   mild; a flip-storm phase (tight $C054/$C055/LC-bank loops under
   mode 2) is cheap to add. Also `INTC8ROM` set by a FAST $C3xx fetch
   mid-run.
6. **Timing marginality.** +0.089 setup / +0.055 hold at nominal;
   silicon corners are real. Suspect this only if the counters come
   back clean and failures track temperature/speed scaling. (History:
   the proven pre-L1 builds closed at +0.009..+0.243.)

## Strongly recommended first change: chicken bits

Before deep debugging, add two ACCEL_CTRL spare bits (word has room;
[25] turbo_disable, [26] drain_disable), plumb to `turbo_ok` and
`fast_dma`, rebuild once. That turns the hardware itself into the
bisector: baseline-accel (proven 12.6x path) vs +turbo vs +drain vs
both, switchable at runtime under the failing workload. An hour of work
that likely localizes the bug in one evening of play.

## Code-review targets (fresh eyes, in this order)

- `rtl/cpu65c02.sv`: `take_int`/`int_pc_hold`/`i_steer` interactions;
  anything consuming `irq_n` combinationally.
- `rtl/l1_front.sv`: the claim/tries window vs turbo_ok (can any state
  leave the core with NO path to a cyc_en? enumerate); lp reload vs
  map_changed same-edge; steer during aux_sync/hold engage.
- `rtl/hd_card.sv` S_DRAIN: every wait's exit conditions; the
  ev_enabled hole above; interplay with `accept`/timeout while
  draining.
- `rtl/event_merge.sv`: the 3-writers-per-clock wp arithmetic and
  whether DEPTH gives the claimed margins.
- `rtl/mem_cache.sv` li FSM vs `inval` walk vs an op arriving at each
  of its 3 clocks.
- Hold-time review of the icache/TLB LUTRAM write paths (WHS +0.055).

## What proves the fix

Whatever is found: encode the repro as a permanent sim phase FIRST
(accel_tb or hd_card_tb), watch it fail, fix, watch the whole battery
pass (accel_tb both sweeps, predict, tlb_trace, mem trio, fb_sim,
hd_card_tb, lint), rebuild to WNS >= 0, then the same workloads on
hardware: a full Total Replay slideshow walk, Nox with music playing,
counters clean (aovf/mlate/mdrops/mmismatch = 0), and a long soak.

## Context a fresh session needs

- Plan + design history: docs/ACCELERATION.md ("The L1 front"),
  docs/HARDDISK.md ("The line drain"), docs/MEMORY.md; the memory
  files l1-front, dma-line-drain, reset-discipline, sim-progress-
  counters (monitor long tests by their counters, never
  timeout-and-retry).
- The bit is SRAM-only (build/load.sh); stop swhost before load.sh;
  a bare `tools/pi.sh run` uses swhost.conf, the user's.
- All sims and their wall times are listed in the sim-progress memory.
- The mid-DMA overlap corner (machine touching an in-flight DMA
  target) is DOCUMENTED-UNDEFINED - do not chase it as a bug unless a
  trace shows a program actually doing it.
