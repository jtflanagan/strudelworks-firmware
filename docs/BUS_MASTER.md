# Taking the bus: driving the Apple II as its CPU

Status: **⬜ design, nothing built.** This is the timing contract and where the
numbers in it came from, written before any RTL so the numbers are arguable
rather than buried in a module.

The card can already watch the bus (`rtl/apple_bus_read.sv`, closed on hardware,
see DERISK milestone 5) and has a cycle-exact 65C02 that agrees with the real
part on 24.7 M cycles (milestone 6). What is missing is the half in between:
pulling DMA′, driving address, R/W and data on the right edges, and letting the
soft core be the machine's CPU.

## Where the numbers come from

`C:/repos/aty` is a working implementation of exactly this on a different board
and a different FPGA. It is the same board *lineage* — its RTL drives
`tini_addr_dir_pin` / `tini_data_dir_pin` / `tini_oe_pin`, which are the names in
our own `constr/apple_bus.xdc` — so the electrical arrangement is ours and only
the fabric clock differs: **133 MHz there, 100 MHz here.**

Its bus timing lives in `hdl/apple/apple_bus_dmz.sv` as taps off two shift
registers: one clocked by phi0 **falling**, one by phi0 **rising**. Everything
below is those constants, scaled by 100/133 and rounded.

| tap | from | aty @133 | here @100 | what it is |
|---|---|---|---|---|
| `ADDR_BEGIN` | phi0 ↓ | 3 | **2** | start of the bus cycle; present the driven address |
| `ADDR_LATCH` | phi0 ↓ | 16 | **12** | deadline to latch the soft CPU's op for *this* cycle |
| `ADDR_SNAP` | phi0 ↓ | 25 | **20** | sample addr / R/W / control |
| `INH_DEADLINE` | phi0 ↓ | 32 | **24** | last chance to assert INH |
| `DATA_EMIT` | phi0 ↑ | 25 | **19** | earliest the FPGA may drive data |
| `DATA_SNAP` | phi0 ↑ | 59 | **44** | sample data |
| pipe depth | ↓ / ↑ | 40 / 62 | **30 / 47** | |

**Two of those we already knew independently, and they agree.** Our snooper
samples address at +20 from phi0 falling and data at +45 from phi0 rising,
derived empirically against a running machine. aty's equivalents scale to 18.8
and 44.4. Two independent derivations, on different hardware, landing within a
cycle of each other — which is the best evidence available that the scaling is
sound and that the *drive* taps, which we have no independent measurement of,
can be trusted too. Keep our measured 20 and 45; take 2, 12, 24 and 19 from the
scaling.

## The drive discipline

Not symmetric, and the asymmetry is the point.

**Address and R/W are driven continuously** while bus mastering, not windowed.
When there is no access to make, the bus is parked as a **read of $0000** rather
than released — a released address bus mid-mastering is floating inputs on
everything downstream.

**Data is windowed.** It is driven from `DATA_EMIT` (phi0 ↑ +19) and released at
`ADDR_BEGIN` (phi0 ↓ +2) of the next cycle. Only in that window do the data
level shifters turn around.

**DMA′ is a level, not a pulse**: `bus_master_active ? 1'b0 : 1'bz`. Asserting it
is what deactivates the 6502 — the motherboard shuts off the transceivers
connecting the CPU to the bus, so the real CPU is *disconnected*, not out-voted.
That is why contention is not a hazard to tiptoe around here.

**The level shifters follow the enables**: `tini_addr_dir_pin` = the address/RW
enable, `tini_data_dir_pin` = the data enable. Both are currently tied to `1'b0`
in `apple_bus_read.sv`, which is the Apple→FPGA direction.

## Three things aty learned the hard way

Worth taking rather than rediscovering.

**Present the address at a fixed tap, not when it happens to be ready.** The
soft core's next-cycle address is known mid-*current*-cycle, and driving it
immediately makes the presented address flip at a point unanchored to the bus
cycle that samples it. Over long runs that flip lands on the wrong side of a
snap and a `$C0xx` write gets driven for two cycles — doubled — or a fetch is
dropped. So: **latch** the core's op when it settles, **present** it at
`ADDR_BEGIN`. Exactly one stable value per bus cycle.

**We snoop our own driven address, so the drive must beat our own snap.** The
driven address has to get out of the pin, through the level shifter, across the
board and back through the 2-FF synchroniser before `ADDR_SNAP`. aty's latch
deadline has a failure history recorded in its source: 22 raced the snap, and 18
*still* failed on hardware — a `$C007` write snooped back as the parked `$0000`,
so the soft switch never flipped and the machine booted to BASIC. They settled
on 16 of 25, ~9 fclk of margin. Presenting at our tap 2 against a snap at 20
leaves 18 cycles, which is comfortable; the number to watch is the *latch*
deadline, not the present.

**Hold the core's outputs across the whole bus cycle.** The core ticks
mid-bus-cycle and its live outputs immediately become the *next* instruction's.
The driven registers must hold this cycle's address, R/W and write data through
`DATA_SNAP`.

