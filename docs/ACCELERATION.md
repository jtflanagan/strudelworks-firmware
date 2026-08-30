# The core faster than the bus

Status: **✅ built and proven in simulation, 2026-08-29; master build closes
(WNS +0.053 ns before the decision was registered, see "Numbers"); not yet
run on hardware.** Branch `acceleration`, both repositories.

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
| the sequencer | `rtl/accel_seq.sv` | owns `cyc_en` and `din`; decides every op; the unified stream; the governor; the counters |
| the driver | `rtl/apple_bus_write.sv` | `bus_owns` / `core_valid` in, dummies out (`op_dummy`), `op_inflight` |
| the class | `rtl/apple_mmu.sv` | the classifier as a function, asked of the core's live op (`q_cls`); the **CX class** and INTC8ROM |
| the cache | `rtl/mem_cache.sv` | `decided` and `busy`, nothing else |
| the stream | `rtl/event_merge.sv`, `rtl/bus_event_filter.sv` | fast-op words (tag `0xC`) merged with the bus's, dummies folded into SKIPs |
| the ROMs | `rtl/hd_card.sv`, `rtl/floppy_card.sv`, `rtl/vidhd_card.sv` | a second read port each, for the CX class |
| the slow zone | `rtl/floppy_card.sv` | `spinning_o`: a drive turning holds the core to the bus's pace |
| the registers | `rtl/wb_regfile.sv` | ACCEL_CTRL, ACCEL_STAT and four counters (PROTOCOL.md) |

## Four kinds of op

| kind | on the pins | the unified stream | the driver's `op_*` |
|---|---|---|---|
| **fast** - a read of RAM, LC or a ROM the card holds; a RAM/LC write in mode 2 | nothing (a dummy may be in flight) | yes | no |
| **bus** - `$Cxxx` the card does not hold; every write in mode 1; everything in mode 0, in a slow zone, or with serving off | driven at T_PRESENT as always | yes | yes |
| **override** - the boot hold's, the disk's DMA, the VBL lock's | driven as always | yes (`u_ovr`) | yes |
| **dummy** - nothing offered at T_PRESENT | a read of `$0000` | **no** | yes, `op_dummy` |

Everything on the memory side - the MMU shadow, the cache, the floating-bus
copy, the hold - watches the **unified stream**: every op in program order,
fast or bus or override, with `op_present` where it was and `op_commit` only
for the ops that had a data phase on the bus. Nothing that acts on a commit
can be a fast op: every soft switch is `$Cxxx`. Every peripheral that decodes
`$Cxxx` or counts bus cycles watches the **driver**, whose ops those always
are, and needed no change: a `$0000` read decodes to nothing in any of them
and `op_commit` still ticks once a cycle, so the Mockingboard's timers and
the floppy's nibbles keep machine time.

## The decision, and merging

The core moves only on `cyc_en`, and the sequencer owns it. Every op the core
puts up is decided **from registers** - the class off the MMU's classifier,
the direction, the override request - the clock after it appears: made in
the same clock it was the longest path in the build (the microcode ROM
through the classifier into the state register, 16 levels, +0.05 ns).

`needs_bus = mode == 0 || class == BUS || (write && mode == 1) || slow || !serving`.
Nothing else sends an op to the bus. An invalidate in progress, or the image
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

## The slow zone

The RWTS reads the floppy's data register on a count of bus cycles - its
seven-cycle `LDA $C0EC,X / BPL` loop reads every nibble exactly once because
the register holds a nibble for seven cycles - and a core that ran ahead
would read the same nibble twice, and writing, land two stores in one
32-cycle slot. Real accelerators drop to 1 MHz on slot 6 for the same
reason. Here the floppy is on the card and says so: while a drive is turning
(`spinning_o`: the motor on, or either drive still coasting - the `motor`
term because the coast count loads a tick after it) every op is a bus op.
ACCEL_CTRL [24] turns that off, for a test.

## The CX class: `$C100-$CFFF` served

Before this every fetch from `$C100-$CFFF` - the internal ROM's `$Cxxx` half,
the slot ROMs, the 80-column firmware ProDOS runs so much of its time in -
was BUS class, and under acceleration every one would have merged. Now,
UTAIIe 5-28 as AppleWin's `Memory.cpp` implements it:

```
read of $C100-$C7FF, page n:  INTCXROM, or n == 3 and SLOTC3ROM clear
                                        -> ROM, from the internal ROM
                              else n the hard disk's, the floppy's or the
                              VidHD's slot, its ROM loaded
                                        -> ROM, from that card's own ROM
                              else (the Mockingboard's VIAs, a physical
                              card, an empty slot)  -> BUS
read of $C800-$CFFE:          INTCXROM or INTC8ROM -> ROM, internal
                              else                 -> BUS
$CFFF, every write, every $C0xx        -> BUS
```

