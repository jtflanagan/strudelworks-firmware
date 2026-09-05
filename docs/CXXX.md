# $Cxxx under acceleration: what to serve fast

**STEP 6 PROVEN ON HARDWARE (2026-09-04 night, branch `cxxx_work`, the Pt, SRAM):** the
speaker, `$C030-$C03F`, served on the card in the closed regime - "The
speaker", below.

**STEP 5 PROVEN ON HARDWARE (2026-09-04 evening, branch `cxxx_work`, the Pt, SRAM):** the
card's OWN slots - the hard disk, the floppy, the Mockingboard - served on
the card in the closed regime: "The on-card slots", below.  The user's
rule changes with it: a slot that is THIS card's is no longer "hardware
that rides the bus"; a slot in a socket still is, and so is the VidHD's
signature ROM (not asked for).

**STEP 4 PROVEN ON HARDWARE (2026-09-04, branch `cxxx_work`, the Pt, SRAM):**
the switch WRITES in the closed regime - "The switch writes", below.  The
banked list's item 1 is now complete on both sides; INTCXROM and SLOTC3ROM
stay on the bus by design, and that section says why that is the right
answer to "how do slot accesses still reach the slots".

**STEP 3 BUILT AND SIMULATED (2026-09-03, branch `cxxx_work`, the Pt):**
the switch READS in the closed regime - "The switch reads in the closed
regime", below.  The banked list's item 1, read side only, taken up
because the demos the user wants to run sync to the beam through exactly
these reads, and the larger FPGA lifted the ban.

Status: **STEP 1 PROVEN ON HARDWARE** (2026-09-02, fw 2db1baf, bit in
SRAM) - page $C3 on the instruction front once the INTC8ROM latch is set.
**STEPS BANKED 2026-09-02** (below, "The next steps, BANKED"): nothing
further on this card until the larger FPGA arrives.
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
  the bus - and nothing else is slow.  The plan must keep that.  (Revised
  2026-09-04, step 5: the card's OWN slots are served on the card in the
  closed regime; a slot in a socket still rides the bus.)

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

## The switch reads in the closed regime (step 3, 2026-09-03)

**What a demo watches.** A demo finds the beam one of two ways: it polls
`$C019` for the IIe's VBL', or it vapor-locks on the floating bus through
a video toggle (`$C054`, `$C050`...).  Under acceleration both were bus
ops - right, but a bus cycle each, so a poll loop ran at the bus's pace -
and the floating one was answered from the real bus, which in mode 2
carries the machine's STALE RAM (fb_sim's serve substitutes the copy's
byte there, and that part was already right).  This step serves both on
the card, at the core's pace, with the values the real machine would give
at that real moment.

**The position was real time - and that was the one wrong decision of
this step.** Served the real beam, a cycle-counting demo is right at a
governed 1.00 and wrong at every other ratio: it counts its own cycles
between reads, and the real beam moves a sixtieth of that at 60x.  The
position is now `rtl/vbeam.sv`'s - the real counter passed through while
the core keeps the bus's time, a counter stepped once per core cycle
while it does not - and the stream and the host render in that time base:
docs/VIRTUAL_TIME.md.  The reads served are the same; only where the
position comes from changed.

**The reads served, and by whom** (`rtl/apple_mmu.sv` q_swi, decided on
the live address beside q_cls; `rtl/master_top.sv` picks the byte on the
registered op):

| read | byte | gate |
|---|---|---|
| `$C000-$C00F` | the parked-dummy latch (step 2, unchanged) | latch holds a byte |
| `$C011-$C01F` except `$C019` | bit 7 from the shadow, over the latch's low bits (as the IOU serves them, AppleWin's `IORead_C01x`) | always |
| `$C019` | bit 7 = the IIe's VBL' from the counter, ONE CYCLE AHEAD (VBL.md "What the machine said"): the level of the cycle after the one in flight | the VBL lock |
| `$C050-$C057` | fb_sim's byte for the cycle in flight; the toggle lands in the shadow at the synthetic commit exactly as at a bus commit | fb_sim.int_ok: serving, locked, not 80 columns |
| `$C080-$C08F` | the same floating byte; the language card's state machine steps at the synthetic commit | the same |

