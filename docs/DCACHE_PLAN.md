# The D-side L1: the plan

Status: **not started**. Written 2026-08-30 for a fresh session, by the
session that did the timing relief and the chicken bits. Everything
here is on branch `acceleration`, both repos (fw f0fbaad / host
ed084e1, neither merged to master). First thing in any session:
`git status` both repos and commit anything old (the user's standing
rule), and note the open soak in DIAG_ACCEL_HW.md - if hardware
glitches recur during this work, bisect with the chicken bits FIRST.

## Why, in numbers (measured, accel_tb mode 2, Nox-like mix)

- **Fast data READS are 46% of ALL clocks**: 6,372 ops at 9 clocks
  each. This is the target.
- Fast WRITES another 7% (912 @9).
- Bus ops are 25% (181 @ ~170 clocks) - NOT this phase's problem;
  they are the soft-switch internalization's (see "After this" below).
- The icache is done: fastI misses 1%, turbo serves ~77% of ops @1.

Projection (docs/ACCELERATION.md, the l1-front work): a 2-clock D$
takes mode 2 from 26.4x to **~41x**; a 1-clock one only ~45x. **The
2-clock first cut is decided** (ACCELERATION.md:465-469: "a 2-clock
dcache with a small write buffer is the planned next rung, and a
1-clock one (LUTRAM or a falling-edge RAM) the rung after").

## Where the nine clocks go today (so you know what you are removing)

A fast data op, best case (rtl/accel_seq.sv + rtl/mem_cache.sv):

- T1: op up; dq_* sample it; `settled` not yet (killed by the retiring
  cyc_en).
- T2: `settled` -> `decide_go` -> `go_fast`; S_FAST; u_* latched.
- T3: `u_present` on the unified stream; apple_mmu classifies;
  `cl_valid` registered.
- T4-T8: mem_cache's five pipeline stages (two BRAM output registers
  each on tags and ways - deliberate, see mem_cache.sv:49-61 - then
  compares, then the hit/byte registers).
- T9: `decided`/`sub_en`; `fast_hit` -> `cyc_en` combinationally; the
  core takes the byte.

Two clocks are the sequencer's decision, six are mem_cache. mem_cache
stays as it is - it became the L2 when the icache went in (MEMORY.md:
"this cache became its L2, unchanged but for sub_line") and misses
keep using it. The D$ goes IN FRONT, like the icache did.

## What is already built for this

- **The TLB carries the write view, dangling.** class_tlb.sv entries
  are {r_ok, r_ppage, w_ok, w_ppage} - both views classified and
  installed since the l1-front work; l1_front.sv:132-133 leaves
  `l_w_ok`/`l_w_ppage` unconnected ("the I side never writes").
  256 entries x 256-byte pages, full 64K coverage, flash-cleared on
  `map_changed`.
- **`sub_line`**: mem_cache already hands the whole 16-byte line
  beside the byte on every way hit and fill (never for ROM); the
  icache fills from it by observation. The D$ fills the same way.
- **The snoop pattern**: icache_l1 has one snoop port; l1_front
  arbitrates the classified op's snoop (`cl_snoop`) over the drain's
  (`snoop2_take = snoop2_en && !cl_snoop`). The D$ needs the same two
  producers handled (see "Snoop obligations").
- **The claim pattern**: `l1_claim` (3-clock bounded window) vs
  `decide_go` requiring `!l1_claim` - the mutual exclusion the D side
  will mirror.

## The laws (hard-won; break none of them)

1. **Nothing in a serve cone but FFs and one LUTRAM** - and after the
   timing relief, not even the LUTRAM read in the same clock as a
   late-settling address. The 2026-08-30 session's findings: an
   address decode at the end of the AGU cone was the design's worst
   path twice over (drv_div, now cut via a registered query address;
   dq_cls, still the standing WNS at +0.001-0.14). **The D$'s serve
   verdict must be a registered bit compared against registered
   state.** The 2-clock budget makes this natural: clock 1 the AGU
   settles the address and it registers; clock 2 the registered
   compare serves. Do not try to serve in the address's own clock.
2. **The lookup path must never descend from `din`** - the I side
   grew a combinational loop that way (din -> AGU -> addr -> byte mux
   -> din); Vivado broke 12 loops arbitrarily before it was found.
   Data addresses DO descend from din (that is what the AGU is), which
   is exactly why the D$ answers a clock later from registered copies.
3. **Fast ops have a present and no commit** (accel_seq.sv:50-52).
   D$ ops are fast ops. Do NOT harden this invariant into the new
   code - the soft-switch internalization (next phase) will bend it -
   but do not break it either: nothing that acts on a commit may be
   D$-served, which holds by class ($Cxxx is never fast).
