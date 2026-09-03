# $Cxxx under acceleration: what to serve fast

Status: **STEP 1 PROVEN ON HARDWARE** (2026-09-02, fw 2db1baf, bit in
SRAM) - page $C3 on the instruction front once the INTC8ROM latch is set.
**STEP 2 BUILT AND SIMULATED** (2026-09-02): the keyboard in the dummies -
docs/ACCELERATION.md "The keyboard in the dummies".  Battery 70 checks
0 errors both sweeps; the ProDOS boot bench (2M bus cycles, mode 2
unlimited) 137.2M ops = 68.6x at Bitsy Bye where step 1's bit stood at
~8x there, bus reads over the whole run 12.6k; traces identical to mode
0.  **ON HARDWARE** (fw 9d8d574 / host 3dce2a0, SRAM): Nox at the
overworld map 20x -> 50-60x depending on what it is doing (the user's
HUD reading).  The comparison trace (5 s SPARSE - full capture wedges
the link at this acceleration, the FT601 behaviour ACCELERATION.md
"Sparse capture goes with acceleration" recorded, so the fast-op side
is writes only; every bus event and every cycle is exact):

- bus events 21,145 in 5.00 s of machine time (5.1M cycles) against
  1,005,020 in 2.49 s before - 0.0041 per cycle from 0.3952, a 95x
  reduction; at ~2 cycles a bus op that is <1% of the machine's time on
  the bus.
- $C000 reads: 595 = 119/s = exactly the edge-kept dummies (two per
  frame), i.e. NO program poll rides the bus.
- What remains, all periodic and small: the LC pair $C083/$C08B (2,936
  each), RAMRD/RAMWRT writes $C002-$C004 (5,870), the status reads
  $C011/12/13/14/16 (1,468 each), $C054/$C055 (734 each).  Those are the
  swint-status-page and switch-write items left for later - at <1% of
  the time they are not worth a step on this screen; a trace of a busier
  scene should decide.
wave.dsk: the main section stays at 80x, the end loop goes from 22x to
past 90x - it was almost entirely AUXMOVE fetching from slow memory - and
the user reports everything else on the machine working as before.
The user's decision: treat "what in $C000-$CFFF can be served fast" as ONE
programme rather than piecemeal exceptions, taken up BEFORE dline rung 4
(docs/DLINE.md; streams are deferred, not dropped), starting with $C3xx
because AUXMOVE lives there.  The standing rule holds throughout: a $Cxxx
access that is not the motherboard's own ROM is slow, nothing else is.

## Step 1 (2026-09-02): $C3xx on the front - what was done and why

**The premise, corrected.**  The exclusion of $C3xx was never for the host.
The host models nothing in $C100-$CFFF: strudelworks-host classifies all
of $Cxxx as Bus, tracks INTCXROM/SLOTC3ROM only from the $C006/7 and
$C00A/B WRITES (src/apple_memory.cpp, src/mb_audio.cpp - the Mockingboard
gates VIA writes with them), has no INTC8ROM anywhere, and its MEM_STAT
decode skips bit 13.  Nothing on the host consumes a $C3xx read; the
cycles a turbo fetch replaces are dummies on the pins, counted into
SKIPs, so the beam and the sound clocks never notice.  No bus event, no
"slot owner" notice, no host change.  The one consumer that would desync
was the CARD's own shadow: apple_mmu.intc8rom learns from the unified op
stream at op_present, and a turbo retire never reaches that stream.

**The change (firmware only, branch dcache):**

1. `rtl/apple_mmu.sv`: the latch sets on any $C3xx access with SLOTC3ROM
   clear, in EITHER state of INTCXROM - UTAIIe 5-28 as AppleWin's
   Memory.cpp has it.  The first cut also required INTCXROM clear, a
   divergence in the safe direction (after INTCXROM off without $CFFF the
   card called $C8xx BUS and the machine's internal ROM answered on the
   bus: right byte, slow).  Gone.
2. `rtl/iline.sv`: `excl` refuses page $C3 only while a registered copy of
   the latch reads CLEAR; the $CFFx line always.  The first $C3xx access
   still rides the sequencer (a ROM-class FAST op) and sets the latch at
   op_present; map_changed pulses the clock after and empties the front,
   and no $C3 line can even be wanted before that.  The clear ($CFFF, a
   bus op; or reset) pulses map_changed too, and `kill_now` additionally
   refuses a $C3 serve on the clock the registered latch reads clear - so
   the RTS after the 80-column firmware's own `LDX $CFFF` at $C372 rides
   the sequencer and re-sets the latch whatever the driver's data/cyc_en
   spacing (today it works by T_CYCEN = T_DIN + 1 alone: zero clocks of
   margin, the same property every switch write relies on).  The
   resolved-branch early want uses the same function; the scanner's own
   pre-filter (`rtl/iscan.sv` tgt_excl - a SEPARATE copy, the earlier
   version of this file said "the same function" and was wrong) carries
   the same term.