## The driver

**✅ Built.** `rtl/apple_bus_write.sv`, with the taps above as parameters.
Verified against an Apple-shaped phi0 by `sim/run_bus_write_tb.sh`, whose checks
are drawn from the ways this is known to fail rather than from the module's
structure — two of them are aty's bugs written down as assertions:

```
ok: not mastering - address, data and DMA' all released
ok: DMA' is a level, held for the whole session
ok: address and R/W driven continuously, never released
ok: exactly one address change per cycle, over 30 cycles
ok: every change at cycle 3 after phi0 falling; reader samples at 20,
    so 17 cycles of round-trip margin
ok: exactly one cyc_en per phi0 cycle - the core is locked to the bus
ok: data driven only on writes
ok: data released for the address phase
ok: data driven inside the emit window on all 15 write cycles sampled
ok: din is latched from the bus and stable at cyc_en
ok: releasing master_active releases every pin at once
```

**One stage, not two.** aty stages the core's op and presents it later; the
lesson there is *anchoring*, not the number of stages. Because our core is
locked to the bus by `cyc_en` we know exactly when its outputs are valid — about
50 fabric cycles before they are needed — so latching them at the present tap is
already one stable value per bus cycle, anchored to the cycle that carries it.
A separate staging tap on the rising pipe was tried and removed: it left one
fabric cycle before the next falling edge, which is not a margin, it is a
coincidence.

**The reader gained two more outputs**, `phi0_sync` and `data_sync`, for the
same reason as `res_sync`: the driver needs phi0 live to place its taps and the
data byte live to be the core's `din`. Sharing the synchronisers rather than
adding a second set is not only cheaper — two synchronisers on one pin are two
answers to the same question, and they disagree exactly when it matters.

**Data is deliberately still driven for a few cycles after the falling edge**,
until `T_PRESENT` of the next cycle. That is hold time, not a leak.

## The master build

**✅ Built, and it fits.** `build/build.sh --master` → `master_top.bit`.

```
                     snoop      master
  setup WNS       +0.216 ns   +0.065 ns
  hold  WHS       +0.070 ns   +0.101 ns
  Slice LUTs                      1300  (6.3%)
  Slice Registers                 1433  (3.4%)
  Block RAM                         10  (20%)
  Bonded IOB                        91  (53%)
  IOBUFs               32            58
```

The 26 extra IOBUFs are exactly the pins that became bidirectional: 16 address,
8 data, R/W and DMA′.

**The tight path is not ours.** The master's 0.065 ns is `ft_txe` into the FT601
controller, in the `ft_clk` domain — the same interface DERISK records as having
been carefully constrained, now under more placement pressure from a bigger
design. The soft CPU's own worst path, its microcode ROM into the new
`last_addr` register, has **0.89 ns** of slack. If the FT601 path ever needs
winning back, that is where to look and it has nothing to do with mastering.

**The tops were split rather than duplicated.** `card_link.sv` is the card minus
the Apple — link, messages, capture, registers, UART — and both tops instantiate
it. The alternative was a second copy of five hundred lines of link plumbing,
where a bug fixed in one copy is a bug still shipped in the other. What is left
in each top is only what differs:

| | `snoop_top` | `master_top` |
|---|---|---|
| Apple pins | `input` | `inout` |
| `CAN_MASTER` | 0 | 1 |
| level shifters | tied Apple→FPGA | follow the drive enables |
| behind them | nothing | `apple_bus_write` + `cpu65c02` |

`apple_bus_read` is in **both**, unchanged and driving nothing, so every cycle
the master drives is captured and shipped on the path already closed on
hardware. A driven cycle can be checked against a capture rather than inferred,
and `sim/run_trace_replay.sh` already knows how to read the result.

The shifter control moved out of the reader into the tops, because their
direction is exactly what differs between watching and driving — and the reader,
having no way to drive either way, has no opinion.

**The core is reset with the machine**: `cpu_rst = card reset || RES′ asserted`.
So the //e being reset resets the soft core too, and it comes out running its own
seven-cycle reset sequence, fetching `$FFFC`/`$FFFD` from the machine's own ROM
over the bus it is driving.

## What changes here

✅ Done as planned: `rtl/apple_bus_read.sv` is input-only in both builds, driving
lives in `rtl/apple_bus_write.sv`, and the Apple pins are `inout` only in
`master_top`.

We already have every pin: `apple_dma_pin`, `tini_addr_dir_pin`,
`tini_data_dir_pin`, `tini_oe_pin` are all in `constr/apple_bus.xdc`. Note the
card brings out DMA′ but **not** the DMA daisy-chain pins, so single-card
mastering is fine and priority arbitration against another DMA card is not
expressible.

## The changeover, and why a reset owns it

**✅ Built.** `CPU_SOURCE`, at `0x8000_0008` in `rtl/wb_regfile.sv`:

```
[0]      desired   RW   0 = the native 6502 (default), 1 = the soft core
[8]      active    RO   what was latched at the last RES' assertion
[16]     capable   RO   this bitstream can actually master the bus
[31:24]  latches   RO   RES' assertions seen, wrapping
```

**Writing it does not hand over the bus.** The write sets an intention; the
falling edge of RES′ is what acts on it. There is no good moment to take the bus
from a running machine — the real CPU is mid-instruction, the soft core is not
where the real one was, and whatever mess the DMA′ transition makes lands in
software's lap. A reset has no such lap: the motherboard holds RESET far longer
than the changeover takes, and everything after it starts from the vector, so a
switch made anywhere inside that window is invisible by construction.

The **edge**, not the level, so it is exactly one changeover per reset however
long the line is held — and however much it bounces, which it does, being a
switch with nothing debouncing it.

`latches` is what lets the host tell "not reset yet" from "reset and ignored":
write `desired`, read back, and if the count has not moved then `active` is
still answering about the previous reset.

`capable` is 0 in `snoop_top`, and the register **refuses to latch itself into
mastering** when it is. The instrument carries the register so the host can read
it uniformly across builds, and cannot lie about being the machine's CPU.

Host side: `swhost --cpu native|soft` writes it, and the banner reports it —
including saying plainly when the bitstream cannot master, rather than leaving
someone to wonder why a write had no effect.

Covered by `sim/run_reg_map_tb.sh`, end to end from a REG_WRITE message: that a
write alone does **not** hand over, that a reset does, that every field reads
back, and that a held-low RES′ latches once rather than once per cycle.

## ✅ It works

The card is the Apple II's CPU. Second attempt, `master_top` at commit `ff1a6e3`:

```
16.44 s captured, 0 gaps
free-running for 8.23 s after the last RES' release

write-then-read-back by region
  $0000-$0FFF   matched   153544   differed        0
  $C000-$CFFF   matched   371661   differed    36429

mismatches outside the I/O page: 0
writes to the text screen: 3603
```

**Every RAM write reads back.** The 36,429 differences are all in `$C000-$CFFF`,
where a write and a read are different operations by definition — soft switches
and I/O registers, not failures. The machine boots, runs, and draws.

*The first attempt failed, and the failure is the useful part.* The handover
itself worked on the first try: DMA′ pulled, seven-cycle reset, the vector out of
the Apple's own ROM, and the monitor executing correctly — `CLD`, `JSR $FE84`,
`LDY #$FF`, `STY $32`. It came apart at the first `RTS`, pulling `$A0`/`$A0`
where it had pushed `$FA`/`$65` six cycles earlier. 6740 of 6855 write-then-read
pairs did not read back, while every read was perfect.

The cause was `T_EMIT`, and **not** the scaling — aty's 195 ns scaled to 200 ns
here, faithfully. The number was right for a different question. In aty the card
impersonates **memory**, driving a byte the CPU samples at the *end* of the
cycle, and its own soft CPU writes into shadow RAM behind INH, so that tap had
never been asked to be a CPU write. A CPU must hold its write data across its
whole active phase. `T_EMIT` 19 → 2.

Early, but deliberately not from `T_PRESENT`: the data bus belongs to the video
circuitry while phi0 is low — that is what makes the floating bus return screen
data — so driving from the present tap would put us against the machine's own RAM
output for half of every cycle. Just after the rising edge stays inside the CPU's
half.

**The lesson worth keeping**: a scaled constant carries its units but not its
meaning. Both taps were 200 ns and only one of them was an answer to our
question.

## Open

- ✅ **A master trace had no SYNC**, and now records the core's own instead.
  `m2sel` is the real 6502's SYNC line and asserting DMA′ disconnects that chip,
  so it read zero for all 16,777,208 cycles of the first master capture —
  leaving an undecodable trace, since an opcode fetch and an operand read look
  identical without it.

  `apple_bus_write` latches the core's SYNC with the rest of its op and
  `apple_bus_read` records that instead, in a master build only. The bit is then
  **logically exact and electrically absent**: it is the same signal the core
  will drive onto the real SYNC line once the card sits in the **CPU socket**
  rather than a slot, arriving by a shorter route because the slot has nowhere
  to carry it. Not a guess, and not a measurement.

  The distinction is still recorded, because everything else in the word was
  measured on the wire: the host sets `kFlagSyncSynth` in the trace header and
  `run_trace_replay.sh` says so in its banner. When the socket build arrives the
  same bit becomes a genuine measurement and the flag simply stops being set.


- ✅ **`cyc_en` is one pulse per phi0** — done, in the driver, and checked.
- ✅ **Changeover** — done, see below.
- ⬜ **The setup and hold the machine expects from a driver** are still not
  measured. The taps above say *when aty drives*, which is strong evidence but
  is not the same as the datasheet figure, and it is not recoverable from a
  capture of someone else driving.
- ⬜ **What INH is for here.** aty uses it to override reads from its own
  shadow memory; whether we need it at all depends on the memory mode.
