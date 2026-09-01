# The instruction stream front: two lines riding the code's linearity

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
JMP/JSR to resident lines at ZERO stall.  Proven under Verilator only
so far (53 checks, both sweep points, the self-modifying-code scenarios
included; sim/run_accel_vl.sh), NOT yet run under iverilog, NOT built,
NOT on hardware.

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
- Page $C3 and the $CFF0 line: any access there moves INTC8ROM, which the
  MMU shadow learns at `op_present` on the unified stream - and a turbo
  retire never reaches that stream.  These ride the sequencer, by rule.
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

**Timing watchpoints for the build** (not yet attempted): the retire's
ihit is now a ten-way tag OR off the PC registers; kill_now gained two
CAM snoop-cancel terms; the candidate byte muxes select among ten
sources (registered destinations, but wide); the CAM data wants
replication for its multiple concurrent read addresses (distributed
RAM, ~32 LUTs a copy); the JMP/JSR resolve path runs i_din (late, when
the sequencer serves the high byte) through a compare network into a
registered candidate.  If closure objects: registered hit hints for
ihit at one beat's cost, an F_CAM beat for the promote, and the
JMP/JSR live lookup can fall back to registering the target first
(one beat, branches unaffected).

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
