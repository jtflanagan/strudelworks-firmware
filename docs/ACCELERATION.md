# The core faster than the bus

Status: **✅ on hardware, 2026-08-30** - BASIC at 12.6x, the governor holding
4.00 at a target of 4, ProDOS booting from slot 7 and the floppy, and the
Mockingboard detected and playing, all in mode 2 - after three findings the
simulation had not modelled: the machine's MMU infers a reset from the bus,
so the reset sequence has to ride it ("The reset sequence"); the floppy and
the Mockingboard's timers must keep the core's time, not the bus's ("What
watches which stream"); and the SmartPort ROM inherited an Open-Apple skip
from AppleWin. Branch `acceleration`, both repositories.

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
 cpu65c02 ──► accel_seq ──► apple_mmu ─► mem_cache / apple_rom / fb_sim   │
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
| the L1 front | `rtl/l1_front.sv` (+ `rtl/class_tlb.sv`, `rtl/icache_l1.sv`) | the icache and its page-TLB ahead of the sequencer: a fetch both know retires in ONE clock - a TURBO op the sequencer sees only as the books; the claim, the fills, the write snoop |
| the sequencer | `rtl/accel_seq.sv` | owns `cyc_en` and `din` (through the front); decides every op; the unified stream; the governor; the counters |
| the driver | `rtl/apple_bus_write.sv` | `bus_owns` / `core_valid` in, dummies out (`op_dummy`), `op_inflight` |
| the class | `rtl/apple_mmu.sv` | the classifier as a function, asked of the core's live op (`q_cls`); the **CX class** (the motherboard's `$Cxxx` ROM) and INTC8ROM |
| the cache | `rtl/mem_cache.sv` | `decided` and `busy`, nothing else |
| the stream | `rtl/event_merge.sv`, `rtl/bus_event_filter.sv` | fast-op words (tag `0xC`) merged with the bus's, dummies folded into SKIPs |
| the registers | `rtl/wb_regfile.sv` | ACCEL_CTRL, ACCEL_STAT and four counters (PROTOCOL.md) |

## Four kinds of op

| kind | on the pins | the unified stream | the driver's `op_*` |
|---|---|---|---|
| **turbo** - a program-stream fetch whose page the I-TLB knows and whose line the icache holds | nothing | **no** - only its capture event and the books | no |
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
decodes to nothing in any of them.

A TURBO op is not even on the unified stream: it is a read of a line the
card already holds, so no consumer needs it - the MMU's shadow moves only on
`$Cxxx` and the two pages that can flip INTC8ROM (`$C3xx`, `$CFxx`) are
never turbo-servable, the hold learns of the fetch by `aux_sync`, and the
capture gets the event word. The two that keep time - the floppy's nibble
clock and the Mockingboard's VIA timers - keep the **core's** time, one tick
per op the core completes: `op_commit && !op_dummy` for a bus op, the
sequencer's `op_tick` for a fast or turbo one. `op_tick` exists because a
turbo event can be shed under capture pressure but a timer tick never may.

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
every mode; a read the card's memory answers is fast. There is no hold-off
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
RWTS's 37 ms, room enough at 12x. An invalidate in progress, or the image
not ready, makes a fast op **wait**: in mode 2 the bus would answer a RAM
read with the machine's stale byte. A fast op also waits for the cache to be
idle (`busy`), for its last request to have been taken (`mq_valid`, which is
what keeps `fifo_drops` at zero by construction), for no op to be on the bus
(`op_inflight`), and for governor credit.

A **fast op** is presented to the MMU and the cache, decided at the cache's
P6 (a hit, a ROM byte, a write) or when its fill lands, and the core takes
the byte on that clock: **nine clocks an op, ~11x** at 98 clocks a cycle.
The core's own latency between one op and the next is what keeps a write
from being read back before the way RAM has it. A fast read the cache
declined - an invalidate that began after the decision - is decided again,
never sent to the bus.

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
while INTCXROM and SLOTC3ROM are both clear, cleared by any access to `$CFFF`
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

## The L1 front: one clock per fetch