Stays on the bus: `$C010` (the real strobe), `$C058-$C05F` (annunciators
and DHIRES - the shadow does not carry them; DHIRES is the host's), the
speaker and the rest of `$C02x-$C07x`, every slot, and **every write** -
the write side of the banked item is still banked (AUXMOVE's RAMRD/RAMWRT
dance keeps its four bus ops).  The regime is step 2's: mode 2, serving,
`ACCEL_CTRL[28]` clear, the core not held; the one lever covers both.

**The stream.** An internalized read retires with the synthetic commit
(step 2's mechanism, one clock, `u_commit` high with the op still on
`u_addr`), so the shadow, `map_changed`, the fronts' kills and the
keyboard's bookkeeping all fire as for a bus op.  Its fast-op word is
what tells the HOST: `pipeline.cpp` applies every word, fast or not, to
the mirror and the display shadow before it decides the word is not a
cycle - so a `$C055` served on the card flips the host's PAGE2 through
its word.  Two rules keep that from flooding the link:

- `rtl/bus_event_filter.sv` keeps a fast READ on a sparse stream only if
  it is of `$C05x` or `$C08x` (the ones carrying state); `$C00x`/`$C01x`
  polls stay off it as every fast read did.
- `rtl/accel_seq.sv` puts NO word on the stream for a QUIET `$C050-$C057`
  read - one whose switch already holds the value the address sets
  (`apple_mmu.q_swi_quiet`).  A vapor-lock loop polling `$C054` at ten
  million reads a second is all quiet reads; the one that flips a page is
  not.  The language card's reads are never quiet (the prewrite state
  moves on each); the host's LC follows them.  In FULL capture the same
  rule holds - a quiet read is a no-op for every consumer of the stream,
  the trace included - so the census counts it and the stream does not.

**Proof.** At the bus's pace the monitor (`rtl/fb_sim.sv`) now compares
`$C019` reads too - bit 7 against the bus, counted with the ordinary
mismatches, `FB_LAST2`'s op address `$19` telling them apart - so
`tools/fb_test.sh`-style runs and the VBL probe prove the served value
before acceleration uses it.  `sim/fb_sim_tb.sv` case 6g probes a frame
of `$C019` against a model that carries the lead: 0 mismatches.
`sim/accel.s` phase 5c reads the status page back after every switch,
flips PAGE2/MIXED/TEXT by reads (one of them quiet), and walks the LC
pair; the bench's machine model moves its switches at the synthetic
commit as the pins would, and the same program passes in every mode.
Hardware: the demo the user named first is `megademo.dsk`.

## The switch writes (step 4, 2026-09-04)

**What was left.** After step 3 every switch READ the card could answer
was answered on the card, and every WRITE still rode the bus - AUXMOVE's
RAMRD/RAMWRT dance around every tile on the Nox map was four bus ops
(18% of the clocks there, the census said), and the LC pair, 80STORE and
the video toggles by STA were the rest of the bus traffic on that screen.
This step serves those writes on the card, on the same path the reads
took: `apple_mmu.q_swi` now answers for a write too, the op rides S_FAST
(the page cache decides a BUS-class write with nothing written - a write
outside the image lands nowhere, `cl_wr_image` clear), and it retires
with the synthetic commit, so the shadow moves, `map_changed` fires, the
fronts' kills fire, and the fast word carries the write to the host
exactly as a bus commit would have.  A write wants no byte, so it needs
no fb_sim.  The census counts it in WR beside every other write; KBD is
now the internalized READS alone.

**The writes served** (`rtl/apple_mmu.sv` qi_wr), and the quiet rule:

| write | effect | quiet when |
|---|---|---|
| `$C000/1` 80STORE, `$C002/3` RAMRD, `$C004/5` RAMWRT, `$C008/9` ALTZP, `$C00C/D` 80COL, `$C00E/F` ALTCHAR | the shadow's switch, at the synthetic commit | the switch already holds the value |
| `$C050-$C057` | TEXT/MIXED/PAGE2/HIRES, likewise | the same |
| `$C080-$C08F` | the language card's state machine, WRITE semantics (A0 = 1 clears prewrite, leaves the enable alone) | never |

