# Virtual time: the beam the accelerated core sees

Status: **DESIGN + CARD SIDE BUILT 2026-09-03** (branch `cxxx_work`); the
host side follows.  The step after docs/CXXX.md "The switch reads in the
closed regime", and the correction of that step's one wrong decision.

## The problem, stated by the demo

A cycle-counting demo (`megademo.dsk`) syncs to the beam once - `$C019`,
or a vapor lock on the floating bus - and then COUNTS ITS OWN CYCLES to
place every mode switch and every write at the right place in the frame.
Served the real beam's position (CXXX.md step 3), the demo is right at a
governed 1.00 and wrong at every other ratio: at 60x the real beam moves a
sixtieth of what the demo counted.  The value a read returns is not the
issue; the TIME BASE is.  For a cycle-counted program the whole visible
machine has to run in the program's time - the beam, VBL', the floating
bus, the video switches' effect - and be rendered in that time.

The host already renders that way: from a frame mark it walks a complete
frame cycle by cycle, from "here is an event" and "there were N cycles with
no event" (SKIP words), keeping the switch state and the memory it reads
the picture from.  What it walks today are the BUS's cycles: a fast op is
"an op and not a cycle".  Under acceleration the stream has to present the
CORE's cycles as the cycles.

## The design

**One counter, two sources.** `rtl/vbeam.sv` is the beam position every
consumer takes - fb_sim's prediction, the internalized reads' `$C019`, bit
19 of every stream word, the frame mark.  When the core is not accelerating
it is `vbl_lock`'s counter, passed through: the real beam, as before.  When
the accelerated regime is in force (`virt`: `accel_on`, the core not held)
it is seeded from the real counter at the transition and then STEPS ONCE
PER CORE CYCLE: a fast op's retire (`fev_valid || turbo_tick ||
dline_tick`, the tick the floppy and the Mockingboard already keep time by)
or a real bus op of the core's own (`bus_tick && !op_dummy && !op_ovr`).  A
dummy cycle - the bus idling while the core runs fast - is not a core cycle
and does not move it; neither does an override (the hold's, a DMA's).  The
frame is 262 or 312 lines as the lock found it; `locked` is the lock's.

**The stream in the core's time.**  While `virt`:

| | real base (as before) | virtual base |
|---|---|---|
| a bus op's event (0xF) | a cycle | a cycle |
| a dummy's event | a cycle (SKIP-counted, kept on edges) | NOT a cycle: dropped, counted by nothing |
| a fast word (0xC) | not a cycle; dropped in sparse if a read | a cycle: counted, edge rule applies, dropped reads counted into SKIPs |
| bit 19 (VBL level) | the real counter's | vbeam's |
| the frame mark | vbl_lock's, on a bus event | vbeam's origin, on whichever word is at it - a fast word carries a mark now (`event_merge` fast_mark) |
| `VBL_MARK` free[1] | 0 | 1: "the frames from here are virtual" |

So the host sees exactly the shape it always saw - marks, events, SKIPs -
with the count of cycles between marks being the core's 17,030 (or
20,280), not the bus's.

**Exact, in order: the door decides.**  The first cut counted dropped
cycles where they happened and let the fronts shed words when the merge
was crowded; on the machine that gave frames of 17,029 and 17,031 cycles
and one mark in six lost (a shed word's mark goes with it).  So the
decision moved to the MERGE'S DOOR (`rtl/event_merge.sv`): a fast op's
word is kept or dropped before the queue - kept if it is a write, a switch
read of `$C05x`/`$C08x`, a mark, or an edge of the blanking level; dropped
if it is a read nobody wants in sparse or a quiet switch read (`fev_quiet`
from the sequencer, the read that changes no switch) - and every queued
entry carries the COUNT OF DROPPED CYCLES SINCE THE ENTRY BEFORE IT, in
order; a count with no word to carry it goes out as a carrier entry.  The
filter (`rtl/bus_event_filter.sv`) folds those counts into its SKIPs.  And
nothing sheds: the fronts (`rtl/iline.sv`, `rtl/dline.sv`) retire only
into room on the merge and fall to the dispatcher otherwise, so a cycle
without a word cannot happen; a kept word that finds the queue full is a
fault counted in `overflows`, dropped, and still counted as a cycle.
`sim/run_bus_event_filter_tb.sh` cases 9b and 10 are the door and the
counts.

**The host** (`src/pipeline.cpp`): a fast word is a cycle to the beam
while the last mark said virtual.  Frames then arrive at the core's rate -
sixty a real frame at 60x - and the display can show one in N, so the
host DECIDES AT THE MARK whether the frame that starts there will be
shown (the display's own period has elapsed since the last one it drew).
A frame it will show is walked as every frame was: events and SKIPs
cycle by cycle, `beam_.cycle()`/`beam_.run()`, drawn, taken and decoded
when the beam enters blanking.  A frame it will not show is NOT WALKED
AT ALL: its events still go through the mirror and the display shadow -
that is what keeps memory and the switch state exact for the next frame
that is shown - and its cycles are only counted, so the position is known
and the next mark is recognised; the beam does not move, places nothing,
draws nothing.  The cost of a skipped frame is its events, not its
17,030 cycles.  The sound clocks: the Mockingboard's VIA timers already
tick on core ops on the card; the host's audio path in virtual time is a
separate matter (docs/MOCKINGBOARD.md) and not part of this step.

**What is unchanged.** The real beam and the lock: `vbl_lock` runs as it
did, its probe and verify frames are its own, and the moment acceleration
stops, `vbeam` passes the real counter through again and the next mark is
the real one (free[1] = 0).  The floating-bus monitor compares at the
bus's pace only, as before.  The internalized reads of CXXX.md step 3 are
the same reads; only their position source changed.

## What proves it

- `sim/run_bus_event_filter_tb.sh` case 10: the table above in the virtual
  base - fast reads and shed cycles counted into the SKIPs, dummies
  dropped uncounted, a switch read, a blanking edge and a mark kept on
  fast words - beside the real-base cases unchanged.
- `sim/run_fb_sim_vl.sh`, the accel battery and the boot bench: the real
  base unchanged (vbeam passes the lock through; the sequencer's tick
  beside its word).
- Not yet in simulation: vbeam stepping, and the host's virtual walk.
  The hardware run below is their proof for now; a vbeam bench (a frame
  of core cycles against a scanner stepped per cycle) is the next one to
  write.
- Hardware (2026-09-03, the Pt, bit of 22:07): the host's histogram of
  cycles between marks reads exactly 17,030 on every frame - 5,554 of
  5,554 at a governed 8x, 75,155 of 75,155 unlimited - with no mark lost
  and no frame cut short; `megademo.dsk` at 8x renders its cycle-counted
  scenes - the split-screen title with its scroller, the letter beside the
  picture - as the bus-pace run does.  Unlimited (~90x) the demo loads and
  then sits on its vapor-lock fill: the floppy reported 27 LATE TRACK
  FILLS against 0 at 8x - at that speed the RWTS's 37 ms wait is 0.4 ms of
  real time, under the host's fill - so the load is suspect, not the beam.
  The next step is the floppy's: stall the accelerated core while a fill
  is pending (docs/FLOPPY.md).
