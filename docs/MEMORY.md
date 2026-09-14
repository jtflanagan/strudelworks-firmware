# The machine's memory, on the card

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

> **On branch `page_cache` the 4-way cache, its DDR3 client and the 24-bit
> physical address described below are REPLACED** by the two-bank design of
> docs/PAGE_CACHE.md (`rtl/page_cache.sv`, `rtl/page_client.sv`).  The MMU
> shadow, the ROM, the RamWorks semantics, the divert, the monitor's rules
> and the registers' meanings all carry over and this file remains their
> reference; the cache-mechanics sections are historical here.

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
`$C000-$CFFF`, bank 2 and `$E000-$FFFF` where they sit. Image bank 0 is main
memory, always; image banks 1-255 are the auxiliary memory, one per RamWorks
bank (below). The ROM is not in the image.

## The RamWorks

The card is an Applied Engineering RamWorks III of 255 banks: the auxiliary
memory is not one 64 KB bank but 255 of them, and a write to `$C073` - or
`$C071`, which AppleWin also honours for the earlier extended-memory cards -
names the one every auxiliary access reaches (RAMRD, RAMWRT, ALTZP's zero
page, stack and language card, 80STORE's pages). **Bank 0 is the regular
auxiliary memory** of a 128K IIe - the 80-column firmware's, DHGR's, ProDOS's
`/RAM` - and lives in image bank 1 exactly as it did before; bank *k* is image
bank *k+1*; the 255 banks plus main memory fill the 16 MB. A write of 255, a
bank that does not exist, is ignored and the register keeps its value, as
AppleWin's does for a bank beyond the configured size. The register cannot be
read on the real card; `MEM_CTRL [23:16]` reads the shadow's copy. 16 MB is
the whole of it (`rtl/apple_mmu.sv`, `RW_BANKS`); the host mirrors the same
256 banks (`apple_memory.hpp`).

**The bank register resets on RES', by decision.** The real card's does not
(AppleWin resets it only on a power cycle, GH#1414), so a program that leaves
bank 5 selected and then Ctrl-Resets has the monitor's and the 80-column
firmware's auxiliary memory in bank 5. Nothing reliable depends on that, and a
reset that always lands in bank 0 avoids a whole class of confusion; the
convenience wins, on the card and on the host alike.

**A write to a bank the machine does not have goes out as a read.** The bus
is driven for every cycle and the real IIe has no bank register, so a write to
bank 5's `$2000`, sent out as a write, would land in the machine's one
auxiliary bank over whatever bank 0 put there - and the video scanner reads
that RAM. So the driver **diverts** it (`apple_bus_write.sv`): `apple_mmu` is
asked, of the address about to be presented and in the same clock, whether a
write there reaches auxiliary memory in a bank other than 0 (`q_addr` /
`q_divert`), and if so - and the card is serving - the cycle goes out on the
pins as a READ of the same address: R/W high, the data bus never enabled. A
read of `$0000-$BFFF` or `$D000-$FFFF` has no side effect on a IIe; `$Cxxx`
is BUS class and never diverted, so the bank register's own write and every
soft switch still reach the machine. Everything on the card's side of the
pins still sees the write - `op_rw`, `op_wdata`, `op_commit` are the core's
op, so the shadow and the image apply it - and the reader records the WRITE
in the capture with the core's byte (`apple_bus_read.sv`, `rw_override`), so
the host's mirror follows it too. `MEM_DIVERTED` counts them.

The machine's auxiliary memory is therefore bank 0's alone: a monitor plugged
into the Apple shows the right 80-column and double-hires pages whatever a
RAM disk is doing in bank 7. Two more consequences:

- the RamWorks is real only while the card is **serving**: with serving off
  the core reads the machine's memory, so nothing is diverted and a program
  probing for banks finds one aliased bank, exactly as a IIe without the card;
- the **monitor** compares only image banks 0 and 1 with the bus - banks 2 and
  up are memory the machine does not have, and the bus's byte there is not an
  opinion (`mem_cache.sv`, `p_machine`).

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

> **Removed 2026-09-14 (user decision).** The refresh gate is gone: the patch, the
> `REFRESH_GATE` parameter, `i_refresh_ok` and every `refresh_ok` producer.  It had been
> off since 2026-09-12 (`REFRESH_GATE = 0`) as a suspect in the IIgs bitstreams that
> met timing and never calibrated - it was not the cause, and could not have been (its
> branch needed `final_calibration_done`) - but dead code in the controller was one more
> thing that could perturb the DDR3 logic, and manual refresh no longer buys anything.
> UberDDR3 is now the pinned upstream commit, unpatched; refresh is its own tREFI timer.


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
| `sim/run_mem_cache_tb.sh` | the cache against a tree-PLRU model and a Wishbone stub that acks like the DDR3: every served byte, every hit/miss, every write's byte lane, the late-fill drop, the invalidate, the monitor - and that a RamWorks bank is served and never compared; at 512 and 64 sets |
| `sim/run_mem_ddr3_tb.sh` | the client on the real controller: write-then-fill order, fill latency under pre-emption, refreshes only in the window |
| `sim/run_mem_integ_tb.sh` | the real core running `sim/mem_integ.s` on the whole path against a **128K IIe model with one auxiliary bank on the pins** and a four-bank RamWorks kept as the reference: once serving, the program's bank tests (bank 0 the regular aux memory, banks 1-3 their own, a non-existent bank ignored, ALTZP's zero page per bank) run against memory only the card has - every banked read the reference's byte, every banked write sent out as a read and counted, the machine's auxiliary bank holding bank 0's writes alone at the end, the register cleared by RES': every read the machine's byte (56 K of them), tracking first and then serving under the running program - **31 093 of 31 129 reads answered by the card**, the rest I/O, 52 513 hits to 116 misses, zero mismatches - a DMA through the override path, a reset under it, the image byte-for-byte the machine's memory at the end |
| `sim/run_reg_map_tb.sh` | the registers, end to end from a REG_WRITE |
| the host's `tools/ramworks_test.sh` | the RamWorks on the **real machine** (2026-08-29): a monitor routine writes banks 1-3 and reads them back - `30 30 30` with serving off (one aliased bank, as a IIe without the card), `10 20 30` serving; the bank register reads 2 on the card and in the host's mirror; a Ctrl-Reset clears both |

The first hardware attempt was lost to a rule this repository already
states: a new host→card message type has to be in `rtl/ft601_msg_rx.sv`'s
known list, or the card treats its first use as lost framing and drops the
link. `MEM_ROM` was not, so every session with the ROM file present died at
connect with the host reporting `write failed` - on the previous firmware too,
which is what made it look like the board. The host now names the fault in
its frame line, and the type is in the list. (It happened once more, with
VIDHD_ROM; since then an unknown type is skipped by its length and reported
to the host as an UNKNOWN_TYPE notice rather than dropping the link -
PROTOCOL.md.)

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

- **Every slot's page in `$C100-$CFFF`, every expansion ROM, and `$CFFF`**
  stay the bus. The motherboard's own `$Cxxx` ROM - under INTCXROM, SLOTC3ROM
  and the INTC8ROM latch - is served (the CX class, ACCELERATION.md).
- **The accelerated mode** - now ACCELERATION.md, and built on exactly the
  "one op at a time" this keeps: the sequencer presents the next op only when
  the last is decided (`decided`, `busy`), so the cache needed no bypass and
  no write buffer, and a BUS-class read's rendezvous with the bus is the
  sequencer's merge. Pipelining the cache past ~11x is the follow-on, behind
  the same interface. The motherboard's own `$C100-$CFFF` reads the
  classifier used to leave to the bus are ROM class now - the CX class,
  ACCELERATION.md; every slot's page stays the bus's.
- **INH'.** A card asserting INH' or DMA' is out of scope (DERISK.md, "Two
  memory modes"); serving trusts the image.