A quiet write, like a quiet read, puts no word on the stream: the host's
mirror and display shadow would apply it as a no-op.  The regime is the
same lever as steps 2 and 3 - mode 2, serving, `ACCEL_CTRL[28]` clear,
the core not held, past the reset sequence; the host's `swint` key and
`accel swint on|off` - and outside it every one of these writes is a bus
op as before.  In mode 1 RAM writes land on the motherboard, so the
motherboard's switches must follow the program's: everything rides the
bus there, by the rule.

**What stays on the bus, and why that is the answer to the slot
question.** The user's concern going in: if the card stops telling the
motherboard about switch writes, will a slot access the card DOES put on
the bus still reach the slot?  The IIe routes I/O SELECT' ($Cn00-$CnFF)
and I/O STROBE' ($C800-$CFFF) to the slots on exactly three things:
INTCXROM, SLOTC3ROM, and the INTC8ROM latch those two feed.  Nothing
else - not 80STORE, RAMRD, RAMWRT, ALTZP, the IOU's pair, the toggles or
the language card - touches slot routing, and DEVICE SELECT' ($C0n0-
$C0nF) is never gated at all.  So:

- **`$C006/7` INTCXROM and `$C00A/B` SLOTC3ROM stay bus ops in every
  mode.**  The card's classifier (`classify`, "THE CX CLASS") only makes
  a $Cnxx access a BUS op when its shadow says the slot owns the page,
  and its shadow and the motherboard's MMU have then seen the same
  writes to the same two switches - so the motherboard routes the cycle
  the same way the card decided it.  The four on-card peripherals track
  the same two writes from the driven stream (`rtl/slot_switches.sv`),
  a second reason they must be there.
- **INTC8ROM may diverge, in the harmless direction only.**  A $C3xx read
  with SLOTC3ROM clear is ROM class, served on the card with no bus
  cycle, so the card's latch sets and the motherboard's does not.  The
  card then serves $C800-$CFFF itself and never externalizes it, so the
  motherboard being MORE open to the slots than the card believes causes
  no wrong cycle.  The dangerous direction - the motherboard more closed
  than the card - would need it to have seen an INTCXROM/SLOTC3ROM write
  the card did not, and there are none.