The serialised fast path costs nine clocks an op. Two thirds of a 6502's
cycles are program-stream fetches (the Klaus suites measure 66/34), and for
those the front end takes the nine down to ONE:

- **The I-TLB** (`rtl/class_tlb.sv`): the MMU's answer cached per 256-byte
  page - which is the grain everything on a IIe is decided at - 256 entries
  direct-mapped by `addr[15:8]`, each holding both the read and the write
  view of its page (class, physical page, write-lands-in-image). Full
  coverage, so only cold misses exist; a miss refills from `apple_mmu`'s
  `t_*` page query in a clock. Any access that moves the map
  (`apple_mmu.map_changed`: the mapping soft switches, the RamWorks bank
  register, every `$C08x` touch, INTC8ROM moving, RES', the ROM arriving)
  clears the whole valid vector at that same edge - never an update in
  place - and the entries refill lazily. The two pages that are not uniform
  or that mutate the map by mere access, `$C3` and `$CF`, are never
  L1-servable, so INTC8ROM's triggers always reach the MMU as presented ops.
  **The fetch clock never reads the TLB.**  The first build proved it could
  not (WNS -4.8 ns: the PC through one 256-deep LUTRAM into another, 22
  levels, mostly routing).  Instead a PAGE REGISTER holds the last entry
  used - the prediction that the next fetch shares it, which only a page
  crossing breaks - and the fetch clock is flip-flops on both sides: an
  8-bit page compare, a concatenated physical address, an index off
  registers.  A mismatch stalls one clock, during which the TLB is read
  register-to-register with a whole clock to make it, the page register
  reloads, and the row re-steers from the TLB's live answer: +1 clock per
  page cross, and a hot loop straddling a boundary pays it twice per lap
  (the mix line's page-stall count is what would justify a second,
  previous-page register).

- **The icache** (`rtl/icache_l1.sv`): 4 KB, 256 lines of 16 bytes,
  direct-mapped, physically indexed and tagged in the 25-bit space
  `{rom, pa[23:0]}` - the internal ROM is its own space, and LC banks,
  ALTZP and every RamWorks bank coexist without aliasing, which is also why
  a TLB flush does NOT flush the icache: only translations refetch. A block
  RAM answers a clock late, so the row register is steered a clock EARLY:
  by `i_steer` - the core's REGISTER-ONLY prediction - while the core
  runs, and by the live address while it retries.  i_steer leans on the
  6502's own grants: every carried or data-borne PC load is followed by
  an extra cycle (the taken branch's dummy, the page-cross fixup, RTS's
  increment) in which the PC registers settle, and JMP/JSR's target low
  nibble sits in `md`, a register - so a steer with no din, no AGU and
  no condition logic behind it is dynamically identical to the exact
  predictor, and the row-verdict's whole cone stays flip-flop-shallow.

- **The late cancel**: the core launches every clock as if the steered row
  were right; `cyc_en`, now a last-moment combinational signal, simply
  stays low when it was not, and the identical cycle retries. cpu65c02
  (`cyc_is_i`, `i_pred`, the classified views) proves this contract under
  `sim/run_cpu_predict_tb.sh` with garbage driven on `din` through every
  cancelled clock.

- **The claim**: an I-fetch the front might yet serve raises `l1_claim` for
  its first three clocks, holding the dispatcher off - clock 0 looks (and
  refills a cold TLB page), clock 1 retries with the row steered right (a
  mispredicted branch: two clocks, not nine), clock 2 covers the cold-page
  case - then falls, and the op rides the sequencer exactly as before, at
  most two clocks later than it would have. `turbo_ok` (S_DECIDE, credit,
  no override, no reset sequence, serving, the claim itself) and the
  claim's `!l1_claim` in the dispatch make a turbo op and a dispatch
  mutually exclusive by construction.

- **Fills**: an image line is installed by OBSERVATION - the fetch that
  missed rides the sequencer, and `mem_cache`'s new `sub_line` (the whole
  16 bytes the byte came from, hit or fill) is taken as it flies past. A
  ROM line is streamed by the front itself from `apple_rom`'s second read
  port, four words racing the op's own nine-clock service. Both are gated
  on the TLB entry still standing.