`intc8rom` is the IIe's unreadable latch: set by any access to `$C3xx`
while INTCXROM and SLOTC3ROM are both clear, cleared by any access to `$CFFF`
and by RES′. It is set at `op_present` rather than `op_commit`, because a
`$C3xx` fetch served from the card has no data phase; for one that does the
difference only reaches the *next* op, which cannot be presented before this
one's commit. `MEM_STAT[13]` reads it. A ROM source that is not loaded
classifies as BUS, so "ROM class" always means the card has the byte, and
the cache needs no per-source check. The three slot ROMs are 64×32 LUT RAMs
read combinationally, so a second port each was a mux.

Proven where the old ROM class was: `sim/run_mmu_trace.sh` on the three real
captures compares every ROM-class read with the file - **4.7 M of them on
`apple.bustrace`, 0 mismatches**, half a million more than before, the
`$C100-$CFFF` reads among them. The Mockingboard's page stays BUS: its
`$Cnxx` are VIA registers with read side effects.

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
                            [24] slow_fd (default 1); [31] W1 clear counters
ACCEL_STAT    0x8000_0090   [0] accelerating; [2:1] held {floppy, governor};
                            [3] bus_owns; [7:4] state; [15:8] merge overflows
                            (must be 0); [23:16] fast ops decided twice
ACCEL_FAST    0x8000_0094   fast ops
ACCEL_BUS     0x8000_0098   the core's ops that rode a bus cycle
ACCEL_CYCLES  0x8000_009C   bus cycles while accelerating
ACCEL_WAIT    0x8000_00A0   clocks the core spent waiting to merge
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

**The mismatch monitor counts in mode 2's slow zones.** A RAM read that rides
the bus there - the floppy's - is served from the card and compared with the
machine's stale byte: the count moves, as it must, and only there. In mode 1
the monitor stays meaningful (writes keep the machine coherent).

**Programs that count CPU cycles between floating-bus reads break**,
inherently: the floating bus is real time and the core is not. Every
peripheral on the card keeps machine time, so nothing on the card drifts.

**Under acceleration the memory client's windows are the whole cycle**
(`mem_client.accel`): fills and writes land at any point in the cycle, and
the 30-50 window that used to keep refreshes and ring batches clear of the
next op would only starve the ring. A refresh under a fast op is a stall,
not a wrong answer (DDR3_USAGE.md).

## Numbers

Master build of 2026-08-29 with the decision in the same clock as the core's
ROM: **10 640 LUTs (51 %, +1.6 k)**, 8 334 flops, BRAM unchanged at 35.5 of
50, setup WNS **+0.053 ns** on the path `u_cpu/uc_reg → … → u_seq/st_reg`
(16 levels), hold +0.031 ns. The decision was then registered (one more clock
per fast op) and the build re-run; see the commit for the figures.

In simulation (`sim/run_accel_tb.sh`, the real core on sim/accel.s against
the 128K IIe model): **mode 2 unlimited 10.0x** (32 814 fast + 178 bus ops
over 3 284 cycles), mode 1 7.5x on that read-heavy program, the governor
3.99 at 4.00 and 1.00 at 1.00; 280 K reads, every one the reference's byte;
`late_fills` 0, `fifo_drops` 0, merge overflows 0.

## What proves it

| | what it settles |
|---|---|
| `sim/run_accel_tb.sh` | the real core, driver, reader, sequencer, MMU, ROM, cache, client, arbiter and hold against the 128K IIe model, running `sim/accel.s`: mode 0 bit-exact (no dummy, no fast op, every cyc_en the driver's); modes 1 and 2 unlimited and the governor at 4.0 and 1.0; every read the reference's byte, fast or bus; every dummy the parked read; no BUS-class op served fast; every write on the pins in mode 1 and none in mode 2; consecutive bus ops on consecutive cycles; a DMA of the disk's shape mid-run with its last byte's commit its own; the armed boot hold at the post-reset fetch and a runtime knock at the next SYNC, accelerating; a reset; an invalidate landed on a fast read (decided again, and no RAM read on the bus); the floppy's slow zone; the CX class's every case; swept over the core-to-present margin down to 3 clocks |
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
- **A slot mask for physical cards** (a TransWarp's "slot speed"): a `$C0nx`
  or `$Cnxx` access to a masked slot holding the core to the bus's pace for
  a while. Word 41 of the register map is left for it.
- **A physical card's `$C800` expansion ROM**: BUS, always.
- **The periodic timestamp record** in the trace (DDR3_USAGE.md): a trace of
  an accelerated machine is not a cycle stream; the host flags it
  (`kFlagAccel`) and the replay tool refuses it, while the MMU check still
  follows the shadow through it.