- **A reset does not give an "all slots" state, and does not need to.**
  The motherboard's inferred reset (ACCELERATION.md, "The reset sequence
  rides the bus") leaves INTCXROM clear and SLOTC3ROM clear: slots 1, 2,
  4-7 and $C800 routed to the slots, $C3xx to the internal ROM.  The
  monitor ROM never writes SLOTC3ROM (the only `STA $C00A/B` in the
  16 KB are the 80-column firmware's PR#3 disconnect at $C2E2/$C2EA), so
  the machine stays there until a program asks otherwise - and when one
  does, the write rides the bus.  The alternative considered and
  rejected: forcing the motherboard to INTCXROM off / SLOTC3ROM on as a
  fixed backplane and internalizing those two writes as well.  It would
  buy a handful of cycles (the ROM toggles INTCXROM around its $C8xx
  calls and at reset) and cost a synthetic `$C00B` write after every
  reset sequence plus a permanent motherboard/shadow divergence to
  re-sync on any move to mode 0.
- Also on the bus, as before: `$C010` and every `$C01x` write (the
  strobe), `$C058-$C05F`, the rest of `$C02x-$C07x`, `$CFFF`, every
  slot.

**The host** needed nothing: `pipeline.cpp` applies every word, fast or
not, to the mirror and the display shadow before deciding whether it is
a cycle, and the sparse filter keeps every fast write.  A `STA $C003`
served on the card flips the host's RAMRD through its fast word, as the
`$C055` read did in step 3.

**Proof.** `sim/accel.s` phase 5d writes every served switch and reads
it back through the status page (RAMRD excepted - the program runs from
RAM at $6000, and the aux tests in ROM flip RAMRD already, now on this
path), makes two quiet writes, drives the LC by writes, and writes both
Cx-ROM switches; `sim/accel_tb.sv`'s machine model moves its switches at
a synthetic-commit write with the pins' semantics, and mode 2 asserts:
switch writes served (309, 27 quiet), NO memory-switch write on the pins
in the closed regime, INTCXROM/SLOTC3ROM writes ON the pins (33), none
of those served on the card.  Verilator, both sweeps: 81 checks, 0
errors, 71.4x unlimited, governors 4.00 and 1.00 exact.  `sim/boot_tb.sv`'s
machine model got the same synthetic-commit write (it had the read half
only, and the first run showed exactly the divergence that predicts: the
reference's LC and aux state falling behind the card's after ProDOS's
first internalized `STA`); with it the ProDOS boot bench, 2M bus cycles
mode 2 unlimited, is bit-for-bit step 2's - 137.2M ops, 68.6x at Bitsy
Bye, 12.6k bus ops, 0 bad reads, image equal to the reference in every
bank - which is expected: ProDOS idling in Bitsy Bye writes no switches,
so that bench is a correctness proof here and not a speed one.  Build:
WNS +0.008, bitstream 2026-09-04 17:24.

**The hazard the hardware found, and the settle (2026-09-04, same day).**
The first bit locked Nox Archaist up in its DHGR splash - with `accel
swint off` (the config's `swint = off`; the socket command was found
broken on the host and fixed, `pipeline.cpp drive_accel_ctrl` dropped the
disable bits) it booted, so the fault was in the internalized switch ops.
The stuck loop was the splash's speaker sample player at $1116-$115B,
sitting in BOTH banks with RAMRD on, the machine looping in it forever
because a byte it depended on was wrong.  The cause, found by instrumenting
`sim/accel_tb.sv`: a bus op's commit lands mid-cycle and the driver holds
the core for the rest of it, so the shadow, `map_changed`, the CAM
flash-clears and everything derived from them have settled before the
core's next op; a SYNTHETIC commit comes one clock AFTER the core moved
(fast_hit is the cyc_en; swi_commit follows a clock later), the shadow
flips the clock after that and `map_changed` the clock after THAT - and
`turbo_ok` was free again two clocks after fast_hit.  The instruction
front served the opcode right after `STA $C003` from a CAM line resident
under the OLD map, one clock before map_changed killed it: one byte from
the wrong bank.  Step 3's reads had the same window (an LC or PAGE2 read
followed by an opcode from the switched region) and nothing ran into it
before Nox.  The fix, `rtl/accel_seq.sv` swi_settling: a switch-CHANGING
synthetic commit (not a quiet one) holds `turbo_ok` and the dispatcher's
`settled` for four clocks - the commit's, the shadow's, map_changed's and
one for anything derived from map_changed - so the next op sees the new
map everywhere, exactly as after a bus op.  Cost: four clocks per switch
flip, against the ~98 the bus cycle cost.  The reproducer is `sim/accel.s`
bankfetch (phase 4b): four stubs at $1F00-$1F3F identical in both banks
except for the byte under test, flipping RAMRD/RAMWRT and continuing; the
first cut had `LDA #imm` differing in the OPERAND and passed on the broken
RTL, because the one byte served early is the OPCODE - it now differs in
the opcode (INX/DEX) and fails on the broken RTL (mode 2: 1 turbo read
disagreed, the program's flag raised) and passes with the settle.  The
first cut of the settle held on EVERY non-quiet internalized op and cost
the ProDOS boot bench 12% (68.6x -> 60.1x: Bitsy Bye's `$C000` poll paid
four clocks a read); narrowed to the ops that can move a switch ($C00x
writes, $C05x/$C08x either way) it is back to 137.2M ops, 68.6x, 420 ops
short of before.  Battery with the settle: accel_tb 81 checks 0 errors
both sweeps (bankfetch included), mode 2 71.1x; boot bench 0 bad; build
WNS +0.021 after the post-route phys_opt (the pre-opt figure read -0.010).
**ON HARDWARE (2026-09-04 18:50, SRAM, host with the swint fix):** Nox
Archaist boots through the DHGR splash into the HiRes title with swint
ON, mode 2 governed 16 - the WR bucket climbing (its switch writes served)
and the KBD bucket too; the runtime `accel swint off` now reads back
"swint OFF".

**On hardware (2026-09-04, SRAM, host 3978b05 unchanged).**  megademo.dsk
at the governed 8.00 in mode 2: runs as before; a 5 s sparse trace
(36.7 s of machine time) carries only the Mockingboard's VIA writes in
slot 4 and 43 speaker reads - its toggles are reads, served since step 3.
wave.dsk's STARTUP (the AUXMOVE workload), mode 2 unlimited: an 8 s sparse
trace covering 321 s of machine time has **zero bus events**, and the
fast-op mix shows `$C002 W` and `$C003 W` at 1026 each - RAMRD's dance
served on the card; `accel status` twice around the trace: 892M ops over
9.19M cycles, ~97x, the bus-op counter frozen at 1,692,197 across the
whole run (the earlier 60-90x readings of this section included Bitsy Bye
and the boot).  The first swhost restart on the test config hit the
FT601 "device gone" startup race (stop and start back to back); a 5 s gap
between them cleared it.  Test config: `swwr_test.conf` on the Pi (floppy
1 = wave.dsk, hd off, accel all unlimited), written by `tools/pi.sh conf`.

## The on-card slots (step 5, 2026-09-04)

**The rule, revised by the user.**  Until now every slot access rode the
bus, the card's own peripherals included: the SmartPort HDC's `$C0F0`
port and `$C7xx` ROM, the Disk II's sixteen switches at `$C0Ex` and its
P5A ROM at `$C6xx`, the Mockingboard's VIAs at `$C4xx`.  A real card in a
socket must still get its cycle, and nothing about that changes.  But an
access one of THIS card's peripherals answers has no reason to cross the
connector: the peripheral is a clock region away from the core, and the
bus cycle was only the seam it happened to hang on.  So in the closed
regime (the same lever as steps 2-4) those accesses are fast ops served
on the card, and a slot in a socket is what "slow" means from now on.
The VidHD's slot is NOT included - its ROM is read once at boot and the
user did not ask for it.

**The decision.**  `rtl/apple_mmu.sv` q_slot: an access is an on-card
slot's when its address is a peripheral's DEVICE SELECT range
`$C0n0-$C0nF` (never gated by a switch) or its I/O SELECT page
`$Cn00-$CnFF` while the slot owns it (INTCXROM clear, and for slot 3
SLOTC3ROM set - exactly the classifier's and `rtl/slot_switches.sv`'s
rule, so every access this claims is one the classifier called BUS).
The three slot numbers come from the same registers the peripherals are
enabled by; 0 means none.  Reads and writes alike - a write to a slot's
ROM page lands nowhere on a real card either.  q_swi includes q_slot; the
op rides S_FAST like every internalized op and retires with the synthetic
commit; no settle (a slot op moves no switch); never quiet.

**The peripherals see the op through a view** (`rtl/master_top.sv`,
"THE PERIPHERALS' VIEW OF THE OP STREAM").  The hard disk, the floppy and
the Mockingboard decode the driver's op as they always did, and an
internalized access is one the driver never sees.  So for its window -
from the dispatch (accel_seq sl_win: S_FAST with a slot op, through its
synthetic commit) - the three are shown the unified op instead: present
on the dispatch clock, the core's address, direction and data, the
synthetic commit as their commit.  Three rules make the window safe:

- The driver's dummies are hidden for the window: a dummy is nobody's op,
  and the peripherals only use a present to decode and claim.
- The window's commit is flagged a dummy, so the floppy's and the VIAs'
  core clocks (`tick`, `via_slow_clock`: a committed non-dummy op, or a
  fast op) do not tick on it - fast_tick ticks them once for the op, as
  for every fast op.  The hard disk keeps no such clock.
- The claim is masked from the driver.  A peripheral's registered
  rd_claim answers the fast op (master_top's swi_byte keys on the slot
  FIRST - a slot ROM page's low nibble would otherwise read as the
  keyboard's), and `rtl/apple_bus_write.sv` DRIVES a claimed read's byte
  onto the bus in its data window.  A claim left over from a fast op
  under a dummy's read of `$C000` would fight the IOU for the data bus.
  sl_claim_fast masks it from the dispatch until the driver's next
  visible present re-registers the claim for its own op.  fb_sim takes
  the masked claim too (a claimed read is no floating candidate).

The peripherals' answer is registered at their present, one clock after
the dispatch; the fast op's decision (the page cache's `decided`, P3) is
two clocks later still, so the byte is there by construction, as the
keyboard's and the status page's were.

**The stream and the host.**  Every internalized slot access is a fast
word.  Writes are kept as every fast write is; fast READS are dropped on
a sparse capture by the door's rule (rtl/event_merge.sv) - which is what
the busy polls need: the SmartPort ROM's `lda IO_Execute,x / bmi` loop,
a bus cycle a poll until now, runs at three clocks a poll on the card
while the host's disk thread answers over USB, millions of them, and the
host must not see them.  But the host's disk controller (src/hd_card.cpp)
follows the port from the stream: the EXECUTE is an armed read of
`$C0n0`, and the first non-busy read completes the command on its side.
So the door has `fast_force`: master_top raises it for a fast read of the
hard disk's port that was an EXECUTE (hd_card's exec_q, registered at the
op's present and held to the next) or that did not answer `$80`.  The
polls, all `$80`, are dropped; the two reads the host needs go through.
The floppy's and the Mockingboard's reads nobody on the host consumes.
On the host, `pipeline.cpp` no longer skips fast words for the disk
controller (it decodes by address), and the sound gets `apply_fast`:
a Mockingboard register write applied with NO time - the chips' cycles
stay the bus words', as the shelved pacing decision left them (memory:
audio-pacing-shelved).  The speaker (`$C030`) is not a slot and rides the
bus as before.

