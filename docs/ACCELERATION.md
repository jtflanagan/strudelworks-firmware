# The core faster than the bus

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

Status: **rebuilt on the page cache and ✅ on hardware, 2026-08-31; branch
`page_cache`, both repositories** - accel_tb 14.2x mode 2 unlimited (46
checks, both sweep points), and on the machine the same day: Nox at ~7.9x
effective (its `$C0xx` polling is the cap) with the Mockingboard detected
and playing, a wave.dsk floppy boot at ~16x net, the HUD reading in the
gutter, and `aovf`/`aretry`/`mlate`/`mdrops`/`vslips` all zero.**  This is the acceleration
branch's core feature ported onto the page-cache memory architecture
(docs/PAGE_CACHE.md) as a clean restart: the sequencer, the dummies, the
merge, the governor, the class-only slot rule, the reset sequence on the
bus, and the peripherals on core time are all kept exactly as proven on
hardware 2026-08-30 (BASIC at 12.6x, ProDOS from slot 7 and the floppy,
the Mockingboard playing); the L1/D$/turbo work that followed is
deliberately left behind.  A fast op is served by the page cache's
three-clock pipeline instead of the old 4-way cache's six, which is where
the ~14x (was ~10x) in the same testbench comes from.  Three hardware
findings from the first round are baked in from the start: the machine's
MMU infers a reset from the bus, so the reset sequence has to ride it
("The reset sequence"); the floppy and the Mockingboard's timers must keep
the core's time, not the bus's ("What watches which stream"); and the
SmartPort ROM's Open-Apple skip stays gone (the host's ROM).

The card is the Apple's CPU (BUS_MASTER.md) and keeps the machine's memory
(MEMORY.md). Until now the soft core was locked to the bus: one op per phi0
cycle, ~98 fabric clocks each, whatever the card could have answered. This
lets the core run **from the card** - a read of RAM, the language card or a
ROM answered in a handful of clocks, a write of RAM too in one mode - while
the physical bus keeps being driven every cycle, and the ops the machine
must see are **merged in** to real bus cycles. A governor paces it to a
target ratio on average. Mode 0 is the old machine to the clock.

## What is where

```
                  ┌──────────── the unified op stream ─────────────┐
 cpu65c02 ──► accel_seq ──► apple_mmu ─► page_cache / apple_rom / fb_sim  │
   ▲  │          │  ▲        (cl_*)       boot_hold                      │
   │  │ bus op   │  │ the cache's byte, decided, busy                    │
 cyc_en/din      ▼  │                                                    │
             apple_bus_write ──► pins  (a DUMMY - the parked $0000 read  │
                 │ op_* (the bus stream, op_dummy flagged)  - when nothing│
                 ▼                                            is offered) │
   kbd_inject, pb_inject, hd_card, floppy_card, vidhd_card, mockingboard, │
   slot_switches, vbl_lock: unchanged - they only ever see $Cxxx ops,     │
   which are always bus ops, and count time on op_commit, one per cycle   │
```

| piece | file | what it does |
|---|---|---|
| the sequencer | `rtl/accel_seq.sv` | owns `cyc_en` and `din`; decides every op; the unified stream; the governor; the counters |
| the driver | `rtl/apple_bus_write.sv` | `bus_owns` / `core_valid` in, dummies out (`op_dummy`), `op_inflight` |
| the class | `rtl/apple_mmu.sv` | the classifier as a function, asked of the core's live op (`q_cls`); the **CX class** (the motherboard's `$Cxxx` ROM) and INTC8ROM |
| the cache | `rtl/page_cache.sv` | `decided` and `busy`, nothing else (the banks and the page engine: docs/PAGE_CACHE.md) |
| the stream | `rtl/event_merge.sv`, `rtl/bus_event_filter.sv` | fast-op words (tag `0xC`) merged with the bus's, dummies folded into SKIPs |
| the registers | `rtl/wb_regfile.sv` | ACCEL_CTRL, ACCEL_STAT and four counters (PROTOCOL.md) |

## Four kinds of op

| kind | on the pins | the unified stream | the driver's `op_*` |
|---|---|---|---|
| **fast** - a read of RAM, LC, the system ROM or the motherboard's own `$Cxxx` ROM; a RAM/LC write in mode 2 | nothing (a dummy may be in flight) | yes | no |
| **bus** - every `$Cxxx` access a slot answers, and every I/O access; every write in mode 1; everything in mode 0 or with serving off | driven at T_PRESENT as always | yes | yes |
| **override** - the boot hold's, the disk's DMA, the VBL lock's | driven as always | yes (`u_ovr`) | yes |
| **dummy** - nothing offered at T_PRESENT | a read of `$0000` | **no** | yes, `op_dummy` |