3. The testbenches: both machine models set the latch the machine's way;
   accel_tb asserts the STRICTER rule (its model clears at present of
   $CFFF, the card at commit) and counts page $C3's fetches by path; the
   internal ROM image gets code resident in $C3xx ($C372 the firmware's
   shape, $C380 a one-line loop, $C39A a loop across two lines) and
   cxtest runs all four shapes including the INTCXROM-set case.

**Sim result (sim/run_accel_vl.sh, both PHI0 sweeps): 65 checks, 0
errors.**  Per sweep 1170 $C3xx fetches at one clock and exactly 15 on
the sequencer - three per pass, one per latch-set episode ($C380 after
the entry clear, the RTS at $C375, $C380 under INTCXROM), five passes.
Mode 2 unlimited 68.9x as before (the test program is not AUXMOVE-bound).

**Not run:** sim/run_mmu_trace.sh - the real captures (sim/trace_work,
gitignored) are not on this machine.  Note for when they are: a BUS-class
read is never compared there, so diff the ROM `classes`/`compared` counts
before and after; more ROM compares at 0 mismatches is the proof of the
changed set condition.

**Hardware (2026-09-02, the user driving wave.dsk):** the previously
fast section unchanged at 80x; the previously slow end loop from 22x to
past 90x.  Nothing else changed behaviour.  A trace census of the loop
(tools/swtrace_mix.py) was not taken - the HUD figure was the proof.

## The finding that started it (2026-09-02, on hardware)

wave.dsk's final loop runs at 22x unlimited while its main section runs at
80x, on rung-3 firmware (fw 8c59006, host 9239498) with the governor
holding a configured 8x at 8.00 in both sections - so the counters are
right and the difference is real.  A 3.07M-cycle sparse trace of the loop
(tools/swtrace_mix.py on the host) showed:

- **584 real bus ops in 3.07M cycles** - one per ~5,000 cycles.  The bus
  is NOT where the cycles go.  They are AUXMOVE's setup: writes to
  $C002-$C005 (RAMRD/RAMWRT), reads of $C013/$C014, $C054/$C055.
- **Fast ops exactly 8.00 per cycle** (the governed rate), 24.5M of them.
- **583k iterations of an 11-instruction loop whose opcode fetches are all
  in $C393-$C3AB**: the IIe's AUXMOVE ($C311) copy loop in the internal
  $C3xx firmware, reading the monitor pointers $3C/$3D and $42/$43 and
  incrementing them.  The data side is one-clock already (dline); every
  one of the ~11 fetches per iteration rides the dispatcher at ~9 clocks,
  because page $C3 is the one page rtl/iline.sv never serves, by rule.

That rule (docs/ISTREAM.md, rtl/iline.sv `excl`): an access to $C3xx SETS
the INTC8ROM latch, and $CFFF clears it; the MMU shadow (rtl/apple_mmu.sv)
learns the latch from the unified op stream, and a turbo retire never
reaches that stream - so both are excluded from the front whole.  The
same exclusion sits in the dline's last-byte serve ($Cxxx whole).

## What the classifier says today (rtl/apple_mmu.sv, "THE CX CLASS")

