# The instruction stream front: two lines riding the code's linearity

> **SUPERSEDED IN PART, 2026-09-08.**  The memory rethink
> (`docs/MEMORY_REFACTOR.md`) replaced the two fixed 64 KB banks and the ROM's
> own block RAM with ONE PHYSICAL SPACE of 256-byte pages, cached 128 sets x 8
> ways: `rtl/bank_ram.sv` and `rtl/apple_rom.sv` are DELETED, the ROM is
> physical bank $FF loaded through the posted-write seam
> (`rtl/rom_loader.sv`), and the fronts' line port answers `il_done` three
> clocks after its grant.  Everything below that names those modules, the two
> banks, or the ROM beside the cache describes the design that was replaced.
> The current design is `rtl/page_cache.sv`'s own header and
> `docs/MEMORY_REFACTOR.md`; this file was not rewritten (a decision, not an
> oversight - the user's, 2026-09-08).

> **THE RETAINED SET, INDEXED (2026-09-11 night; docs/GS.md "Where the
> stalls are"):** the eight-entry fully-associative CAM becomes a SIXTEEN-SET
> BY FOUR-WAY line cache, 64 lines, the data front's shape (rtl/dline.sv's
> 8x4 cache, the one that worked).  Motivation: GS/OS's desktop at the
> unlimited target refilled 40.6 M instruction lines in ten seconds - one
> every six fetches - with 21.9 M lines dropped by bank changes and 2.7 M
> revived; IFILL alone was 14% of all clocks and the fetches that fell to
> the dispatcher more.  Toolbox code does not fit ten lines.
>
> **The set is the line-in-page.**  A line's virtual tag is addr[15:4]; its
> low four bits, addr[7:4], are the set index (`ICS = 16`) and the high eight,
> the page, the stored tag.  That choice is the whole design: addr[7:4] is the
> same in the virtual and the physical space (a page is 256 bytes), so the
> write snoop and the install's dedupe index by the write's line-in-page and
> compare only `ICW = 4` physical page numbers, and the candidates index by
> their own line-in-page and compare four eight-bit tags.  Nothing compares
> across the whole set any more: the eight 12-bit compares per candidate
> become four 8-bit ones behind a 16:1 select, and the snoop's eight
> 20-bit compares per source become four 16-bit ones.
>
> **What each line carries** is exactly what a CAM entry carried: valid,
> retained, the tag, the physical page, the region, the fold and the virtual
> bank, all in flip-flops (a map change reads them all at once), and the 128
> bits of data in ONE 64-deep LUTRAM per read port, addressed by {way, set} -
> the way from the compare, so a candidate's byte is compare -> read -> the
> 16:1 byte select, inside the full clock the lookups already have into
> their registers (i_byte_q, tgt_byte_q).  Six read ports: the five
> candidates and the promote's copy; one write port, the install at F_W2.
>
> **The serve path does not change.**  The two slots, the +1 predictor, the
> registered candidates, the early branch resolution, the scanner and the
> pinned pair are untouched.  Two cones move to registers and get shallower:
> the retire's `ihit` takes the cache's term at exp_q's set (retire already
> demands exp_q == pc_addr, and the target path's at tgt_q's), and
> `kill_now`'s cancel is the write's set against the serving set.
>
> **Install, dedupe, promote, snoop, revalidation** are the CAM's rules per
> set: a committed line goes to the retained way of its set that already
> holds the same physical page (the dedupe - one live copy per identity) or
> to the set's round-robin victim; a promote finds the valid way with the
> picked tag and copies its row a beat later (F_CAM, as before); a write
> kills every retained way of its set whose page matches, from both sources;
> a map change recomputes every line's valid bit from its stored identity in
> the two register-rooted stages the slots and the data front use, and the
> books count drops and revivals from registered copies.
>
> **Cost**: ~3,000 flip-flops of identity, 48 Kbit of LUTRAM (~800 LUTs) for
> the six replicas, and the revalidation's breadth (64 lines a clock, off
> every serve cone).  BRAM is not involved.  `ICS`/`ICW` are parameters; the
> IIe build takes the same shape and the battery's bptest - the four-line
> loop only the retained set can hold, the promotes and scan fills it
> asserts - is the gate there.
>
> **16x4 BUILT AND WITHDRAWN (gs_icache, the same night):** TIMING MET at
> +0.003 with 0 of 95,783 failing, LUTs 55 -> 62%, and the bitstream NEVER
> CALIBRATED THE DDR3 on the card (UART D=0 on two loads; the previous bit
> calibrates at once on the same board) - docs/GS.md "The retained set and
> the DDR3".  The census named the pressure: the candidate lookup into
> i_byte_q at 9.89 ns, and the snoop's live 16:1 page select and compare
> running through kill_now, the retire and every core enable (13-16 levels,
> 0.005-0.09 ns).  **So the set is 8 x 4, the data front's size** - the set
> addr[6:4], the tag addr[15:7], the physical identity the page AND addr[7]
> (`ic_a7`, the data front's PTW) - **and the kill lands a clock later** from
> a registered compare (`kq_*`); what stays live in kill_now is a 3-bit set
> match (`ic_cancel`, plus its registered copy for the clock the kill takes
> to land), and the promote's copy checks the pending kill (`ic_pro_dying`).
> A write anywhere in the fetch's set costs one clock; nothing serves a dead
> line.
>
> **ON THE IIgs TOO, 2026-09-11 (docs/GS.md rung 6):** the front builds at
> `GS = 1` and serves the 65816's program stream at `{pc_bank, pc_addr}`.
> Each line stores the virtual bank it was fetched in; the bank registers are
> part of the map, so a JSL/RTL revalidates rather than flushes; the I/O
> window's exclusions apply in the four pair banks alone.  The IIe's netlist
> is unchanged (`GS = 0` folds every bank to zero).

Status: **built, proven in simulation, and TIMING CLOSED, 2026-09-01;
branch `page_cache`, both repositories - accel_tb 27.7x mode 2 unlimited
(48 checks, both sweep points, self-modifying code included), master
build WNS +0.490 ns; not yet on hardware.**  This is the
first step of what the acceleration branch called "turbo", redone on the
page cache and taken the full way through by decision: the icache first,
the data side later, and no chicken bit.

**The branch-prefetch extension (branch `branch_prefetch`, 2026-09-01)**:
the retention CAM - which SERVES, making the front a ten-line
associative icache - the branch scanner, the pinned pair, and early
branch resolution on the core's exported flags, below.  **99.3% of the
mode-2 instruction stream at one clock per fetch**, taken branches and
JMP/JSR to resident lines at ZERO stall.  Proven under Verilator (53
checks, both sweep points, the self-modifying-code scenarios included;
sim/run_accel_vl.sh) and **TIMING CLOSED: setup WNS +0.058 ns, hold
+0.055, zero failing endpoints** - after two rounds against exactly the
predicted families (below).  NOT yet run under iverilog, NOT on
hardware.

The idea is the user's design.  Instruction streams are very linear, so:

- **The core says what a fetch is.**  `cpu65c02.cyc_is_i` classifies every
  cycle from the address mux itself - PC-sourced is the program stream,
  dummies included, tagged by what they are derived from; stack, vectors
  and the LAST/FIXUP re-reads are data - and the data return is SPLIT
  (`i_din`/`d_din`), so the instruction front can hold its speculation on
  one port while the data path owns the other, neither caring what the
  other predicts.  Proven by `sim/run_cpu_predict_tb.sh`: both Klaus
  suites at one clock per cycle with GARBAGE riding the inactive port on
  every clock, cancels included.
- **Two 16-byte lines, one clock per fetch** (`rtl/iline.sv`).  The line
  the program executes from and the one after it.  A program-stream fetch
  that lands in either retires at a cadence of ONE: the byte stands
  registered from the previous edge's predictor lookup, the tag compare
  runs off the PC registers, and `cyc_en` - asserted speculatively, pulled low at the end of the
  clock by any late "oops" (an override engaging, a map change, a snoop) -
  is the RDY-style late cancel; a cancelled edge consumes nothing.
- **The prefetch is next-line.**  On the first retire out of a newly
  entered line, the old slot is refilled with the line AFTER the new one,
  so execution crosses each boundary into bytes already registered.  The
  whole 16-byte row is one read: the page cache's banks are 128 bits wide,
  and the prefetcher steals port A on any clock the op path leaves free
  (`page_cache.il_*`); a ROM line streams four words from the ROM
  loader's otherwise-idle port (`apple_rom.r2_*`).  Jumps and taken
  branches out of the held pair are not predicted - they miss once, ride
  the sequencer at its usual price, and the front trains itself on the
  miss in parallel, so the next fetch hits.  A short branch WITHIN the
  pair is free after ONE stall beat: the served byte and its select are
  REGISTERS fed by the front's own "+1" predictor (exp_q, the last
  program-stream fetch plus one - the user's design, and the shape that
  closes timing).  Three byte candidates are looked up in parallel from
  registers - the sequential step, the recovery at cpu_addr, the hold -
  and the late verdicts only pick among them; a mispredicted fetch
  re-aims the predictor and serves on the next clock.  Why not a live
  mux, and why not the core's i_pred: a combinational byte mux on
  cpu_addr closes a structural loop through the core's AGU (din -> addr
  -> byte mux -> din; never logically active, but synthesis ballooned to
  52 GB on it), and a lookup at i_pred drags the core's next-PC carry
  chains plus the late cyc_en select into one 18-level cone (-1.5 ns).
  A retire checks prediction against the fetch on offer and the live
  tags both, so the byte is always exactly this fetch's; a fill's first
  serve is one clock after its commit.