- **Coherence**: every write that lands in the image - the core's, a
  diverted RamWorks write, the disk's DMA - snoops the icache by physical
  line address on the clock it is classified (`cl_*`), BEFORE it reaches
  the image; the refetch rides the sequencer behind it, in order.
  Self-modifying code therefore cannot fetch stale - `sim/accel.s`'s
  `smctest` rewrites an operand and an opcode every pass and reads them
  back through the data side. The flash (the host invalidating, the ROM
  reloading) clears every line at an edge, same as the TLB.

- **The books**: the sequencer charges the governor 256 per turbo op,
  counts it (ACCEL_TURBO), pulses `op_tick` for the op-time clocks, and
  emits the capture event - the last only when `event_merge` has room
  (`fev_room`), because turbo runs outpace the merge's drain three to one
  and shedding fetch events at the source is what keeps the merge's
  overflow counter a fault flag. A sparse capture discards fast reads
  anyway; nothing a trace keeps is lost.

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

## The registers

```
ACCEL_CTRL    0x8000_008C   [1:0] mode: 0 off, 1 reads on the card / writes on
                            the bus, 2 reads and writes on the card; [23:8]
                            target, ops per bus cycle, 8.8, 0 = unlimited;
                            [25] turbo_dis - the L1 front serves nothing, every
                            op is the sequencer's; [26] drain_dis - hd DMA
                            rides the bus, never the image (both diagnosis
                            levels, DIAG_ACCEL_HW.md; 0 in normal use);
                            [31] W1 clear counters
ACCEL_STAT    0x8000_0090   [0] accelerating; [1] held by the governor;
                            [3] bus_owns; [7:4] state; [15:8] merge overflows
                            (must be 0); [23:16] fast ops decided twice;
                            [24] the reset sequence is still on the bus
ACCEL_FAST    0x8000_0094   fast ops
ACCEL_BUS     0x8000_0098   the core's ops that rode a bus cycle
ACCEL_CYCLES  0x8000_009C   bus cycles while accelerating
ACCEL_WAIT    0x8000_00A0   clocks the core spent waiting to merge
ACCEL_TURBO   0x8000_00A4   ops the L1 front served in a single clock
```

The ratio the card achieved is (TURBO + FAST + BUS) / CYCLES.

Levels, like MEM_CTRL's, safe under a running machine - with **one rule**:
mode 2 leaves the machine's own RAM stale (only its video reads it), and a
change to any state where the core would read it again - mode 0, or serving
off - would run stale memory. The host refuses both while in mode 2: go to
mode 1 first, or reset. Mode 2 also turns the floating-bus serve on
(FLOATING_BUS.md): the machine's floating bus is stale there too, and the
card's simulated byte is the right one - which needs the VBL lock. DERISK.md's
"chosen at boot and never changes" is relaxed to that.

## Decisions, and why

**Serialised, ~11x, not pipelined.** The cache pipeline holds one op and the
way and tag RAMs have no bypass (MEMORY.md, "The accelerated mode"); the
sequencer presents the next op only when the last is decided, which makes
every hazard the pipelined design would have simply not exist. The
sequencer's interface to the cache - present, `decided`, `busy` - is what a
pipelined cache would keep, so that work starts from here.

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
milliseconds (dmesg: a disconnect and a re-enumeration). With `--sparse`,
and the mode set once the link is up, it has run for as long as it was
watched. Whether the rate or the timing is what the FT601 objected to is not
yet known; `accel` should be used with `sparse = on`.

**Programs that count CPU cycles between floating-bus reads break**,
inherently: the floating bus is real time and the core is not. Every
peripheral on the card keeps machine time, so nothing on the card drifts.

**Under acceleration the memory client's windows are the whole cycle**
(`mem_client.accel`): fills and writes land at any point in the cycle, and
the 30-50 window that used to keep refreshes and ring batches clear of the
next op would only starve the ring. A refresh under a fast op is a stall,
not a wrong answer (DDR3_USAGE.md).

## Numbers