- $C000-$C0FF: BUS, always (soft switches, I/O).
- $C100-$C7FF page n: the INTERNAL ROM (class ROM, served fast) when
  INTCXROM, or n == 3 with SLOTC3ROM clear; else BUS (a slot's).
- $C800-$CFFE: internal ROM when INTCXROM or INTC8ROM; else BUS.
- $CFFF and every $Cxxx write: BUS.
- INTC8ROM: set at op_present of any $C3xx access with INTCXROM and
  SLOTC3ROM both clear; cleared at the commit of any $CFFF access or by
  RES'.  MEM_STAT[13] reads it.  map_changed pulses on every change of it
  (and of every switch), killing every held line and both CAMs.
- The user's standing rule (docs/ACCELERATION.md): a $Cxxx access that is
  not the motherboard's own ROM is slow - every slot is hardware and rides
  the bus - and nothing else is slow.  The plan must keep that.

## The refinement as first identified (BUILT as step 1, above - the term is the latch alone after the set-condition fix; and iscan has its own copy of the rule)

Exclude $C3xx from the instruction front only while the latch could still
change: while INTCXROM and INTC8ROM are both clear.  Once INTC8ROM is set
(the first $C3xx access does that through the dispatcher, as today) or
INTCXROM is set, a $C3xx access changes nothing on the card or the
machine, so serving it is safe; the latch clearing ($CFFF) and INTCXROM
moving already pulse map_changed, which kills every held line, and the
exclusion resumes until a real $C3xx access re-sets the latch.  $CFFF
stays excluded.  One registered term in iline's `excl` (intcxrom ||
intc8rom, from sw_state[6] and mem_intc8rom), the same term in the
scanner's want filter (it uses the same function).  Expected effect:
AUXMOVE and every 80-column-firmware loop at one clock; the demo's end
loop from 22x toward the fast section's figure.

## The second finding (2026-09-02, on hardware): Nox at the overworld map, 20x

A 5 s FULL capture (26.2M words, 2.54M bus cycles = 2.49 s of machine
time, 1.005M real bus events, 23.6M fast words) of Nox sitting at the
overworld map on the step-1 bit, showing 20x on the HUD:

- **92.2% of all bus events are reads of $C000** (926k): the keyboard poll
  at $D56C - `LDA $C000 / BPL $D57C / INX / ...` back to $D56C.  Every
  poll costs TWO bus cycles, not one: after the read's data phase the
  core's next $C000 read has missed the current cycle's present point and
  waits for the next (898k of the 926k gaps between consecutive $C000
  reads are exactly 2 cycles, 28k are 1).  **1.82M of the 2.54M cycles -
  72% of the machine's time - is the poll loop**, at ~6x.
- The rest: AUXMOVE's setup - $C004/$C003/$C002 writes (RAMRD/RAMWRT),
  $C013/$C014 reads - 77k bus events, 7.7%, 12.9k AUXMOVE calls; the
  copy loop itself is now all fast words ($C393-$C3AD, step 1).  The map
  redraw loop at $D4FD-$D531 (206k iterations, ~40 ops each, all fast).
  $C083/$C08B 464, $C011/12/16 348, $C054/55 116: noise.
- No phases: every 100k-cycle window looks the same (~39k bus events,
  ~36k of them $C000).  The redraws appear as ~50 gaps of ~6.5k cycles
  between polls.

So at this screen the 20x is the idle poll's figure.  Serving the
keyboard read on the card (question 4 below: sample the keyboard in the
parked dummy instead of the $0000 read, cache the sample, answer program
$C000 reads from it - the user's design; the kbd_inject latch semantics
for injected keys unchanged) removes 72% of the cycles at once; the
AUXMOVE switch traffic (questions 1/3: RAMRD/RAMWRT writes internalized,
$C013/$C014 answered from the shadow) is the next 7.7% of bus ops.
Evidence trace: nox_map.swbt (session scratchpad, 105 MB, not kept).

## The third finding (2026-09-02, on hardware): the census at the Nox map

fw 463d85c / host 9210eee, `swctl accel status` twice 7 s apart, Nox idle
at the overworld map, 61.1x, 1.60 clocks per op:

| bucket | ops in 7 s | share of the dispatcher's ops | ~share of all clocks |
|---|---|---|---|
| keyboard ($C00x from the latch) | 46.2M | 92.2% | 53% |
| RAM data (the data front missed) | 3.1M | 6.2% | 3.6% |
| I-fetch (the front missed) | 0.6M | 1.2% | 0.7% |
| writes | 0.18M | 0.4% | 0.2% |
| LC / ROM $D000+ / ROM $Cxxx data | 0 | 0 | 0 |

So step 2 moved the poll off the bus and onto the DISPATCHER, and at
6.6M polls a second the dispatcher's ~8-clock round trip is now HALF of
all clocks by itself: the loop is ~12 ops, eleven at one clock and the
keyboard read at eight.  RAM misses, the presumed rung-4 target, are
3.6% of clocks here; ROM-class data reads are zero.  The next step is
therefore the keyboard read at ONE clock on the data front (a `$C00x`
term in rtl/dline.sv's serve, the byte kbd_inject's int_byte, the
bookkeeping pulse int_rd from the dline's retire, the governor charged
through d_commit), which on this arithmetic takes the map from 61x to
~90x.  Rung 4 proper (RAM coverage) is worth ~4% here and wants a
busier scene's census before it is designed.