Everything on the memory side - the MMU shadow, the cache, the floating-bus
copy, the hold - watches the **unified stream**: every op in program order,
fast or bus or override, with `op_present` where it was and `op_commit` only
for the ops that had a data phase on the bus. Nothing that acts on a commit
can be a fast op: every soft switch is `$Cxxx`. Every peripheral that decodes
`$Cxxx` watches the **driver**, whose ops those always are: a `$0000` read
decodes to nothing in any of them. The two that keep time - the floppy's
nibble clock and the Mockingboard's VIA timers - keep the **core's** time,
one tick per op the core completes (`op_commit && !op_dummy`, or the
sequencer's `fev_valid` for a fast op); see below.

## The decision, and merging

The core moves only on `cyc_en`, and the sequencer owns it. Every op the core
puts up is decided **from registers** - the class off the MMU's classifier,
the direction, the override request - the clock after it appears: made in
the same clock it was the longest path in the build (the microcode ROM
through the classifier into the state register, 16 levels, +0.05 ns).

`needs_bus = mode == 0 || class == BUS || (write && mode == 1) || !serving`.
Nothing else sends an op to the bus. **What is slow is a matter of class
alone**, the rule the user set: a `$Cxxx` access that is not the motherboard's
own ROM - the I/O page, every slot's I/O and ROM pages, a slot's expansion
ROM, on this card or in a socket - is BUS class and rides a real cycle, in
every mode; a read the card's memory answers is fast.  (Revised
2026-09-04, CXXX.md "The on-card slots": in the closed regime an access
one of THIS card's peripherals answers - the hard disk's, the floppy's,
the Mockingboard's - is served on the card; a slot in a socket still
rides the bus.)  There is no hold-off
after a slot access and no rule about a drive turning; a peripheral's code
runs at the bus's pace exactly as far as it touches the bus.

**The floppy keeps the core's time, not the bus's.** There is no drive on
the card, only a track in BRAM, and the one clock that fiction has to keep
is the program's: `floppy_card` ticks once per op of the core - a bus cycle
that carried one, an override's, every fast op, never a dummy - so with the
core locked to the bus it is one tick per cycle as before, and with it
accelerated the platter turns as fast as the core runs and every loop RWTS
and the boot block count in cycles sees the count it always saw. (The user's
point, after the first cut held the core to the bus's pace while a drive
turned, as a real accelerator must for a real drive.) The Mockingboard's
VIA timers tick the same way (`mockingboard.op_dummy/fast_tick`), for the
same reason: every detection routine writes a timer, runs a known number of
instructions, reads it back and accepts the card only if the count moved by
the cycles those instructions took - on bus time under a 12x core it moved
by a twelfth of that and the game found no Mockingboard (the user's report,
after the floppy fix). A real Mockingboard in a real accelerated machine
keeps bus time and those same routines fail there too, which is why the
accelerators of the day had slot slow-down switches; a virtual one has no
reason to.
`fill_max` and `late` are in the floppy's ticks, so the host's track budget
shrinks by the ratio - its fills measured half a millisecond against the
RWTS's 37 ms, room enough at 12x. The image not being ready makes a fast op
**wait**: in mode 2 the bus would answer a RAM read with the machine's stale
byte. A fast op also waits for the cache and its page engine to be idle
(`busy` - which is what keeps `late_fills` at zero by construction), for no
op to be on the bus (`op_inflight`), and for governor credit.

A **fast op** is presented to the MMU and the cache, decided at the page
cache's P3 (a hit, a claim, a ROM byte, a write) or when a miss's critical
beat lands, and the core takes the byte on that clock: **about seven clocks
an op, ~14x** at 98 clocks a cycle - the page cache's three-clock pipeline
against the old design's six is the whole difference from the first round's
~11x.  The sequencer's one-op-at-a-time discipline is what keeps a write
from being read back before the bank has it. A fast read the cache decided
without a byte is decided again, never sent to the bus: in mode 2 the
machine's RAM is stale and the bus's byte would be wrong.

