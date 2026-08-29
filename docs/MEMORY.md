# The machine's memory, on the card

Status: **✅ built and proven in simulation, 2026-08-28; master build of 20:21
(WNS +0.212 ns, WHS +0.036 ns, 31 of 50 BRAM tiles); not yet run on hardware.**

The card keeps its own copy of the Apple's memory and answers the soft core's
reads from it. The bus does not change: every cycle is still driven, every
write still reaches the machine's RAM (the video scanner reads it), and every
read still puts the machine's byte on the bus - the card simply hands the core
a byte of its own instead, through the same `din_sub` route the keyboard
injection uses, so the capture records what the core actually read. This is
the groundwork for running the core faster than the bus, and it is what lets
the card be memory the machine does not have.

## What is where

```
  op_addr/op_rw/op_wdata ─► apple_mmu ──► mem_cache ◄──► mem_client ──► wb_arb ──► DDR3 bank 0
  (apple_bus_write)          │ class,      │  4-way,      (card_link)   priority
                             │ physical    │  32 KB                      slot
                             │ address     │
                             └──────────► apple_rom (16 KB BRAM) ─► sub_en / sub_data ─► cpu_din
```

| piece | file | what it holds |
|---|---|---|
| the IIe's memory map | `rtl/apple_mmu.sv` | the soft switches, shadowed; every op classified BUS / RAM / LC / ROM with a physical address |
| the ROM | `rtl/apple_rom.sv` | $C000-$FFFF, 16 KB, host-loaded (`MEM_ROM`), 4 RAMB36, always a hit |
| the cache | `rtl/mem_cache.sv`, `rtl/cache_way_ram.sv` | 4 ways × 512 sets × 16 bytes, tree PLRU, write-through, 9 RAMB36 |
| the DDR3 side | `rtl/mem_client.sv` | one in-order queue, the refresh window, bank 0 |
| the port | `rtl/wb_arb.sv` | the strict-priority slot above the ring's rotation, pre-emptive |
| the registers | `rtl/wb_regfile.sv` | `MEM_CTRL`, `MEM_STAT`, the counters (PROTOCOL.md) |

**The image** is DDR3 bank 0 - `{L[19:7], 3'b000, L[6:0]}` for line `L`, 2 KB
of every 16 KB, a 16 MB image - laid out as emulators lay it out: 64 KB per
bank, `$0000-$BFFF` RAM, the language card's bank 1 of `$D000` folded into
`$C000-$CFFF`, bank 2 and `$E000-$FFFF` where they sit. Bank 0 is main memory,
bank 1 auxiliary; the eight bank bits leave room for a RamWorks-style card
when the image grows. The ROM is not in the image.

## Decisions, and why

**Unwritten memory is unknown.** Nothing tracks which bytes have been written
since power-up; a read of one returns whatever the DDR3 holds, exactly as a
powered-up Apple returns whatever its RAM holds, and programs are written for
that. The alternative - a known flag per byte, learned from the bus - was
designed and costed (it rides free in the block RAMs' parity bits, and would
have let the ROM learn itself) and set aside: the ROM is small enough to hold
outright, and the flag plane is a complication the acceleration work does not
need. The consequence is that the monitor below cannot tell a wrong byte from
an unwritten one; the number to watch is whether it *plateaus*.

**The ROM has its own block RAM.** 16 KB, four tiles, host-loaded like the
Disk II's boot ROM. Held in the image it would compete with the program's own
lines for a 32 KB cache - the monitor, BASIC and every ProDOS call live there -
and cost a DDR3 burst on every miss. Held here it is always a hit at a fixed
two clocks. The host vendors `assets/Apple2e_Enhanced.rom` (its NOTICE has the
argument); `sim/run_mmu_trace.sh` proves the file is this machine's ROM.

**Write-through, never dirty.** A write updates the line if it is present and
always goes to the DDR3 (byte enables make a one-byte burst free). So a miss
is exactly one read burst, an eviction costs nothing, and there is no
write-back to land in front of a fill and eat 40 ns of turnaround. At Apple
speed a write is done a dozen clocks into its cycle. A write buffer, for the
day the core runs faster, goes in `mem_client`'s queue.

**Refresh from the cycle's position, not from hit prediction.** The refresh
gate (DERISK.md, milestone 2) pulls a refresh in when `refresh_ok` is high.
At Apple speed the card's memory work is done by clock ~25 of a ~98-clock bus
cycle and nothing can arrive before the next `op_present`, so `mem_client`
raises `refresh_ok` when it is idle and the cycle is between clocks 30 and 60:
the ~23-clock refresh is over before the next cycle can need the memory. No
prediction of hits is needed. It would be, on a IIgs at 2.8 MHz, and the
predicate has a place for one. The `tREFI` timer stays as the backstop that
cannot starve.

**The priority slot pre-empts.** The memory client does not wait for a ring
batch to end: the clock after it asks, the port is its and the rotation's
holder is stalled where it stands - a stalled `stb` is the pipelined-Wishbone
way of saying "not yet", nothing is cancelled, `cyc` stays the OR of everyone's
so no ack is aborted. What a fill can still queue behind is a burst the
controller has already accepted plus a turnaround: ~8 clocks, not a batch.
The ring's batches are 32 lines so one begun inside the client's window
(`rot_ok`, clocks 30-50) is over before the next cycle.

**Serve bits are levels, safe under a running machine.** With a class's bit
clear the core takes the bus's byte exactly as it did before this existed;
with it set the cache was already tracking every write. So bring-up goes one
class at a time under a running program, and the registers never wait for a
reset.