Note on reading the status line: the seven census registers ride the
accelerating rotation and ACCEL_FAST the HUD's, so within one line
they are of different ages - the census's proportions are exact, its
sum against ACCEL_FAST is not (50.1M vs 36.5M over this interval).

## The fourth finding (2026-09-02, on hardware): the animated map

The user's steer: the keyboard poll is the definition of an idle task and
is already cheap; what matters is how the DATA side does.  A second Nox
map, half the screen tiles in a 4-frame animation - real data traffic.
Counters over 21 s (wrap-safe: turbo wraps every ~75 s at 60x), 55.7x,
1.76 clocks per op:

| | count | |
|---|---|---|
| data front hits (reads + writes, ACCEL_DLINE) | 229M | 19% of all ops |
| data read misses (all RAM class; LC/ROM/CX zero) | 43.0M | 14.6% of data accesses |
| data write misses (the dispatcher's writes) | 22.6M | 7.7% of data accesses |
| **data-access hit ratio** | | **77.7%** |
| clocks: data misses / bus / keyboard / I misses | | ~25% / ~18% / ~9% / ~3% |

The 5 s sparse trace of the same screen says what the two visible
kinds are:

- **The bus (447k events, 18% of clocks) is AUXMOVE's setup, 99% of
  it**: $C004 W 147k, $C002 W and $C003 W 73.7k each, $C013 R and
  $C014 R 73.7k each - 73.7k AUXMOVE calls in 5 s, six bus ops apiece
  at two cycles each.  The copy loop itself is fast (step 1); its
  RAMRD/RAMWRT dance is now the single largest bus item on a busy
  screen.  The acceleration branch's swint (15c8444 there) internalized
  exactly these - the $C00x switch writes and the $C01x status page from
  the shadow - so that port is the next bus step.
- **The write misses are the language card**: $D522/$D523/$D528/$D529 W
  1.18M each in 5 s = 4.7M, ~20M over 21 s = the 22.6M FAST_WR.  Nox
  keeps its variables in LC RAM; the data front's write retire is
  "virtual and below $C000" (rung 3), so every LC write rides the
  dispatcher while LC READS of the same bytes hit the CAM (LC data
  misses: zero).  A registered LC-class write qualifier in dline.sv
  would take those at one clock: ~9% of clocks here.
- **The read misses (43M, ~16% of clocks) are not visible in sparse**
  (fast reads are dropped).  By the program they are AUXMOVE's source
  bytes - `LDA ($3C),Y` walking main memory - and the tile data: the
  eight-line CAM against streaming reads.  That is rung 4's case (a
  stream/next-line prefetch on the data front), and now it has a number.

Ranked by clocks on this screen: read misses ~16%, AUXMOVE's switches
~18% (two-cycle bus ops), LC writes ~9%, keyboard ~9%, I misses ~3%.

## Open questions for the next steps

1. (Latch pages: DONE, step 1.)  Whether the dline's data-side $Cxxx
   exclusions (the last byte excludes $Cxxx whole; the CAM never holds ROM
   class) should follow the same logic for ROM-class data reads of
   $C1xx-$CFxx (the firmware reads its own tables) - with a trace first
   showing the data side is where cycles go.
2. $C800-$CFFF: already ROM class when the latch says internal; the front
   serves it.  Confirm on a trace that 80-column text output (COUT through
   $C3xx into $C8xx) is one-clock end to end after (1).
3. Soft-switch READS that have no side effect and whose value the card
   knows: $C013-$C01F (the MMU's own state), $C054/$C055-style reads that
   ARE side effects (PAGE2) must stay on the bus; the pure status reads
   could be answered from the shadow - the soft-switch-internalization
   work (memory: soft-switch-internalization, ACCEL_CTRL[28]/swint) did
   some of this and left open issues; reconcile with it rather than redo.
4. The keyboard ($C000/$C010): the kbd_inject latch model; a poll loop is
   the idle case and was measured at ~54x with swint - what is its status
   on the dcache lineage?
5. Slot ROMs of the card's OWN slots (the SmartPort HDC, the floppy, the
   VidHD signature ROM): the card holds those bytes; the rule says slots
   are hardware and ride the bus.  A decision for the user, not the plan.
6. Measurement: for every candidate, a trace with tools/swtrace_mix.py
   before and after, plus the governed-8x check (the HUD reading 8.00 is
   the arithmetic's proof).