## What a line is

Each slot: valid, the virtual tag (`addr[15:4]`), the folded physical
identity `{aux, bank, off[15:4]}` captured from the classifier at fetch
time, a ROM flag, and 16 bytes.  Classification is per-page and the LC
fold per-4K, so a 16-byte line never straddles a mapping boundary.  Every
class serves at turbo cadence - main, LC, ROM (system and CX), and
auxiliary/RamWorks alike; an aux line adds only a residency check at the
fill (the engine's tags), and a non-resident page simply declines - the
demand miss rides the sequencer, whose page engine does the fill, and the
retrain after it succeeds.

## What is never served here

- BUS class ($C000-$C0FF, every slot's pages, the internal ROM unloaded).
- The $CFF0 line, always; and page $C3 while the INTC8ROM latch is CLEAR:
  an access there sets the latch, which the MMU shadow learns at
  `op_present` on the unified stream - and a turbo retire never reaches
  that stream - so the access that sets it rides the sequencer, by rule.
  Once set (any $C3xx access with SLOTC3ROM clear, in either state of
  INTCXROM), the page is an internal-ROM page like any other and is
  served; the clear ($CFFF, a bus op; or reset) pulses `map_changed`,
  which empties the front, and `kill_now` refuses a $C3 serve on the very
  clock the registered latch reads clear, so the RTS after the 80-column
  firmware's own `LDX $CFFF` ($C372) re-sets the latch through the
  sequencer.  The scanner's own pre-filter (rtl/iscan.sv `tgt_excl`) says
  the same; the engine's `excl` is the correctness gate.  This is what
  puts AUXMOVE's copy loop ($C393-$C3AB) at one clock (docs/CXXX.md).
- Any clock `turbo_ok` withholds: an op on the bus or in the cache
  pipeline (its trailing commit may flip switches under a held line's
  feet), an override engaging (the boot hold catching a SYNC cancels the
  retire through this term), the reset sequence, a fast op's event clock
  (so the two never collide at the merge), or no governor credit.

## Coherence

Writes snoop by classified physical identity the clock they classify
(P1), killing held lines and fills in flight before the write lands - and
the core is serial, so the refetch orders behind the write.  Proven by
smctest in `sim/accel.s`: operands and opcodes rewritten and at once
executed, both directions.  A map change (`apple_mmu.map_changed`: any
switch, the LC, the bank register, INTC8ROM, a reset) kills both lines
and restarts the fill with fresh classification.  ROM load traffic kills
ROM lines.  Serving off or an invalidate empties the front.  A page
engine eviction does NOT invalidate - the line is a copy, its bytes stay
the bank's truth for its tag, and any later write arrives through the
snoop.

## The books

The sequencer sees a turbo op only as `turbo_commit`: one governor charge,
one ACCEL_TURBO count (word
41, 0x8000_00A4), one tick for the floppy's and the Mockingboard's
core-time clocks, one `seen_sync` for the boot door when it was an opcode
fetch, and one capture event on the fast-op path (tag 0xC) - emitted only
when the merge has room (`event_merge.fast_room`), shed at the source
otherwise, so `overflows` stays a fault flag.  The dispatcher stands down
for any fetch the front holds or is clocks from holding (`claim`),
bounded by the fill; a decline drops the want and the op rides the
sequencer.  The ratio is (TURBO + FAST + BUS) / CYCLES everywhere.

## The governor: a registered permission token

The user's design, and what finally closed timing.  The governor GRANTS
one op's permission up front, registered (`grant_q`); once up it cannot
go away until an op completes and consumes it, and the consumption
verdict touches nothing but one-bit register inputs.  The pool is the
governor's own bookkeeping, register-in register-out: deposits on bus
ticks, a debit the clock AFTER a consumption, the cap, the re-arm -
nothing in its cone is the consumer's data.  Unlimited holds the grant
high and debits nothing, so turbo's cadence of one is untouched; under a
finite target the one-clock re-arm lag is invisible against a 98-clock
deposit period, grants pair one-to-one with debits, and the measured
ratio stays exact (3.99 at 4.00, 1.00 at 1.00).  The old same-clock
debit - retire's verdict landing inside 21 bits of carry arithmetic -
was the path that refused closure: five endpoints at 20 levels, the
worst threading the sequencer's state through the front's compare,
through the CORE'S AGU CARRY CHAINS (cpu_addr on a data cycle is
din-fed - a functionally false path the analyzer must still time), into
the credit's D.  The token cut the arithmetic out; exporting the PC
REGISTERS from the core (`pc_addr` = {pch, pcl}, flip-flop outputs,
equal to the bus address on every program-stream cycle by construction)
and pointing every compare and lookup in the front at them cut the AGU
out.  Every compare in the front now starts and ends at registers.
The build: **setup WNS +0.490 ns, hold +0.053** - from -0.045 at the
best of the six preceding attempts.

The same registered-trigger pattern is applied throughout, each with a
one-clock lag argued harmless in place: `turbo_en` (mode changes),
`unlimited` (target changes), the miss train, the crossings, the `off`
copy in the sequencer's output muxes.  And one rule found by a
simulation wedge, not timing: THE PREDICTOR RESETS WITH THE MACHINE
(`cpu_rst`), because the core's first post-reset cycles are PC-sourced
with the OLD PC while `reset_seq` and the map-change kill each lag a
clock - a retire in that window feeds a resetting core a stale byte.

## Numbers, in simulation

`sim/run_accel_tb.sh` (sim/accel.s, smctest included, both sweep points):
**mode 2 unlimited 27.7x** (25 955 turbo + 7 471 fast + 181 bus over
1 214 cycles; the i_pred-lookup variant measured 29.2x and failed timing
by 1.5 ns - the branch-beat is what closure costs), mode 1 13.2x, the governor 3.99 at 4.00 and 1.00 at 1.00
with turbo ops paying credit; every turbo byte the reference's, none from
an excluded page; the boot hold and the runtime knock catch the
accelerating core; the reset sequence still rides the bus.  For scale:
the same bench gave 14.2x without the front, and the OLD branch's full
64-line icache + TLB gave 26.4x - two lines beat it here because the
data side behind them is the page cache's three-clock serve.

## The branch-prefetch extension: the retention CAM, the scanner, the pinned pair

The two-line front's blind spot is control flow: a taken branch out of
the pair misses, and - worse - the crossing's rotation refetches a hot
loop's own lines every iteration (entering line B prefetches C OVER A,
so the branch back to A misses, and the train then kills B too).  Three
pieces close it, none of them touching the serve path - the CAM is
behind the fill engine, never in the retire cones:

- **The retention CAM SERVES** (rtl/iline.sv): eight entries, tags and
  folded identities in flip-flops (every compare network reads them all
  at once), the 8 x 128-bit line data in DISTRIBUTED RAM - one write
  port, no block RAM anywhere.  Every line the engine commits is
  recorded (deduplicated round-robin).  Every predictor candidate looks
  up ALL TEN lines - the slots and the entries - so a fetch into any
  resident line runs at the cadence of one: the front is a ten-line
  fully-associative icache, and the promote survives only to re-center
  the pair behind an executing CAM line (the ordinary miss train does
  it unprompted).  The lookups are REGISTERED - a full clock, outside
  the late cones.  Promotion needs no re-classification: the CAM is
  flash-cleared on any map change, so a surviving entry's captured
  identity is still the map's truth for its tag.  Dedupe - one live
  entry per tag, every copy snooped identically - is what makes any
  matching source's byte THE byte.
- **Early branch resolution** (the user's design): at a branch's operand
  cycle everything needed is registered truth - the opcode (latched at
  its fetch), the offset (the byte being served, so a slow serve at a
  line boundary still delivers it), and the flags (`p_flags`, exported
  register-direct from the core like pc_addr before it; the previous
  instruction's writeback landed entering T0 and a branch writes none).
  The front computes taken-and-where right there, by the core's own
  rule, and the target becomes a FOURTH registered candidate - so the
  target fetch, however many dummy cycles later, page cross included,
  serves with ZERO stall.  JMP abs and JSR resolve the same way at
  their high operand byte, whose serve is the cycle before the target
  fetch - the lookup runs live on the byte being served and registers
  at that edge, just in time.  A conclusion cannot be wrong, only
  useless: the candidate serves only when the core's real fetch address
  equals it, revalidated by the live tags like every serve.  A taken
  transfer to a NON-resident line fires an early want instead, ahead of
  the demand miss.  RTS is not resolved (its target is on the stack -
  the data side), but its return line is almost always retained, so it
  pays one re-aim beat.
- **The branch scanner** (rtl/iscan.sv): walks instruction boundaries
  forward from the last opcode fetch through the held pair with the
  65C02's length table - one instruction per clock, two for a branch,
  three for a JMP/JSR - follows unconditional flow (JMP abs, BRA, JSR),
  falls through conditional branches, and issues a CAM prefetch for
  every transfer target's line not already held.  Its wants are the
  engine's LOWEST priority and only ever CAM fills; a ROM target stages
  in f_cbuf so the slots' bytes are never its.  The scanner cannot be
  wrong, only wasteful: a misdecoded stream (mid-instruction entry, SMC
  under the scan) at worst prefetches a line nobody needs, whose bytes
  are still fetched fresh and snooped from then on.
- **The pinned pair**: a transfer the scanner finds from one held line
  into the other sets a loop bit, and the crossing's rotation stands
  down while it holds (`loop_sup`, cleared the clock either slot's
  content changes); independently, a crossing whose next line the other
  slot ALREADY holds no longer kills and refetches it.  Together a loop
  held whole in two lines runs at the within-pair branch's price with no
  refetch at all.

**Coherence is the slots' rules, applied to every copy**: each CAM entry
snoops every classified image write by folded identity (a promote
launching the very clock its entry dies aborts and retries down the fill
path); the map-change flash clear; ROM entries die on ROM load traffic;
inval and serving-off empty it.  sim/accel.s's `bptest` makes each
mechanism unavoidable and each hazard real: a clean two-line hot loop, a
loop REWRITING ITS OWN OPERAND inside the pinned pair, a four-line loop
only the CAM can hold, calls the scanner follows, and the retained
line's own hazard - an opcode rewritten in a line the CAM holds but the
slots no longer do, then jumped back into.  The bench asserts the
promotes, the pins and the scanner prefetches all fired, and checks
every byte against the reference as always.

Measured (Verilator, mode 2 unlimited, the bptest-heavy program):
**99.3% of the instruction stream at one clock** - 35 361 turbo
ifetches against 238 sequencer-served (cold first touches, the excluded
pages, the post-reset stream), 2 730 taken transfers at ZERO stall,
4 428 fetches served straight from the CAM, 192 pinned crossings.
Cycles for the phase fell 1 427 -> 1 337 against the machinery-off
baseline of the same program; the mix, not the bus-bound ratio, is the
signal.

**How closure was won** (WNS +0.058 from -0.038, then -0.126, in two
rounds - the failing families were exactly the flagged watchpoints, and
each fix was the documented fallback):

1. *The resolve lookup's address waited for the retire.*  The first
   build's -0.038 threaded the write snoop -> kill_now -> retire ->
   `resolving` -> the ten-line target lookup -> tgt_byte_q: half the
   period gone before the lookup started.  Fix: the lookup address is
   SPECULATIVE, registers only (bk state, the flags verdict, i_byte_q
   standing for the operand about to be served), and the late serve
   truth gates only the one-bit valid - the house rule (late verdicts
   pick, never compute) applied to the one place it had been broken.
   Cost: a slow-served JMP/JSR high byte falls back to the one-beat
   re-aim; branches and turbo-served transfers keep zero.
2. *The one-clock promote's enables.*  The second build's -0.126 (34
   endpoints) was promote_go - the live pick, the CAM compare - driving
   the 128-bit slot register's CE.  Fix: the promote latches at F_IDLE
   (index and identity into the f_* registers, which also puts it under
   the fill's own snoop) and commits a beat later in F_CAM, the heavy
   enables on a registered state bit; the launch-clock kill race became
   a registered cam_v check in F_CAM.  Cost: none observable - a
   resident line SERVES from the CAM while its promote re-centers.

Still-live widths that DID close and bear watching in future builds:
the ten-way ihit OR in the retire, the two CAM snoop-cancel terms in
kill_now, the replicated CAM read ports behind the candidate muxes.
Registered-hint fallbacks remain available for each.

## Not here, deliberately

- **A branch target buffer proper**: the scanner + CAM buys the line,
  not the predicted next PC; the one-beat within-pair branch stall
  stands (consuming the core's exported i_pred still costs its carry
  chains - see the governor's history).
- **Data-side prediction**: d_din exists for it; nothing drives it yet.
- **A turbo chicken bit**: none, by the user's decision - this restart
  stands or falls whole.
- **Scan-fill yield**: a slot want arriving mid-scan-fill waits for it
  (~228 clocks total in the whole bench run); if a real workload shows
  worse, the CAM fill can learn to yield at F_REQ.
