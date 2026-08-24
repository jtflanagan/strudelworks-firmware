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

## What changes here

`rtl/apple_bus_read.sv` **stays input-only.** The instrument must not become a
participant — that is what makes a driven cycle checkable against a capture
rather than inferred. Driving goes in a new `rtl/apple_bus_write.sv`, and the
Apple pins become `inout` only in a master top, never in `--snoop`.

We already have every pin: `apple_dma_pin`, `tini_addr_dir_pin`,
`tini_data_dir_pin`, `tini_oe_pin` are all in `constr/apple_bus.xdc`. Note the
card brings out DMA′ but **not** the DMA daisy-chain pins, so single-card
mastering is fine and priority arbitration against another DMA card is not
expressible.

## Open

- ⬜ **The soft CPU's `cyc_en` becomes one pulse per phi0**, which is the
  interface `rtl/cpu65c02.sv` was built for and has never been driven with.
- ⬜ **Changeover is atomic across a reset in aty** — the CPU source is latched
  once, at RES′ assert, never mid-run. Whether we want the same rule or can
  hand over live is undecided, and it is the question with the most ways to be
  wrong.
- ⬜ **The setup and hold the machine expects from a driver** are still not
  measured. The taps above say *when aty drives*, which is strong evidence but
  is not the same as the datasheet figure, and it is not recoverable from a
  capture of someone else driving.
- ⬜ **What INH is for here.** aty uses it to override reads from its own
  shadow memory; whether we need it at all depends on the memory mode.
