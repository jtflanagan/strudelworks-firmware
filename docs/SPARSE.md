# Sparse capture: the cycles the host needs, and a count of the rest

Status: **built and simulated; not yet on hardware.**

The card has always sent the host one event per phi0 cycle - four bytes a
cycle, four megabytes a second. Most of those cycles are reads: every opcode
fetch is one, every operand, every table lookup. And the host does nothing
with a read of RAM or ROM. Its mirror of the machine's memory follows the
writes (MEMORY.md); its picture follows the writes and the soft switches
(VBL.md); its sound follows the I/O page. Everything that acts on a *read*
acts on one in `$C000-$CFFF`: the video switches at `$C05x`, the keyboard at
`$C000`, the speaker at `$C030`, the slot I/O, the language card's
double-read prewrite at `$C08x`, the disk's EXECUTE. So a second mode, for
links that cannot carry four megabytes a second (a wired gigabit link can; a
wireless one is five to ten times short of it):

**Sparse.** BUS_ENABLE `free[2]`, latched at enable beside the source select,
zero meaning the mode that shipped. The card sends

- every access, read or write, to `$C000-$CFFF`;
- every write, wherever it lands;
- the two cycles of each frame where the scanner's blanking level changes
  (bit 19 of the event word, VBL.md "The bit"): line 192, cycle 0 and line
  0, cycle 0. The host places its beam by those edges, so they go whether
  they are reads or not;
- every cycle where RES′ changes, either way. The host's consumers treat
  reset as a level carried on events, and its sound clocks stop during one;
- the first cycle after the capture is enabled, so the host has a baseline
  for both levels.

And nothing else. On a running program the kept events are a fifth or less
of the cycles; in a busy loop that only reads, almost none.

## The count

The host is cycle-exact now. It draws the picture cycle by cycle from where
the beam is, runs its sample clock on cycles, and counts every event as
one. Dropping events would leave it with a beam and a clock that no longer
know where they are. So the cycles not sent are **counted**, and the count
travels in the stream as a word of its own:

```
SKIP   {4'hD, count[27:0]}     count >= 1: this many cycles passed unsent
```

The event word's tag is `0xF`, so the host tells the two apart by the nibble
it already checks for framing. A SKIP means the cycles *before* the next
word: `rtl/bus_event_filter.sv` emits it on the clock a kept event arrives,
then the event itself on the clock after, from a one-deep hold. A count that
reaches `CAP` (1024, a millisecond) goes out on its own, event or not: a
program in a loop that neither writes nor touches I/O still moves the host's
clocks a millisecond at a time, the capture's flush timer still sees traffic,
and 28 bits are never approached. Two SKIPs can be adjacent (a cap, then the
remainder). A count pending when the capture is disabled is dropped: the
capture ended and nothing is owed.

**The mark.** The VBL_MARK notice (VBL.md "The mark") cuts the BUS_EVENTS
message before the origin event, and the origin is always kept. The mark
travels with the event, never with a SKIP, so the cut lands between the
SKIP and the marked event: on the wire, `SKIP | VBL_MARK | [BUS_EVENTS]
EVENT(0,0)`. The host's ring sees the skip word, the marker, the event, in
that order, and its beam - placed by the marker, or by the bit's edge in the
same event - agrees with itself.

**`captured` counts words.** BUS_STATUS reports how many words went into the
FIFO: kept events and SKIPs. That is what the host's parser, session and
pipeline count too, so the completeness check (`captured` against what
arrived) holds unchanged. The number of *cycles* is the kept events plus
the sum of the SKIPs, which the host keeps for itself.

**The synthetic source is never sparse.** It is the link's self-test, and
the host checks its every word against a sequence; `sparse` reaches the
filter as `sparse_ctrl && source_real`.

## Where it sits

`rtl/bus_event_filter.sv`, between `card_link`'s source mux and
`bus_event_capture`, in both modes: in full mode every event is kept and
the count stays zero, so it is a register in the path and nothing more -
one clock of latency, and the pass-through exercised by every capture there
has ever been. Events arrive some ninety clocks apart and the capture takes
one word a clock, so the SKIP-then-event pair on consecutive clocks costs
nothing; the module's one contract is that events are at least three clocks
apart.

## What the host does

`strudelworks-host`: `--sparse`. The decoder's per-word loop gains a branch
for the SKIP: the beam walks the counted cycles and draws them from the
memory as it stands - nothing changed during them, by construction - and
can finish a frame partway through (line 191, cycle 64 is a read); the
speaker's sample clock advances in closed form to each sample boundary,
frozen during reset as it is per cycle; the Mockingboard's prescaler
advances by the count. The mirror, the display's switches, the disk and
the menus see nothing, because nothing happened that they follow. A trace
file recorded in sparse mode carries the SKIP words and a header flag;
`sim/trace_replay_main.cpp` stops at one as it stops at a gap (it cannot
verify blind cycles), and `sim/mmu_trace_check.cpp` counts them and goes on
(the shadow follows writes and `$Cxxx`, which sparse keeps).

## Verification

- `sim/run_bus_event_filter_tb.sh` - full mode passes a mixed stream
  unchanged, in order, marks and all; sparse keeps exactly the rule (first,
  writes, `$Cxxx` reads, both blanking edges, both RES′ edges) each behind
  a SKIP of the right count with the mark on the event; a run of unsent
  cycles is flushed at CAP and the remainder follows; the SKIPs and the
  kept events add up to every cycle sent in; no two words leave on adjacent
  clocks except a SKIP and its event; disable drops the count and re-enable
  keeps the first event again; and chained into the real capture, the wire
  carries `SKIP | VBL_MARK | [BUS_EVENTS] EVENT(0,0)` with `captured` equal
  to the words.
- The host's `sparse_test`: a full stream and its sparse form produce the
  same frames, the same audio, the same mirror.
