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

## Step 0 - the design discussion: OUTCOMES (held 2026-08-30)

The measured locality (accel_tb, fw 4c3d78e, mode 2, 7284 fast data
ops): zp 53.6%, stack 1.9%, one floating register 35.2%,
zp+stk+one-float 57.0%, zp+stk+two-float LRU 99.3%. The workload
alternates two data pages (a copy loop's src and dst) - one floating
register can never hold that pair, two hold it almost perfectly.

- **The zp/stack store (USER'S DESIGN, settled - both rounds)**: a
  dedicated 512-byte BRAM (32 lines x 16 B, per-line valid FFs),
  the AUTHORITATIVE HOME of physical main pages 0 and 1 - not a
  cache of them.  Identity is permanent: no tags, no map_changed
  interaction.  The serve qualifier is registered addr[15:9]==0 AND
  a registered "zp/stack maps to main" bit (ALTZP-effective state;
  changes only via soft-switch bus ops, stable in the fast cone).
  ALTZP-on and RamWorks-banked zp/stack fall to the ordinary D$
  path, correct but unprivileged.  Writes update the BRAM and go NO
  further: no write-back line, no queue entry, no DDR3 traffic -
  DDR3's pages 0/1 go permanently stale - so a main-zp/stack write's
  retirement depends only on event-FIFO room.  LAW 5 STANDS: the
  event word is still emitted per write (the host mirror is built
  from the stream; hd writes take blocks from the mirror).  The
  corners the authority creates, each with its existing pattern:
    1. a WRITE to a cold line is not fast-servable - it rides the
       sequencer once and the passing sub_line installs the line
       (DDR3 is still fresh for any line the BRAM never dirtied);
       reads fill by observation as usual;
    2. the icache must NEVER install physical main 0/1 (its fills
       read now-stale DDR3), and I-fetches there - stack-page
       loaders, rare - are served by the D-front from this BRAM at
       2 clocks.  THE SMC TRAP: forget this and code run from the
       stack page executes stale bytes;
    3. a DMA drain landing in pages 0/1 snoops this store to COLD
       (an invalidate would lose authoritative data, but the drain
       just wrote that exact line to DDR3, so cold-then-refetch is
       correct).  Host invalidate: flash to cold, same logic - the
       host is replacing the image and DDR3 is the new truth.
  NOTE for the next phase: the card-side image is now DDR3 plus
  this overlay; soft-switch internalization inherits that.
  Why dedicated at all: in a 4KB direct-mapped D$, pa[11:4] puts
  zp/stack at indices 0-31, the same rows as the first 512 B of
  every 4KB region (both HGR page bases included) - drawing loops
  would evict them all day.
- **The floating pages**: a 2-entry LRU of page registers
  ({page, ok both views, ppage} in FFs), reloaded from the TLB off
  the serve path on a mismatch, one-clock stall, the I-side pattern.
  Covers the non-zp/stack remainder at 99%+ by the measurement.
- **No fusion with the decision path**: dq_cls stays as it is. Once
  the D$ serves, only misses and slow classes reach the sequencer's
  decision, so the pressure drops naturally; revisit after, with the
  DIAG_ACCEL_HW.md false-path memo as the fallback.
- **Write buffer: MERGING write-back lines, a small set (user's
  call, refined)**: FOUR open lines {line, 16-bit be, 16 B, dirty},
  LRU - not one, because the write path is shared and zp/stack are
  ~55% of write traffic: with a single line, every JSR/PHA/INC-ptr
  between stores to a streaming line would force a flush.  Four let
  the zp line, the stack line and the fill line coexist and all
  merge.  A same-line write ORs in a lane; a fifth distinct line
  evicts the LRU one as a single line push.  mem_client's queue
  entries are ALREADY {fill, id, line, be, data} (mem_client.sv:
  110-124 - a byte write is a line write with one lane), so no
  format change.  Land merged lines the DMA-drain way: dq_* push +
  inv_line walk of the L2 + the in-order queue that already forbids
  a fill passing a drained line.  Coherence is structural: open
  lines shadow ONLY DDR3, never the caches (a write updates the
  D$/zp-store copy at retirement), so cache-served reads are
  coherent by construction; only a read MISS descending to L2/DDR3
  compares against the open lines - on the miss path, off the serve
  clock - and stalls until the match flushes.  Other flushes: all
  dirty lines at any override/DMA/hold boundary (bounded, 4 pushes),
  opportunistic writeback when mem_client's queue is empty.  DMA
  overlap with an open line falls under the documented-undefined
  mid-DMA corner.  Line count is a parameter; tune later against
  the counters.  Merging relieves the DDR3/L2 side only - the event
  stream still caps sustained write retirement (next section).
- **Write-event backpressure: stall in the serve verdict + DEPTH
  back to 16** (see next section for the arithmetic).  The stall
  machinery is settled as mandatory (user: it WILL happen at high
  acceleration); both walls gate retirement - event-FIFO room
  (law 5, correctness) and buffer-full-pending-eviction.  Sizes
  (4 lines / 16 events / queue 4) are starting points to tune.
- **Storage**: dedicated 4KB direct-mapped D$ BRAM, physically
  indexed/tagged in the 25-bit {rom, pa} space (data reads CAN be
  ROM), FF valid vector, flash-clear; map changes flush only the
  TLB, never the cache. Now free of zp/stack index pollution.

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

## Step 1 - the reset audit (DONE 2026-08-30)

The audit: one 100 MHz domain (clk_ctrl = apple_clk); the flat rst
originates in card_link (~clk_locked | tickcount<1ms | cmd_reset,
card_link.sv:409) and fans into ~27 modules plus card_link's
internals; cpu_rst adds the live !apple_res_sync term.  Every
assertion is held >=100,000 clocks, so a two-flop pipelined replica
is the same reset two clocks later; the only skew windows are at a
card reset's edges, a millisecond before anything moves, and the
machine-RES' term is common and unpiped, so runtime reset behavior
is bit-identical.

The conversion (master_top): rst_core / cpu_rst_core, a two-flop
replica feeding the accelerated neighborhood only - cpu65c02,
accel_seq, l1_front (TLB + icache inside), apple_mmu, apple_rom,
mem_cache.  Cards, injectors, capture and the link stay flat and
convert opportunistically later.  The D$ takes rst_core, never
apple_rst.  Build: WNS 0.000 / WHS +0.050, worst path still the
dq_cls cone (identity unchanged, phys_opt closes it) - the reset
change moved nothing.  On hardware only with the D$'s first bit.

## Step 2 - the RTL (shaped by step 0's outcomes)

A `dcache_l1.sv` + D-side extension of l1_front (or a sibling
`d_front`): the dedicated main-zp/stack BRAM, the 2-entry LRU page
registers fed by the TLB's both-view classification, and the 4KB D$;
2-clock hit (clock 1: registered address + steer; clock 2: registered
verdict serves, cyc_en late-cancel style); fills by observation from
sub_line like the icache; write-through via the merging line
accumulator into mem_client's queue (dq-style landing + inv_line);
the merge-credit stall in the verdict; op_tick + pay per op; a
d_claim window vs decide_go mirroring l1_claim's mutual exclusion.

**Add the chicken bit on day one**: ACCEL_CTRL [27] dcache_dis gating
the D$ serve permission, host key + `swctl accel dcache on|off`,
following [25]/[26] exactly (wb_regfile -> card_link pass-through ->
master_top gate - remember the card_link port forwarding, it was
missed once). The 2026-08-30 lesson: the hardware bisects itself in
minutes when the lever already exists.

## What the first cut's debugging established (2026-08-30, overnight)

Seven rules the sim battery forced, each a real failure first.  They
rank with the laws for anything that touches this design later:

1. **A claim term may not descend from the live address.**  A data
   address holds din through the AGU; the first cut's claim decoded
   live cpu_addr and closed a combinational loop d_hit -> cpu_din ->
   AGU -> claim -> d_ok -> d_hit (law 2's exact trap).  The claim is
   registered (da_q) - sufficient, because the dispatcher cannot fire
   before `settled`, which is one clock behind, the same clock da_q is.
2. **The wb flush selects on one edge and captures on the next**
   (F_CAP).  Capturing on the selection edge read the pre-merge word
   for a byte merging that very edge, then cleared dirty: the byte was
   lost to DDR3 forever.  Purges apply through F_CAP, and to the
   captured word while the push waits; after acceptance the in-order
   queue resolves against later writers.
3. **Fill-by-observation never touches a VALID zp/stack line.**  Valid
   means AHEAD of the L2; the passing sub_line is the L2's stale view.
   (The icache never had this rule because its validity never outruns
   its L2.)
4. **Reads never wait for event room; their events shed like turbo's.**
   A zp/stack-valid read that misses its window falls to the
   sequencer's stale path - so nothing optional may hold a read in the
   window.  Law 5 is about writes; the sparse filter discards RAM-read
   events anyway.
5. **The try window counts only clocks a serve was possible** (tries
   advance gated on d_ok).  Under the governor's hold the op parks
   with the window alive; the dispatcher is blocked by the same
   can_pay, so nothing deadlocks.  Where d_ok stays low with the
   dispatcher free - the reset sequence, mode off - run_rd/run_w
   withhold the claim entirely (a claim there only split the reset
   sequence's consecutive stack reads, which the machine's MMU counts
   on the pins).
6. **A D$ write serves only through a proven row** (steered_right AND
   look_ok): the row then answers present (update in place) or PROVEN
   absent (wb alone).  An unproven row left a present line stale
   behind the wb byte.  A write that lapses to the sequencer instead
   is safe - its classified pass snoop-invalidates the D$ line.
7. **A bare invalidate is not a reload.**  The L2 walk under a running
   machine must not discard the wb lines (they flush by age - they
   are the only copy of recent writes) and must not flash the
   zp/stack store (its bytes exist nowhere else).  The store flashes
   only when the invalidate arrives UNDER A HOLD (hold_lvl) - an
   image reload always holds the machine, and the override's flush
   drained the wb lines before the hold ended.  The D$ still flashes
   unconditionally: it is a true cache and DDR3 is its truth.

And two monitor rules: mem_cache's mismatch counter skips wb-dirty
lines and zp/stack-valid lines (both legitimately ahead of the way),
or every reset sequence's stack reads would count false mismatches on
hardware.  The testbench likewise exempts the reset sequence's bus
reads from the reference compare - they read the stale machine by
documented design - and holds the core (the settle override, which
also exercises ovr_flush) around every image comparison.

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