**Census.**  An on-card slot's read counts in CX (the dispatcher's $Cxxx
reads: the internal ROM's data and now the slots'); its write in WR.

**Not changed.**  The hard disk's DMA still lands by the override path
with the core held (a hold is a hold in every mode); the floppy's stall
on a pending track fill still holds the core's next op; the Mockingboard's
interrupts still take the short route to the core.  INTCXROM/SLOTC3ROM
stay bus ops (step 4's argument holds: they route a socket's slot, and the
on-card peripherals track them from the driven stream).

**Proof.**  The ProDOS boot bench is the hard disk's: hd_card sits in
slot 7 of `sim/boot_tb.sv` with the bench playing host off the same view
the peripheral sees (the bench's mirror taps p_* now, as the real host
taps bus and fast words alike), so a boot in mode 2 runs every HDC access
- ROM fetches, register writes, EXECUTE, polls, completion - on the card,
and the DMA'd blocks must still equal the reference.  The accel bench has
no peripherals (ties: no slot); it is the regression.  The floppy and the
Mockingboard are proven on hardware: megademo.dsk (the floppy boot, the
Mockingboard music), wave.dsk, Nox.

**Two things the boot bench taught before it passed.**  First, its
machine model's synthetic-commit block decoded the low address byte alone
(it assumed `$C0xx`), and a fast fetch from the SmartPort ROM at `$C78x`
now retires with a synthetic commit too - the model took it for an LC
switch at `$C08x`, its language card diverged from the card's, and it
dropped ProDOS's writes into the LC (444 image bytes wrong, the first
`dline read $DC04: core got FC, the reference says 00`).  Both benches'
models are guarded with the full address now.  Second - reasoned out
while hunting the first, and real whether or not the bench happened to
hit it: the hard disk's DMA could START inside a slot op's window.  The
ROM polls the port in a tight loop of slot ops while the host answers
over USB, so when the block arrives the odds of the DMA's first override
present falling inside a window were a few percent per block - and the
view hides the driver's presents for the window, while hd_card steps its
DMA on them.  So the driver's override enable is gated for the window
(`drv_ovr_en = ovr_en && !sl_win`; the dispatcher keeps the ungated level
and holds as soon as it sees it) and the dispatcher refuses a fast
dispatch on a clock the override is live (`fast_ok && !ovr_en`), so no
non-dummy driver op can ever fall inside a window.  The DMA starts a few
clocks later than it would have.