Master build of 2026-08-29: **10 042 LUTs (48 %, +1.0 k)**, BRAM unchanged at
35.5 of 50, setup WNS **+0.134 ns**, hold +0.049 ns. The worst path is the
driver's divert decision off the core's ROM (`u_cpu/uc_reg → u_write/drv_div`,
16 levels), which predates this work. With the decision made in the same clock
as the core's ROM the build had closed at +0.053 ns on `uc_reg → u_seq/st_reg`
and 10 640 LUTs; registering it bought the 0.08 ns for one clock a fast op.

In simulation (`sim/run_accel_tb.sh`, the real core on sim/accel.s against
the 128K IIe model): **mode 2 unlimited 10.0x** (32 814 fast + 178 bus ops
over 3 284 cycles), mode 1 7.5x on that read-heavy program, the governor
3.99 at 4.00 and 1.00 at 1.00; 280 K reads, every one the reference's byte;
`late_fills` 0, `fifo_drops` 0, merge overflows 0.

On the machine (`tools/accel_test.sh`, a `FOR I=1 TO 20000:NEXT` loop from a
ProDOS BASIC prompt, sparse capture): at the bus's pace **22.4 s**; mode 1
**4.18 s (5.4x)**, the card counting 4.13 ops a cycle; mode 2 at a target of
4.0 **5.4 s** with the card at exactly 4.00; mode 2 unlimited **1.78 s
(12.6x)** - the card's count over the interval is lower (7.0) because the
interval takes in the prompt's keyboard polling, every read of `$C000` a bus
cycle. `mlate`, `mdrops`, `aovf` 0 throughout, no beam slip, the mismatch
count flat in mode 1, no floating-bus trip in mode 2.

## What proves it