A **bus op** raises `bus_owns` and `core_valid`; the driver latches it at
its next T_PRESENT exactly as before, and the core moves at `cyc_done` -
the old timing for that one op. **The timing fact that shapes this**: `cyc_en`
fires at rise+47 and the driver samples the core's op at rise+52 (T_CYCEN is
counted from the rising edge, T_PRESENT from the falling one). The core's
next op is valid only ~4 clocks before the driver's sample point - not the
"~50" the driver's header used to claim - so `core_valid` is **cleared on
`cyc_done`** and set again only by a decision: the driver can never latch an
op the sequencer has not offered. Two consecutive bus ops ride consecutive
cycles - "stay merged" - because the decision fits in that gap;
`sim/run_accel_tb.sh` sweeps it down to 3 clocks. When the next op does not
need the bus, `bus_owns` drops and the driver is back to dummies.

**The reset sequence rides the bus.** The IIe's MMU does not act on RES′: it
infers a reset from the sequence the 6502 makes coming out of one - three
reads on the stack page, then the vector fetch reads of `$FFFC` and `$FFFD` -
and only then puts its soft switches back. Those seven cycles are RAM and
ROM class, and the first cut served them from the card: the bus saw dummies,
the machine's MMU never reset, INTCXROM stayed set from the last program, and
the autostart ROM's slot scan read the motherboard ROM's memory self-test in
place of every slot ROM - `PR#7` printed its digits, and no disk booted.
Found on hardware by the user, who had met it in another accelerator. So
from reset until the core's read of `$FFFD` has **completed on the bus**
(`reset_seq`, ACCEL_STAT [24]) every op is a bus op, exactly as in mode 0;
the op after it - the first opcode fetch - is decided normally, and an armed
boot hold takes it through the override path as before. The testbench's
machine model now resets its switches the way the machine does - on the
sequence seen on the pins, not on RES′ - and the run without the rule fails
as the hardware did.