**Results.**  ProDOS boot bench, 2M bus cycles mode 2 unlimited: 0 bad
reads, image equal to the reference in every bank, 137.9M ops = 69.0x
(step 4: 137.2M, 68.6x), and the bus ops over the whole run 12,605 ->
1,619 - the HDC's ROM, registers, EXECUTEs, polls and completions all
served on the card; what is left is the reset sequence, INTCXROM/SLOTC3ROM
writes, `$C010` and the speaker.  Build: WNS +0.052 after the post-route
phys_opt.

**On hardware (2026-09-04 19:45, SRAM).**  Total Replay from the on-card
hard disk (the test config's boot disk): boots and runs; `accel status`
CX 131M after a minute (the HDC's accesses, served), bus ops 34k over 48M
cycles; a 3 s sparse trace (173 s of machine time): the HD's register
accesses (`$C0F9` R/W), its EXECUTE and completion reads (`$C0F0` R, the
polls dropped) and the SmartPort ROM fetches (`$C78x`) all fast ops; on
the bus only the empty sockets' slot scan (`$C100/$C200/$C500` R) and
Total Replay's periodic block DMAs into the language card (override
cycles are bus cycles by design).  megademo.dsk from the on-card floppy
with the Mockingboard: boots (209 seeks, 1 fill, 0 late) and runs at the
governed 16; a 5 s trace (78 s of machine time) has 112 speaker reads on
the bus and nothing else, the VIA writes fast ops.

**The bug that trace showed.**  `$C480`, `$C481` and `$C401` writes were
there and `$C400` was not: apple_mmu's quiet rule decoded the LOW address
byte alone (it assumed `$C0xx`), so a Mockingboard write to `$C400` with
80STORE clear looked like a quiet 80STORE write and its word was dropped
at the door - the card's VIA took the write, the host's sound never saw
VIA0's ORB.  q_swi_quiet now requires the I/O page.  (The floppy's
`$C0Ex` and the hard disk's `$C0Fx` were never at risk: their high
nibbles match no switch decode.)  Rebuilt (WNS +0.034; accel_tb 81/0 both
sweeps with the quiet counts unchanged, boot bench 0 bad) and retested
2026-09-04 20:00: megademo's trace now carries `$C400 W` 210,936 beside
`$C480 W` 210,936, `$C401`/`$C481` 105,468 each, and 99 speaker reads on
the bus in 78 s of machine time.  **STEP 5 PROVEN ON HARDWARE.**