| | what it settles |
|---|---|
| `sim/run_accel_tb.sh` | the real core, driver, reader, sequencer, MMU, ROM, cache, client, arbiter and hold against the 128K IIe model, running `sim/accel.s`: mode 0 bit-exact (no dummy, no fast op, every cyc_en the driver's); modes 1 and 2 unlimited and the governor at 4.0 and 1.0; every read the reference's byte, fast or bus; every dummy the parked read; no BUS-class op served fast; every write on the pins in mode 1 and none in mode 2; consecutive bus ops on consecutive cycles; a DMA of the disk's shape mid-run with its last byte's commit its own; the armed boot hold at the post-reset fetch and a runtime knock at the next SYNC, accelerating; a reset; an invalidate landed on a fast read (decided again, and no RAM read on the bus); the CX class's every case, every slot read on the bus; swept over the core-to-present margin down to 3 clocks |
| `sim/run_bus_write_tb.sh` | the driver: a dummy when nothing is offered, an override refused while the bus is not owned, `op_inflight` spanning present to data phase; and the old checks unchanged with the levels tied |
| `sim/run_bus_event_filter_tb.sh` | the three rules, both modes; the merge's order, spacing and the same-clock collision |
| `sim/run_mmu_trace.sh` | the CX class against three real captures, 0 mismatches |
| `sim/run_reg_map_tb.sh` | the six registers end to end from a REG_WRITE |
| every other suite | unchanged and passing: the levels tied, the old machine |
| the host's `tests/accel_test.cpp` | the word and the registers; the filter's rules; a scripted machine's full stream and its mode-1 and mode-2 forms, full and sparse, reconstructing the same memory, switches and display through the host's own consumers; edges on dummies not lost; the mock card accelerating under the pipeline; a disk write's block out of the mirror |
| the host's `tools/accel_test.sh` | on the real machine: a BASIC loop timed at each mode, the card's own ratio against the target, and the ways out |

## Not here, deliberately

- **Posted writes** for mode 1 (above).
- **Pipelining the cache** past ~11x: a write-then-read bypass on the ways
  and the tag word, behind the same `present`/`decided`/`busy` interface.
- **A flush walk** when leaving mode 2 - copying the image back into the
  machine's RAM - so mode 0 could follow mode 2 without a reset.
- **A hold-off after a slot access** (a TransWarp's "slot speed", or a
  Disk II's motor): the core at the bus's pace for a while around a slot's
  I/O. Not asked for. (Word 41, once left for it, now carries ACCEL_TURBO.)
- **The D-side L1**: the same TLB already carries the write view; a 2-clock
  dcache with a small write buffer is the planned next rung, and a 1-clock
  one (LUTRAM or a falling-edge RAM) the rung after. The I side alone
  covers two thirds of all cycles.
- **Any slot's ROM served from the card**: BUS, always, by the rule above.
- **The periodic timestamp record** in the trace (DDR3_USAGE.md): a trace of
  an accelerated machine is not a cycle stream; the host flags it
  (`kFlagAccel`) and the replay tool refuses it, while the MMU check still
  follows the shadow through it.

## The internalized soft switches (2026-08-31)

In the closed regime - mode 2, serving, RAM never exported to the bus -
the soft switches whose whole effect is the card's own shadow stop
riding the bus.  `apple_mmu.q_swi` answers the sequencer's question
beside `q_cls`; the op rides S_FAST as any fast op does (mem_cache
decides it with nothing served), the byte comes from whichever
authority owns the address, and the retirement raises a SYNTHETIC
COMMIT on the unified stream - the one deliberate bend of "fast ops
have a present and no commit" - so the switch shadow, `map_changed`,
the TLB flush and every commit-gated consumer fire exactly as for a
bus op, and the event stream still carries the access to the host.

What internalizes, and what stays on the bus:

- WRITES: 80STORE/RAMRD/RAMWRT/ALTZP/80COL/ALTCHAR ($C000-5/8/9/C-F),
  the video toggles ($C050-$C057), the RamWorks bank ($C071/$C073),
  the language card ($C080-$C08F).  NOT INTCXROM or SLOTC3ROM
  ($C006/7, $C00A/B): four slot cards track those from the bus stream
  (rtl/slot_switches.sv), and they are rare - internalizing them later
  means feeding the unified stream to the trackers.
- READS: the status page $C011-$C01F (bit 7 from the shadow, low bits
  the keyboard latch's, $C019 only with the VBL lock up); the toggles
  and the LC (their byte is the floating bus: fb_sim's prediction,
  gated on `int_ok` - vapor lock keeps working); the keyboard
  $C000-$C00F (below).  $C010 and the $C01x writes are the real
  strobe's and always ride the bus.

THE KEYBOARD.  The driver's dummy cycles park at $C000 instead of
$0000 (`park_kbd` into apple_bus_write), so every idle bus cycle
samples the real IOU - key and strobe - into a latch in
rtl/kbd_inject.sv.  A program's $C00x read is then served on the card
through the same substitution decision a bus read gets (injected key
first, the latch's real byte, the hotkey eaten), with the read-side
bookkeeping applied once at retirement (`int_rd`).  A strobe-clearing
bus op clears the latch's bit 7 as it clears the IOU's, so
$C010-then-$C000 cannot hand a key over twice.  A dummy is a sample,
never a read: none of kbd_inject's read-side state moves on one, and
the sparse filter drops dummy events as it always has, so the link
sees nothing new.

Measured in the boot bench (2M bus cycles, mode 2 unlimited): ProDOS
2.4.3 to Bitsy Bye went from 14.2M to 57.6M retired ops - the idle
keyboard poll runs at ~54 ops per bus cycle where each poll used to be
a bus trip - and Nox's boot from 13.0M to 19.0M.  Bus reads over the
whole ProDOS run fell from ~1.0M to 12.6k.

The lever: ACCEL_CTRL[28] `swint_dis`, `swint = on|off` in the
configuration, `swctl accel swint off` at runtime - dummies park at
$0000 again and every $C0xx access rides the bus as before.

Left for later, deliberately: INTCXROM/SLOTC3ROM writes (above); a
menu hotkey found by the parked dummies themselves, which would let
Ctrl-6 work even in a program that never polls the keyboard; $C019
without the lock; and the machine's own switches go stale in the
closed regime exactly as its RAM does - leaving mode 2 already means a
reset, and this adds nothing to that rule.