**The SmartPort ROM no longer looks at Open-Apple.** The host holds
Open-Apple down across the boot hold's release so the //e's reset handler
takes its cold path, and lets go 50 ms later. The SmartPort ROM vendored
from AppleWin checked Open-Apple again 20 000 cycles after the reset handler
and skipped its slot if the button was still down - AppleWin's convention
for "boot from the next slot"; at 5-12x that check came inside the 50 ms,
and slot 7 never booted while every floppy did (found with a trace of the
boot: the scan read the signature, jumped to `$C700`, read `$C061` as `A0`
and took the branch to `$FABA`). The boot menu is where this machine decides
whether the disk is in play, so the check is simply gone from the ROM
(`firmware/hdc_smartport.s`, the user's call); a once-only button level on
the card was built for it first and taken out again.

An **override** wanting the bus is honoured at the next decision: the bus is
handed over (`bus_owns`, nothing offered) until `ovr_en` has dropped *and*
its last cycle has had its data phase (`op_inflight` - hd_card releases the
clock after its last byte's present, 45 clocks before that byte lands) *and*
the cache is idle. The core sits still, so boot_hold's `engage`, which is
combinational on the core's live SYNC, catches the fetch it wanted; and the
hold watches the unified stream so a SYNC the core fetched from the card
still counts as one (else an `arm` given later would engage at a random
fetch). An override arriving mid-fast-op waits that op plus at most one bus
cycle.

**Exclusivity**: `bus_owns` is a registered level, set only when no fast op
is in flight; the driver latches an op - override or core - at T_PRESENT
only if it is set, else drives a dummy. The unified stream is registered in
the sequencer, so an override's commit forty clocks after its present still
sees its own address in the MMU's switch decoder.

## The governor

A leaky bucket in ops: every bus cycle adds the target (ACCEL_CTRL [23:8],
ops per bus cycle in 8.8 fixed point), every op - fast **and** bus - costs
one, and no op starts below one. So a target of 1.0 averages to the
machine's own speed, 0 is unlimited, and the bucket holds four cycles'
worth: a run of merged cycles is followed by at most that much of a burst.
Measured in the testbench: 3.99 at a target of 4.00, 1.00 at 1.00.

## The CX class: the motherboard's `$C100-$CFFF` served

Before this every fetch from `$C100-$CFFF` - including the internal ROM's
`$Cxxx` half, the 80-column firmware ProDOS runs so much of its time in -
was BUS class, and under acceleration every one would have merged. Now the
reads the **motherboard's own ROM** answers are ROM class, and every slot's
page stays BUS - UTAIIe 5-28 as AppleWin's `Memory.cpp` implements it:

```
read of $C100-$C7FF, page n:  INTCXROM, or n == 3 and SLOTC3ROM clear
                                        -> ROM, from the internal ROM
                              else (a slot's: a ROM on this card or in a
                              socket, the Mockingboard's VIAs, nothing)
                                        -> BUS
read of $C800-$CFFE:          INTCXROM or INTC8ROM -> ROM, internal
                              else (a slot's expansion ROM) -> BUS
$CFFF, every write, every $C0xx        -> BUS
```

`intc8rom` is the IIe's unreadable latch: set by any access to `$C3xx`
while SLOTC3ROM is clear - in either state of INTCXROM, UTAIIe 5-28 as
AppleWin has it (the first cut also required INTCXROM clear; with INTCXROM
set, a `$C3xx` access, then INTCXROM cleared, the machine keeps `$C800-$CFFF`
internal and the card now agrees) - cleared by any access to `$CFFF`
and by RES′. It is set at `op_present` rather than `op_commit`, because a
`$C3xx` fetch served from the card has no data phase; for one that does the
difference only reaches the *next* op, which cannot be presented before this
one's commit. `MEM_STAT[13]` reads it. The internal ROM not yet loaded classifies as BUS,
so "ROM class" always means the card has the byte.

Proven where the old ROM class was: `sim/run_mmu_trace.sh` on the three real
captures compares every ROM-class read with the file - **4.7 M of them on
`apple.bustrace`, 0 mismatches**, half a million more than before, the
`$C100-$CFFF` reads among them.

The first cut served the on-card slot ROMs too, through a second read port
on each, and held the core to the bus's pace while a floppy drive turned.
Neither was in the plan the user set - "a `$Cxxx` slot that is not
motherboard ROM is slow, otherwise fast" - and the served slot ROM is where
the hard disk stopped booting on hardware; both are gone.

## The stream

The reader still produces one event per bus cycle from the pins, dummies
included; the sequencer produces one word per fast op, on the clock the core
takes the byte: `{0xC, data, {vbl, sync, res, rw}, addr}` - the event's
layout under a tag of its own, so every reader that checks the tag it always
checked sees at once that this is an op and not a cycle. `rtl/event_merge.sv`
puts both into one FIFO in arrival order (the bus's word first on a
collision: it is the older cycle) and drains it one word per three clocks,
the spacing the filter needs. Program order is arrival order - a fast op
that precedes a bus op in the program was taken before that op was offered,
and the bus op's event comes 45 clocks after its present - which the hard
disk's write path needs structurally: the host takes the block out of its
mirror at the EXECUTE, and in mode 2 a fetch from the machine would read
stale RAM.

The filter then applies three rules. A **dummy** is counted, in both modes -
so a full capture of an accelerated machine has SKIPs in it - *unless* it is
the first cycle after enable, the marked cycle, or a cycle where the
blanking level or RES′ changes: then it is kept as the `$0000` read it is,
because the host places its beam by those two edges and sees a reset by the
other, and under acceleration most cycles are dummies and the whole of a
RES′-low window is. A **fast op** is kept by the rule an event would be
(every one in full, writes in sparse), never counted, and never consulted
for the edge rule: a fast op taken between two ticks carries the next
cycle's level, and an edge seen on it would not be seen again on the cycle's
own event. An ordinary cycle's event keeps the old rule. The host's
`sparse_filter.hpp` says the same, and `accel_test` holds the two to the same
stream.

## The keyboard in the dummies (2026-09-02)

The finding (docs/CXXX.md, "The second finding"): Nox at its overworld map
showed 20x, and a full trace put 92% of the bus events at $C000 - the
keyboard poll - each costing TWO bus cycles (the read's own, and the next
present point missed by the op that follows), 72% of the machine's time.

So in the closed regime - mode 2, serving, ACCEL_CTRL[28] clear, and the
core NOT held - the driver's dummy cycles park at `$C000` instead of
`$0000` (`park_kbd` into apple_bus_write): every idle bus cycle samples
the real IOU, key and strobe together, into a latch in rtl/kbd_inject.sv
(the raw pins' byte; a dummy is a SAMPLE, never a read, so no
substitution lands on it and none of the read-side state moves).  A
program's read of `$C000-$C00F` is then served on the card: accel_seq
decodes it beside the class (`q_swi`, a 12-bit compare on the live
address registered into `dq_swi`), the op rides S_FAST like any fast op
(the cache decides it with nothing served), the byte is kbd_inject's
`int_byte` - the same decision a bus read gets: the injected key first,
the latch's real byte unless locked or the hotkey, else {0, last_read} -
and the retirement raises a SYNTHETIC COMMIT on the unified stream
(`swi_commit`), the one deliberate bend of "fast ops have a present and
no commit", so every commit-gated consumer sees a bus op's commit and
`int_rd` applies the read's bookkeeping (seen, last_read, the hotkey)
exactly once.  A strobe-clearing bus op (`$C010`, a `$C01x` write)
clears the latch's bit 7 as it clears the IOU's, so $C010-then-$C000
cannot hand a key over twice.  `$C010` and the `$C01x` accesses stay on
the bus: they are the real strobe's.  While a HOLD reads the keyboard for
the host the dummies park at `$0000` again, so no edge-kept dummy can
look like a keypress to the host's menus; the latch refills on the first
dummy after the release and `int_ok` gates serving until it has.

How real keys and injected keys interact is unchanged - only where the
real sample comes from.  The stream: a served read is a fast-op word
(dropped in sparse like any read); the dummies are counted into SKIPs as
before, and the edge-kept ones are now reads of `$C000` carrying the
machine's own byte.

The lever: ACCEL_CTRL[28] `swint_dis`; `swint = on|off` in the
configuration; `swctl accel swint on|off` at runtime; the accel status
line says "swint OFF".  Off parks the dummy at `$0000` and puts every
`$C00x` read back on the bus.

The testbench (sim/accel_tb.sv, SWINT parameter): the program polls the
keyboard once a pass; in mode 1 every poll rides the bus, in mode 2 none
does once the latch has filled, and an injected key pressed from the
bench is served to the poll from the card, taken with the `$C010` that
rides the bus, and stored by the program as {1, $41}.  The boot bench
carries the same instance (no injection, `--swint-off` to compare).

Left for later, deliberately (the acceleration branch's fuller version of
this regime, commit 15c8444 there, is the reference): the status page
`$C011-$C01F` from the shadow, the switch WRITES `$C000-$C00F`/`$C05x`/
`$C08x`, the RamWorks bank; a menu hotkey found by the parked dummies
themselves, which would let Ctrl-6 work in a program that never polls.

**Extended 2026-09-03** to the status page, `$C019` and the floating
toggles - the same S_FAST ride and synthetic commit, the byte from
whichever authority owns the address: docs/CXXX.md, "The switch reads in
the closed regime".

## The census (2026-09-02)

At 58x on hardware (Nox, moving about the map) the counters put 92% of
the ops at one clock and the dispatcher's fast ops - 7.6% of the ops at
~8 clocks each - at 36% of all clocks, bus ops (two cycles each) at 9%;
the arithmetic closes, there is no other stall pool.  So the road from
60x toward the 98x ceiling is the dispatcher's share, and the question
is WHICH reads those are.  A full trace would say but wedges the link at
this speed, so the sequencer counts them: ACCEL_FAST_I (I-stream fetches
the front missed or declined), ACCEL_FAST_DRAM (data reads the data
front missed), ACCEL_FAST_DLC, ACCEL_FAST_DROM ($D000+), ACCEL_FAST_DCX
(the internal ROM's tables in $Cxxx), ACCEL_FAST_WR (every write the
dispatcher retired, an internalized switch write included - CXXX.md,
"The switch writes"), ACCEL_FAST_KBD (every internalized READ: the
keyboard, the status page, the floating toggles and the LC) - seven
exclusive buckets that sum to ACCEL_FAST, cleared with the rest.
The host polls them while accelerating and `swctl accel status` reports
them after the ratio.

## The registers

```
ACCEL_CTRL    0x8000_008C   [1:0] mode: 0 off, 1 reads on the card / writes on
                            the bus, 2 reads and writes on the card; [23:8]
                            target, ops per bus cycle, 8.8, 0 = unlimited;
                            [28] swint_dis: the keyboard not internalized,
                            dummies at $0000 (a level); [27] game_dis: the
                            game port not internalized, dummies at $C000
                            alone (CXXX.md "The game port"); [31] W1 clear counters
ACCEL_STAT    0x8000_0090   [0] accelerating; [1] held by the governor;
                            [3] bus_owns; [7:4] state; [15:8] merge overflows
                            (must be 0); [23:16] fast ops decided twice;
                            [24] the reset sequence is still on the bus
ACCEL_FAST    0x8000_0094   fast ops
ACCEL_BUS     0x8000_0098   the core's ops that rode a bus cycle
ACCEL_CYCLES  0x8000_009C   bus cycles while accelerating
ACCEL_WAIT    0x8000_00A0   clocks the core spent waiting to merge
GAME_STAT/2   0x8000_00C8/CC  the game port's samples: the buttons' levels,
                            the four paddles' timer counts (CXXX.md "The game port")
ACCEL_FAST_I .. ACCEL_FAST_KBD  0x8000_00AC .. 0x8000_00C4   the census of
                            ACCEL_FAST: I-stream fetches, data reads of
                            RAM / LC / ROM $D000+ / ROM $Cxxx, writes
                            (internalized switch writes included), the
                            internalized reads - seven buckets that sum to it
```

Levels, like MEM_CTRL's, safe under a running machine - with **one rule**:
mode 2 leaves the machine's own RAM stale (only its video reads it), and a
change to any state where the core would read it again - mode 0, or serving
off - would run stale memory. The host refuses both while in mode 2: go to
mode 1 first, or reset. Mode 2 also turns the floating-bus serve on
(FLOATING_BUS.md): the machine's floating bus is stale there too, and the
card's simulated byte is the right one - which needs the VBL lock. DERISK.md's
"chosen at boot and never changes" is relaxed to that.

## Decisions, and why

**Serialised, ~14x, not pipelined.** The page cache holds one op and its
tags have no bypass (docs/PAGE_CACHE.md, "ONE OP AT A TIME"); the
sequencer presents the next op only when the last is decided, which makes
every hazard the pipelined design would have simply not exist. The
sequencer's interface to the cache - present, `decided`, `busy` - is what a
pipelined cache would keep, so that work starts from here.  (The first
round's L1/turbo work pipelined exactly this seam; it is deliberately not
here - this restart takes the page cache's honest per-op cost and stops.)

**Mode 0 is the old machine to the clock**, by construction: `bus_owns` and
`core_valid` are forced high, `cyc_en` and `din` are the driver's, and the
state machine merely follows along so a mode switched under a running
program lands in a defined place. The testbench checks it: no dummy, no fast
op, every `cyc_en` the driver's.

**Writes wait, in mode 1.** Every write costs a bus cycle and the core waits
for it, so mode 1 lands around 2x on a write-heavy loop (7.5x on the
testbench's read-heavy one). Posting writes - a queue the core need not wait
on, drained one per bus cycle, ordered ahead of any later `$Cxxx` op - is
the follow-on that lifts it towards mode 2's speed.

**Sparse capture goes with acceleration.** In full mode every fast read is a
word to the host - some 12 M a second at 12x, none of which the host has a
use for - and the one time the card was started with mode 2 written at
connect in full mode the FT601 dropped off the Pi's USB in its first
milliseconds (dmesg: a disconnect and a re-enumeration). With sparse
capture, and the mode set once the link is up, it has run for as long as it
was watched. Whether the rate or the timing is what the FT601 objected to is
not yet known.  On this branch the host's `sparse` key DEFAULTS TO ON, by
decision - full capture is for trace-replay debugging only, and cannot keep
up with an accelerated core.  Reproduced 2026-09-02 with the keyboard in
the dummies: at 50-60x a FULL capture wedges the link (the user switched
the BUS CAPTURE row back to sparse to run at all); the Nox comparison
trace was taken sparse for that reason.

**Programs that count CPU cycles between floating-bus reads break**,
inherently: the floating bus is real time and the core is not. Every
peripheral on the card keeps machine time, so nothing on the card drifts.

**Under acceleration the memory client's windows are the whole cycle**
(`page_client.accel`): fills and flushes land at any point in the cycle, and
the 30-50 window that used to keep refreshes and ring batches clear of the
next op would only starve the ring. A refresh under a fast op is a stall,
not a wrong answer (DDR3_USAGE.md).

## Numbers

In simulation on this branch (`sim/run_accel_tb.sh`, the real core on
sim/accel.s against the 128K IIe model): **mode 2 unlimited 14.2x** (32 842
fast + 181 bus ops over 2 323 cycles), mode 1 8.5x on that read-heavy
program, the governor 4.00 at 4.00 and 1.00 at 1.00; 258 K reads, every one
the reference's byte; `late_fills` 0, `fifo_drops` 0, merge overflows 0; 46
checks at both sweep points.  The master build: **11 164 LUTs (53.7 %,
about +900 for the sequencer and the merge), BRAM unchanged at 49 of 50
tiles, setup WNS +0.551 ns, hold WHS +0.034 ns** - no worse than the
page-cache build it lands on (+0.525).  The full iverilog battery (14
suites) passes.  The hardware run, and the CX class against the real
captures (none on this machine), are still to come.

For the record, the first round on the old memory image (branch
`acceleration`, on hardware 2026-08-30): 10.0x in this same testbench;
on the machine (`tools/accel_test.sh`, a `FOR I=1 TO 20000:NEXT` loop from
a ProDOS BASIC prompt, sparse capture) 22.4 s at the bus's pace, mode 1
4.18 s (5.4x), mode 2 at a target of 4.0 exactly 4.00, mode 2 unlimited
1.78 s (12.6x) with `mlate`, `mdrops`, `aovf` 0 throughout, no beam slip,
no floating-bus trip.

## What proves it

| | what it settles |
|---|---|
| `sim/run_accel_tb.sh` | the real core, driver, reader, sequencer, MMU, ROM, cache, client, arbiter and hold against the 128K IIe model, running `sim/accel.s`: mode 0 bit-exact (no dummy, no fast op, every cyc_en the driver's); modes 1 and 2 unlimited and the governor at 4.0 and 1.0; every read the reference's byte, fast or bus; every dummy the parked read; no BUS-class op served fast; every write on the pins in mode 1 and none in mode 2; consecutive bus ops on consecutive cycles; a DMA of the disk's shape mid-run with its last byte's commit its own; the armed boot hold at the post-reset fetch and a runtime knock at the next SYNC, accelerating; a reset; the CX class's every case, every slot read on the bus; swept over the core-to-present margin down to 3 clocks |
| `sim/run_bus_write_tb.sh` | the driver: a dummy when nothing is offered, an override refused while the bus is not owned, `op_inflight` spanning present to data phase; and the old checks unchanged with the levels tied |
| `sim/run_bus_event_filter_tb.sh` | the three rules, both modes; the merge's order, spacing and the same-clock collision |
| `sim/run_mmu_trace.sh` | the CX class against three real captures, 0 mismatches |
| `sim/run_reg_map_tb.sh` | the six registers end to end from a REG_WRITE |
| every other suite | unchanged and passing: the levels tied, the old machine |
| the host's `tests/accel_test.cpp` | the word and the registers; the filter's rules; a scripted machine's full stream and its mode-1 and mode-2 forms, full and sparse, reconstructing the same memory, switches and display through the host's own consumers; edges on dummies not lost; the mock card accelerating under the pipeline; a disk write's block out of the mirror |
| the host's `tools/accel_test.sh` | on the real machine: a BASIC loop timed at each mode, the card's own ratio against the target, and the ways out |

## The instruction stream front

The first "turbo" step, redone on this branch the full way through: the
core names each cycle's stream on split data ports, and two 16-byte lines
ahead of the sequencer retire program-stream fetches in ONE clock, with
next-line prefetch riding the code's linearity and cyc_en as the late
cancel - 29.5x in the testbench that gave 14.2x without it.  The whole
design, its rules and its books: docs/ISTREAM.md.

## Not here, deliberately

- **Posted writes** for mode 1 (above).
- **Pipelining the cache** past ~11x: a write-then-read bypass on the ways
  and the tag word, behind the same `present`/`decided`/`busy` interface.
- **A flush walk** when leaving mode 2 - copying the image back into the
  machine's RAM - so mode 0 could follow mode 2 without a reset.
- **A hold-off after a slot access** (a TransWarp's "slot speed", or a
  Disk II's motor): the core at the bus's pace for a while around a slot's
  I/O. Not asked for; word 41 of the register map is left for it if it is.
- **A socket's slot served from the card**: BUS, always, by the rule above.
  (The card's OWN slots are served on the card since 2026-09-04, CXXX.md
  "The on-card slots".)
- **The periodic timestamp record** in the trace (DDR3_USAGE.md): a trace of
  an accelerated machine is not a cycle stream; the host flags it
  (`kFlagAccel`) and the replay tool refuses it, while the MMU check still
  follows the shadow through it.