**An observation, not a fault.**  `mmismatch` read 8.6M after the
megademo boot and 4 after Total Replay's, static once running, last
record `$01FE: image 00, machine 80`.  That is the boot-menu hold: the
held core's stack read is re-presented every bus cycle against the
motherboard's RAM, stale in mode 2 by design, for as long as the menu is
up - one count a cycle when the stale byte happens to differ.

## The speaker (step 6, 2026-09-04)

Every access to `$C030-$C03F`, read or write, toggles the IOU's speaker
flip-flop, and a program that makes sound makes them in a tight loop:
Nox Archaist's splash player put 1.5M `STA $C030` on the bus in 35 s of
machine time, 99% of its bus ops and ~40% of its cycles, and the
megademo's residue on the bus after step 5 was speaker reads and nothing
else.  In the closed regime they are fast ops now (`rtl/apple_mmu.sv`
qi_c03x): a write served regardless, a read served when fb_sim can give
the floating byte (as `$C05x`), never quiet - each access is a toggle -
and no settle (nothing of the map moves).  The motherboard's own speaker
falls silent for them; the sound is the host's, as it is for everything
else in mode 2.

**The stream and the host.**  A speaker READ is a click, so the door
keeps fast `$C03x` reads on a sparse stream beside `$C05x` and `$C08x`
(`rtl/event_merge.sv` fast_sw); writes were kept already.
`AppleAudio::apply_fast` toggles the flip-flop and re-arms the gate with
NO time: the sample window advances on bus words alone, as before, so
toggles closer together than a bus cycle collapse into the level the
next cycle samples.  At acceleration that is what a click loop sounded
like on the bus too (a toggle a cycle at the bus's pace, the tone 60x
too high); the pacing that would make it right is the shelved decision
(memory: audio-pacing-shelved) and is not re-raised here.