4. **The books are never shed.** `op_tick` must pulse per retired D$
   op (floppy and Mockingboard timers tick on core ops - a user
   decision), and the governor must be paid (`can_pay`/`pay`) exactly
   once per op. Credit is single-writer (a lost-tick bug lives there;
   see accel_seq's gov_next).
5. **Write events may not be dropped, ever.** See the budget section -
   this is the one genuinely new problem the D$ creates.
6. **Reset discipline** (policy, 2026-08-30): new RTL resets CONTROL
   state only; reset is never a live gate in a fast cone (registered
   qualifiers); the regional-reset-tree audit is scheduled BEFORE this
   phase - do it first (u_regfile/rst is fo=2393 and has wandered onto
   the turbo cone once already).
7. **Close timing by reading the worst path, never by seed.** Builds
   are ~7 minutes single-pass now; keep them that way. The path
   extraction trick: the routed checkpoint lives at
   /mnt/c/temp/strudelworks-build-master/strudelworks.runs/impl_1/,
   and a batch `report_timing -max_paths 150 -slack_lesser_than 1.5`
   against it enumerates every near-critical endpoint (the 2026-08-30
   session's timing_paths.rpt pattern).

## Step 0 - the design discussion (USER-GATED - do not skip)

The user wants the D-fetch design conversation before RTL. Items on
the table, with the analysis to bring:

- **The page-compare classification idea** (the user's, parked from
  the l1-front session). The I side's page register holds the last
  used page's translation in FFs so the serve clock never reads the
  TLB. The D side wants the analog: a D page register (or two - zero
  page + stack are 6502-hot and distinct from the data page), with
  `page_match` on registered address bits. Bring: the measured page
  locality of data ops (instrument accel_tb - what fraction of fastD
  hits the last data page / zp / stack), which decides one register
  vs a few vs reading the TLB's LUTRAM in the first of the two
  clocks (legal - clock 1 is not the serve clock).
- **Possible fusion with the decision path**: dq_cls (the standing
  WNS) exists to classify the op the sequencer decides on. A D-side
  page register that already says "this page is image-servable both
  ways" could subsume the class decode for the common case and
  relieve that path; the false-path memo in DIAG_ACCEL_HW.md is the
  alternative if not. Worth deciding together.
- **Write buffer shape**: MEMORY.md places it in mem_client's queue;
  the l1-front memory says "small". Depth, and the read-after-write
  rule (forward vs stall-on-match - with a small buffer, compare and
  stall is the simple sound choice).
- **Write-event backpressure**: stall vs shed (see next section - the
  answer must be stall; the question is where the stall bites).
- **Storage**: a dedicated D$ BRAM (icache-style, 4KB direct-mapped,
  physically indexed/tagged in the 25-bit {rom, pa} space - data
  reads CAN be ROM) vs serving from a wider structure. The icache's
  physical tagging means map changes flush only the TLB, never the
  cache; keep that property.

## The write-event budget - the one new wall

Today a fast write's event word is emitted **unconditionally**
(accel_seq.sv:431-438 - no fev_room gate) into event_merge's DEPTH=8
FIFO (card_link.sv:773 overrides the default 16!) draining one word
per three clocks. At 9 clocks per op that never backs up. At 2 clocks
per op, a run of writes outpaces the drain 1.5:1 and words WOULD drop
- and a dropped fast WRITE silently diverges the host mirror, the
display, and later hdwrites (blocks come FROM the mirror). aovf != 0
is the tripwire (ACCEL_STAT[15:8]; not cleared by cnt_clr, only rst).

So the D$ write path needs real backpressure: a write op may not
retire (no cyc_en, no op_tick, no pay) until the merge has room for
its word. Turbo events are already shed at source via fev_room
("the books are never shed" - but turbo events are not books; write
events ARE). Design the stall so it lands on the op, not the FIFO:
`fev_room`-style credit checked in the D$ serve verdict (a registered
term - law 1). Bring the arithmetic to step 0: worst-case sustained
write rate (STA/zp loops ~= 1 write per 5-6 core clocks at 2-clock
data ops) vs 1/3-clock drain, and whether DEPTH wants to be 16 again
(DIAG_ACCEL_HW.md already asked; the TX ring behind it has the
bandwidth - the FIFO is just the smoothing).

Reads emit event words too (fast reads carry mem_sub_data) - same
arithmetic, reads are ~3x the writes.

## Snoop obligations (the D$ inherits all of these)

From the 2026-08-30 survey of every producer that writes memory
behind the core's back:

| producer | mechanism today | D$ must |
|---|---|---|
| core's own writes (fast/bus/override, incl. diverted RamWorks) | cl_* classify -> icache cl_snoop; mem_cache updates its own way | update-or-invalidate its line (own writes are its own port; bus/override writes arrive via cl_*) |
| hd_card DMA line drain | dq_* straight to DDR3; inv_line_* walks mem_cache's li FSM; snoop2_* to the icache (arbitrated behind cl_snoop) | a third snoop consumer, same arbitration pattern; mind D_WRITE -> D_INV -> D_SNOOP ordering (hd_card.sv:374-378) |
| host invalidate | mem_invalidating -> icache flash-clear | flash-clear (FF valid vector, like the icache - NOT mem_cache's 512-clock walk) |
| ROM reload | rom_ok edge -> flash | flash |
| map change | TLB flush ONLY (caches are physical) | nothing, if physically tagged - keep it so |

The mid-DMA overlap corner (the machine touching an in-flight DMA
target) is DOCUMENTED-UNDEFINED; do not chase it.

## Step 1 - the reset audit (policy prerequisite)

Regional pipelined reset trees per the adopted policy (UG949/WP272
doctrine): audit u_regfile/rst's fo=2393 net, split card rst /
cpu_rst / link domains formally, convert opportunistically. Scope it
small - the point is that the D$'s new RTL is born reset-lean and the
flat net stops growing, not a wholesale conversion mid-branch.

## Step 2 - the RTL (after step 0 settles the shape)

Sketch, to be revised by step 0: a `dcache_l1.sv` + D-side extension
of l1_front (or a sibling `d_front`), fed by the existing TLB's write
view; 2-clock hit (clock 1: registered address + steer; clock 2:
registered verdict serves, cyc_en late-cancel style); fills by
observation from sub_line like the icache; write-through with the
small buffer in mem_client's queue; the merge-credit stall in the
verdict; op_tick + pay per op; a d_claim window vs decide_go mirroring
l1_claim's mutual exclusion.

**Add the chicken bit on day one**: ACCEL_CTRL [27] dcache_dis gating
the D$ serve permission, host key + `swctl accel dcache on|off`,
following [25]/[26] exactly (wb_regfile -> card_link pass-through ->
master_top gate - remember the card_link port forwarding, it was
missed once). The 2026-08-30 lesson: the hardware bisects itself in
minutes when the lever already exists.

## Step 3 - sims (the fix-proving battery, extended)

Encode every behavior as an accel_tb phase BEFORE trusting it:

- Data-heavy phases: zp hammer, abs,X streaming reads, RMW (INC abs),
  page-crossing data, stack storms (JSR/RTS chains) - with the
  reference model checking every byte and the op-cost mix printed
  (the l1-front memory's measured-mix method).
- Write saturation: back-to-back STA loops long enough to fill the
  merge FIFO; PROVE stall-not-drop (aovf stays 0, mirror byte-exact).
- Drain-under-D$: hd_card lines landing in D$-cached addresses
  mid-run (extend the accel_tb drain phase); write -> invalidate ->
  snoop order observed.
- Map-change storms under D$ (PAGE2/HIRES/LC flips - the TLB flush
  must be sufficient because the D$ is physical).
- SMC both directions: D-write then I-fetch (icache snoop, exists);
  I-page then D-write to it; D-read of a drain-written line.
- Both PHI0 sweeps (49 and 47) - the 47 sweep caught a real
  one-clock dispatch regression in the timing-relief session; it
  guards the no-stolen-cycles invariant. `sim/run_accel_tb.sh` runs
  both by default; a sweep's FAIL exits nonzero - read rc, not the
  tail (a lesson).
- Sim-only `$fatal` checks in the RTL for cross-module contracts,
  `ifndef SYNTHESIS`, per the apple_bus_write precedent - they caught
  two real bugs in one evening.
- The whole battery: accel_tb both sweeps, predict, tlb_trace, mem
  trio, fb_sim, hd_card_tb, floppy, vbl_lock, peripherals, lint.
  Monitor long sims by progress counters, never timeout-and-retry.

## Step 4 - build and hardware

Build ~7 min (`build/build.sh --master`); read timing_summary.rpt and
the checkpoint's top-150 before calling it closed; expect the D$
verdict logic to land near dq_cls's neighborhood - if WNS degrades,
read the path, don't reseed. Then: stop swhost on the Pi (pgrep
first), `build/load.sh build/results/master_top.bit`, `tools/pi.sh
run`, and the workloads: Nox with music, Total Replay slideshow walk,
counters clean (aovf/mlate/mdrops/mmismatch/retries), the corner HUD
for the effective ratio (should read ~41x territory in mode 2
unlimited), and a soak. Host changes cross-compile ONLY (pi5 preset);
never build on the Pi.

## After this (do not start, do not preclude)

- **Soft-switch internalization** (the bus ops' 25%): mode-gated
  reclassification in apple_mmu.classify(); will bend law 3 with a
  synthetic commit - which is why law 3 must not be hardened now.
- The 1-clock D$ rung (LUTRAM or falling-edge RAM).
- Pipelining mem_cache / posted writes for mode 1 (ACCELERATION.md
  "Not here, deliberately").