**Nothing clears the image.** Not power-up, not a card reset, not RES': the
DDR3 holds what it held, as the machine's RAM does, and unwritten memory is
garbage by decision. (A clear walk was built and torn out: it held the
arbiter's priority slot for its length and bought nothing.)

**RES' resets the switches and nothing else.** The shadow goes back to the
IIe's reset state (bank 2, ROM read, RAM write-enabled, every auxiliary switch
off) and is held there while RES' is low; the image and the cache survive it,
like RAM.

**Overrides are ops.** The hard disk's DMA writes RAM through the override
path; the VBL lock flips `$C000`/`$C004` through it; the machine's own MMU sees
those cycles on the bus like any other, so the shadow and the image follow
every op, `op_ovr` or not.

**A 64K machine becomes 128K from the core's point of view** once the
auxiliary class is served, video excepted: RAMRD/RAMWRT/ALTZP reach the image
whether or not there is a card in the auxiliary slot. Intended - this is the
expanded-memory path - and worth knowing when a program probes for memory it
should not find.

## What the monitor is, and what its number means

Every cacheable read is compared, at the data phase, with the byte the bus
carried: the served byte or the byte that would have been served. `MEM_MISMATCH`
counts the disagreements and `MEM_LAST` names the last one. It runs in every
mode, serving or not. Because unwritten memory is garbage by decision, the
count climbs while a program reads memory nobody has written - and stops once the working set has been written. A count that
keeps climbing under a steady program is the signal; a count that plateaus is
the expected shape.

Two counters must read zero on hardware, always: `late_fills` (a fill that
landed after the next op had been presented - dropped, never applied to the
wrong cycle) and `fifo_drops` (a request the DDR3 client could not take).
Either being non-zero is a bug report.

## Numbers

Out of context, `build/synth_ooc.sh`: the cache 444 LUTs, 628 flops, 9 RAMB36,
+4.4 ns at 100 MHz; the ROM 4 RAMB36. In the master build: **+906 LUTs
(8626 of 20800, 41 %), +1064 flops, +13 tiles (31 of 50)**, setup WNS
**+0.212 ns** (was +0.321; the worst path is still the controller's own reset
fanout, not anything here), hold **+0.036 ns**.

On the real UberDDR3 and the Micron model (`sim/run_mem_ddr3_tb.sh`): 450
fills, **mean 11 clocks from request to line, 16 at worst**, every one while
ring batches were being pre-empted underneath; 241 refreshes, **every one
inside the cycle's idle tail**; the ring's stream word-exact throughout.

## What proves it

| | what it settles |
|---|---|
| `sim/run_mmu_trace.sh sim/trace_work/apple.bustrace` | the shadow against a **real IIe**: every read the shadow classifies as memory whose byte has been written must equal the traced byte; every status read (`$C011-$C01D`) must equal the shadow; every ROM read must equal the vendored file. Three captures, **67 M cycles, zero disagreements** over 31 M RAM reads, 94 K language-card reads and 4.2 M ROM reads. This is where the real unknown lived, and it ran before any DDR3 or board was involved. |
| `sim/run_mem_cache_tb.sh` | the cache against a tree-PLRU model and a Wishbone stub that acks like the DDR3: every served byte, every hit/miss, every write's byte lane, the late-fill drop, the invalidate, the monitor; at 512 and 64 sets |
| `sim/run_mem_ddr3_tb.sh` | the client on the real controller: write-then-fill order, fill latency under pre-emption, refreshes only in the window |
| `sim/run_mem_integ_tb.sh` | the real core running `sim/mem_integ.s` on the whole path against a 128K IIe model with a language card: every read the machine's byte (56 K of them), tracking first and then serving under the running program - **31 093 of 31 129 reads answered by the card**, the rest I/O, 52 513 hits to 116 misses, zero mismatches - a DMA through the override path, a reset under it, the image byte-for-byte the machine's memory at the end |
| `sim/run_reg_map_tb.sh` | the registers, end to end from a REG_WRITE |

The trace check is the one to rerun with a new capture: a ProDOS or Total
Replay session exercises the language card far more than the monitor's boot
does, and the check needs no hardware but the capture.

## The bring-up ladder, on hardware

1. `swhost --cpu soft --mem off` through a long ProDOS / Total Replay session:
   `late_fills` and `fifo_drops` stay 0, hits climb, mismatches plateau.
2. `--mem ram`. 3. `--mem ram,lc`. 4. `--mem all`. At each rung the mismatch
   counter keeps running and `MEM_LAST` names the first bad byte. The control
   socket's `status` carries the counters (`mem=`, `mhits=`, `mmismatch=`, ...).

## Not here, deliberately

- **`$C100-$CFFF`** stays the bus - the internal ROM, INTCXROM/SLOTC3ROM, the
  `$C800` expansion-ROM select and `$CFFF`. The two switches are tracked and the
  ROM holds all 16 KB, so a CX class is a classifier change when something
  needs it.
- **The accelerated mode.** One op at a time is what makes this simple; a core
  running a cycle per clock needs a write-then-read bypass on the ways and the
  tag word, a write buffer, and a rendezvous with the bus for BUS-class reads.
  The cache's hit path is registered at every stage so that work starts from
  here rather than from a rewrite.
- **Expanded memory** beyond 128 KB: the image has the room and the classifier
  has the bank bits; a RamWorks bank register is a shadow-and-classifier change.
- **INH'.** A card asserting INH' or DMA' is out of scope (DERISK.md, "Two
  memory modes"); serving trusts the image.