**Proof.**  `sim/accel.s` phase 5e makes five speaker accesses of every
kind; `sim/accel_tb.sv` asserts in mode 2 that they were served and that
none reached the pins.  The bench's byte for a served read is the
model's floating constant, so the compare holds.  accel_tb 83 checks 0
errors both sweeps (15 speaker accesses served, none on the pins); boot
bench 0 bad, 69.0x, bus ops 1,619 -> 1,425 (ProDOS's beep); build WNS
+0.020.  **ON HARDWARE (2026-09-04 20:20):** megademo from the on-card
floppy, a 5 s trace covering 365 s of machine time: **zero bus events**;
`$C030 R` 474 and the VIA writes as fast ops; 6,326 bus ops in total since
the boot (the reset sequence, the Cx-ROM switches, `$C010`).  The bus now
carries nothing of a running program's in the closed regime unless it
touches a socket's slot, INTCXROM/SLOTC3ROM, the strobe, or an
annunciator.  **STEP 6 PROVEN ON HARDWARE.**

## The next steps, BANKED (the user's decision, 2026-09-02)

Written up so they can be picked up cold; not to be built now.  The
reasons: the animated map is a realistic workload but a slightly
idiosyncratic one (AUXMOVE around every tile, variables in the LC), and
the efforts should not overfit to it; and the current card is under
very tight resource constraints - LUTs at ~96%, BRAM 49/50, placement
so tight that a zero-margin cone flips on any nearby netlist change
(three failed builds for the census) - and unnecessary fights are not
worth having until the new, larger FPGA card arrives and there are
large reserves of LUTs, BRAM and placement space again.

In the order the counters rank them on the animated map:

1. **The closed-regime switch port** (~18% of clocks there).  **DONE:
   reads in step 3, writes in step 4 (above).**  The
   acceleration branch's 15c8444, minus what step 2 already carried.
   Gated exactly as the keyboard is - mode 2, serving, ACCEL_CTRL[28]
   clear, not held - which is the user's rule: internalizing a mapping
   switch is legitimate only when RAM is entirely internal; in mode 1
   writes land on the bus and the motherboard's switches must stay in
   step with them, so everything rides the bus there.
   - WRITES $C000-$C005, $C008/9, $C00C-$C00F (80STORE, RAMRD, RAMWRT,
     ALTZP, 80COL, ALTCHAR) as fast ops with the synthetic commit, so
     the shadow, map_changed and the fronts' kills fire as for a bus op.
   - READS $C011-$C01F: bit 7 from the shadow over the keyboard latch's
     low bits (kbd_inject.int_low, already a port); $C019 only with the
     VBL lock, else the bus.
   - STAYS ON THE BUS: INTCXROM/SLOTC3ROM writes (four slot cards track
     them from the driver's stream, rtl/slot_switches.sv); $C010 and the
     $C01x writes (the strobe); the video toggles $C05x and the LC $C08x
     for this slice (they want fb_sim's floating byte; small here).
   - Mechanics: the keyboard-only q_swi decode moves from accel_seq into
     apple_mmu beside q_cls (the shadow bits are there; decode from a
     REGISTERED address copy, the acceleration branch's f841b5c lesson:
     the live decode was its worst path); swi_byte gains the status
     page; the acceleration branch's 2d switch-storm phase (accel.s +
     accel_tb's c0_exp/c0_pin_stat and the synthetic-commit model
     update) comes across.  Cost: a few dozen LUTs, no BRAM.
2. **LC-class writes on the data front** (~9%).  rtl/dline.sv's write
   retire is virtual-and-below-$C000 by design (no classify cone on the
   retire); an LC write needs lc_wren, lc_bank2 and altzp - registered
   levels - folded into the $D000 hole the way p_off/d_off already fold
   reads.  Same splice/post path as rung 3.  Verify with the P+2 law's
   tests and a boot bench (ProDOS keeps its own state in the LC).
3. **Rung 4, the data streams** (~16%: the read misses).  AUXMOVE's
   `LDA ($3C),Y` source walk and the tile reads against an eight-line
   CAM.  The shape to decide with a busier scene's census, not this
   one: next-line prefetch on a sequential miss pattern vs a wider CAM.
   BRAM-hungry; the one that most wants the new card.
4. **The keyboard read at one clock** (~9% idle, ~9% animated).  The
   user's call: an idle task, already cheap; not worth a fight now.
5. **Census refinement**: split FAST_WR by class (RAM vs LC vs other)
   using the spare bucket code 3'd7, so item 2's figure is exact
   without a trace.  Trivial, but it is a build.

Measurement discipline for whichever comes first: `swctl accel status`
twice N seconds apart, deltas mod 2^32 (the turbo counter wraps every
~75 s at 60x), clocks = 98 x cycles; a sparse trace for the bus side.

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
