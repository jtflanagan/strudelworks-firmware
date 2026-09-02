# $Cxxx under acceleration: what to serve fast - the record before the plan

Status: **NOT PLANNED YET** (2026-09-02).  This file is the evidence and the
open questions, written so the plan can be made in a fresh context.  The
user's decision: treat "what in $C000-$CFFF can be served fast" as ONE plan
rather than piecemeal exceptions, and take it up BEFORE dline rung 4
(docs/DLINE.md; streams are deferred, not dropped).

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

## The one refinement already identified (NOT built)

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

## Open questions for the plan

1. The latch pages, as above - and whether the dline's data-side $Cxxx
   exclusions (the last byte; the CAM never holds ROM class) should follow
   the same logic for ROM-class data reads of $C1xx-$CFxx (the firmware
   reads its own tables).
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
