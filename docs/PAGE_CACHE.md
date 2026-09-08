# The page cache: the image in BRAM, DDR3 demoted to RamWorks

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

Status: **built in RTL and proven in simulation, 2026-08-31; branch
`page_cache`, taken from master (`cdcfec3`) — before any of the acceleration
branch's work. Not yet on hardware.**

The implementation: `rtl/page_cache.sv` (the banks, the tags, the serve
pipeline, the page engine), `rtl/bank_ram.sv`, `rtl/page_client.sv`
(replacing `mem_cache.sv`, `cache_way_ram.sv`, `mem_client.sv`), and
`rtl/apple_mmu.sv` reshaped to `{cl_aux, cl_bank, cl_off}` + `pf_off`.  What
proves it: `sim/run_page_cache_tb.sh` (19 checks — DDR3 silent under 128K
traffic, the 3-clock serve, the RamWorks round trip, the busy-engine guards);
`sim/run_mem_ddr3_tb.sh` on the real UberDDR3 + Micron model (critical line
**mean 11 clocks, max 15**; whole fill+flush transaction **max 53 clocks**;
refreshes all in the idle tail; ring word-exact beneath); and
`sim/run_mem_integ_tb.sh` under the real 65C02 (20 checks, every read the
machine's byte, image equal to the reference through serving and reset).
Out-of-context synthesis: **32 RAMB36, WNS +3.41 ns at 100 MHz**, 1596 LUTs,
963 flops.  One deliberate deviation from the design text below: the engine
runs snapshot → fill → flush in SERIES (the snapshot's 17 clocks sit ahead of
the critical read, serving it at ~30 clocks instead of ~12 against a
~91-clock deadline) — the overlap remains an optimization for a faster
regime.  §"The floating bus reads the main bank" was implemented too — the
side copy deleted, `rtl/fb_sim.sv` on the main bank's port B alternating
with the peek, 4.5 tiles returned — and **reversed on branch `cxxx_work`
(2026-09-03)** once the 100T lifted the limit: the copy is back, fed by
the main bank's write tap (`mw_stb/mw_addr/mw_byte`), and port B is tied
off.  docs/FLOATING_BUS.md has the why.

**The full build FITS the XC7A35T**, by one last move: the banks put the
design two tiles over (48 RAMB36 + 8 RAMB18 = 104 RAMB18-sites against the
part's 100 — the banks 32 tiles, the Apple ROM 4, the link FIFOs 5, the
ring's staging 4, the microcode 3, the floppy banks 4, nothing padding), and
the 65C02's microcode closed the gap: it is a CONSTANT, so
`rom_style = "distributed"` lets Vivado logic-optimize its 104 Kbits into
**+257 LUTs against 3 RAMB36 freed** (measured out of context; the same
treatment of the host-loaded Apple ROM would have cost 3,564).  The routed
master build: **45 RAMB36 + 8 RAMB18, 49 of 50 tiles; setup WNS +0.741 ns,
hold WHS +0.009 ns; bitstream written** — a hardware-testable bit on the
current part, with the larger board on order still the comfortable home.
A second reclaim followed on the same reasoning as the banks themselves:
the floppy's two per-drive track buffers became ONE shared buffer (only one
drive is ever live; a drive switch flushes-and-refetches like a head
movement — docs/FLOPPY.md), returning 4 RAMB18.  Synthesis spent the slack
at once and well: the capture FIFO, which had been silently spilled to
1.4K LUTs of distributed RAM when block RAM was oversubscribed, went back
into the 2 RAMB36 it belongs in.  The build after both reclaims:
**47 RAMB36 + 4 RAMB18 (49 of 50 tiles), 10,263 LUTs (49%), setup WNS
+0.525 ns, hold WHS +0.058 ns** — the same one-tile margin, ~1.9K LUTs
returned, and a healthier hold than the microcode-only build's +0.009.

The memory image as built (docs/MEMORY.md) keeps a 32 KB 4-way write-through
cache in front of DDR3 bank 0. It works, and it is proven on hardware — but
it barely earns its keep on latency. A hit costs six clocks of pipeline after
a clock of classification (`rtl/mem_cache.sv:49-66`), nine clocks end to end;
a raw DDR3 read costs 10-12 (docs/DERISK.md, measured 108-110 ns on
hardware). The cache saves roughly a DDR3 access's worth of clocks per hit —
and streaming data walks straight through 32 KB of write-through storage, so
much of the traffic misses anyway. The serialization is the cost: classify,
then address the tags, then read the ways or fall back to DDR3, then install
the line and rewrite the tag word.

This design replaces that shape with one that has almost no moving parts at
1 MHz, at the price of block RAM:

- **The cache is the address space.** Two 64 KB banks of BRAM, each addressed
  one-to-one by the 16-bit bus address. Nothing is set-associative, nothing
  is a victim of anything at the same address in a different region.
- **The main bank has no tags at all.** Main memory lives in BRAM,
  permanently, authoritatively. It cannot miss, it never evicts, it never
  flushes.
- **The aux bank has one tag per 256-byte page** — which RamWorks bank is
  resident — and misses only when RamWorks banking is actually in use. A
  128K machine that never touches `$C071/$C073` never misses either, and
  **the image never touches DDR3 at all**.
- **The classifier is unchanged, and off the critical path.** Because the
  BRAM address is just the bus address, classification no longer gates the
  fetch — it runs beside it and checks the verdict a clock later.
- **Writes are write-back**, one dirty bit per aux page, flushed as a whole
  page when the page is evicted. DDR3 write traffic in the steady state is
  zero.

DDR3's role in the image shrinks to one thing: backing the RamWorks banks
that are not resident. It keeps the TX ring (bank 7) and its measured
latencies; the image simply stops needing it in the common case.

## What is where

```
  op_addr/op_rw/op_wdata ──┬─► main bank   64 KB BRAM, tagless ──┐
  (apple_bus_write)        ├─► aux bank    64 KB BRAM ◄── tags ──┼─► sub_en/sub_data
                           │               (256 × {bank,v,d})    │
                           ├─► apple_mmu   classify, in parallel ┘
                           │               (selects the bank, checks the tag)
                           └─► apple_rom   16 KB BRAM, beside, unchanged

  aux bank ◄──► page engine ◄──► wb_arb priority slot ──► DDR3: aux bank 0,
                (fill + flush,                                  RamWorks 1-254
                 pipelined beats)
```

## The classifier, unchanged and out of the way

The old pipeline had to classify first because the classification chose the
cache address (the 24-bit physical address picked the set and the tag). Here
the cache address **is** the bus address, so the data BRAMs, the aux tag
store, and the classifier all evaluate in the same clock, in parallel, and
register their answers. The next clock there is exactly one decision: the
classifier's main/aux bit selects which bank's byte to serve, and on the aux
side one compare — wanted RamWorks bank against the page's resident tag —
says whether the byte in hand is the right one. The optimistic assumption is
that it is; when it isn't, the fetch already done is discarded and the miss
path below runs.

The classification function itself is the one already proven: the same
region decode and switch reads as `rtl/apple_mmu.sv` (RAMRD/RAMWRT
asymmetry, 80STORE's text and hi-res pages, ALTZP's zero page, stack and
language card, the LC bank 1 `$D000` fold into `$C000-$CFFF`
(`apple_mmu.sv:279`), ROM against LC RAM in the high region). It computes a
wanted page identity — main/aux, the aux bank number, the fold, the rom flag
— instead of a full 24-bit physical address, but it is the same logic making
the same distinctions, and it keeps handling every case the old classifier
handled. `$C000-$C0FF` stays BUS, always; ROM reads stay served by
`rtl/apple_rom.sv` beside the cache, exactly as before.

If the function's depth ever misses timing feeding the compare register,
there is a fallback: precompute the per-page answers into a 256-entry
register vector, bulk-updated in one clock whenever a soft switch moves.
It is not the baseline — at 100 MHz, a few LUT levels off registered switch
flops into a register is not a path worth pre-solving.

**The `rw_bank + 1` adder dies** (`apple_mmu.sv:276`). It existed because
image bank 0 was main memory, so aux bank *k* had to live at image bank
*k+1*. With main in its own BRAM bank, DDR3's aux region starts at zero:
RamWorks bank 0 — the regular auxiliary memory of a 128K machine — is DDR3
aux bank 0, and banks 1-254 follow. The register is stored as written,
compared as stored; the divert predicate stays `rw_bank != 0`. One decision
to record when the host side is touched: the mirror and the protocol speak
"image bank = RamWorks bank + 1" today, and can either keep that convention
at the boundary or follow the new layout. The card does not care; pick one
and write it down.

## The two banks

**Main: 64 KB, tagless, authoritative.** The LC fold makes a bank of the
image exactly 64 KB — `$0000-$BFFF`, LC bank 1's `$D000` in the
`$C000-$CFFF` hole, bank 2 and `$E000-$FFFF` where they sit — so one BRAM
bank holds all of main with nothing left over. It is not a cache of main
memory; it **is** main memory, the way the acceleration branch's zp/stack
store was pages 0 and 1, generalized to the whole bank. DDR3 holds no copy.
Every card-side reader of main — the host's peek and memdump serving, the
monitor's compare — reads this BRAM.

**Aux: 64 KB, one tag per page.** 256 pages of 256 bytes; the tag store is
256 entries of about ten bits — resident bank id, valid, dirty — in
asynchronous-read LUTRAM, readable in the address-setup clock alongside the
data fetch. On a machine that never writes the bank register, the resident
bank is 0 everywhere, forever, and the aux bank behaves exactly like the
main one. When RamWorks banking is live, a page whose resident bank is not
the wanted bank is a miss, and pages migrate one at a time, on demand.

**Storage: 2 × 4096 × 128, 32 RAMB36.** Against this, the floating-bus side
copy — 4 RAMB36 + 1 RAMB18, 4.5 tiles (docs/FLOATING_BUS.md) — is deleted
outright (below), and `mem_cache`'s 9 RAMB36 go away, for a net of about
+18.5 tiles over master's 35.5 of 50. That does not fit the XC7A35T with
room to breathe. **The design targets the larger board already on order**;
until it arrives, the aux bank can be parameterized down (fewer resident
pages, same machinery) if a small-part build is wanted.

## Reads and writes

A read: address the banks, the tags and the classifier at `op_present`;
register; select and compare; serve. Two to three clocks from `op_present`
against six today, and the main side cannot miss at all.

A write: write the byte into the selected bank's BRAM. An aux write sets its
page's dirty bit. That is the whole write path — no DDR3 write, no
write-through queue, nothing to order against a later fill. Main-bank writes
set nothing, because main never flushes.

**One dirty bit per page, not sixteen per line, by decision.** The Wishbone
burst is incrementally addressed; flushing only dirty lines would fragment
one clean 16-beat burst into several short ones, each paying its own command
latency, to save writes that cost one clock each in the stream. If a page is
dirty at all, the whole page goes.

## The miss: fill and buffer-swap flush

On an aux tag mismatch:

1. **Issue the critical line's DDR3 read immediately** — the 16-byte beat
   containing the requested byte.
2. **Snapshot the victim page** — all sixteen lines — out of BRAM into a
   256-byte flush buffer, one line per clock, entirely hidden under the
   DDR3 read's ~11-clock latency. Always snapshot; whether it is written
   back is the dirty bit's business.
3. **Fill the page critical-line-first**, wrapping: sixteen pipelined beats,
   all in one DDR3 row, so every beat after the first is a page hit
   streaming at about one per clock. The critical byte is served the moment
   its beat lands.
4. **If the victim was dirty, drain the buffer**: one incrementally-addressed
   16-beat write burst to the old page's lines, after the fill. The
   turnaround the critical path sees is read-after-read; the write turnaround
   happens after the answer is already delivered.

The old and new pages are different rows of the same DDR3 bank (the image
mapping pins the bank bits — `rtl/mem_client.sv` header), so the flush pays
one precharge/activate; it is off the deadline and does not matter at 1 MHz.
For later, faster regimes there is a free trick waiting: spread the aux bank
bits across DDR3 banks so the evict row opens while the fill row streams.
Noted, not taken.

**The page engine must issue beats pipelined.** UberDDR3's Wishbone is
stall-based and pipelined; `mem_client` as built is deliberately
one-op-at-a-time (its header says so — the depth was "for the day the core
runs faster"). That day is this design: sixteen serialized round trips at
~11 clocks each is ~176 clocks and blows the cycle. The fill and flush
engines keep strobes asserted back-to-back behind the stall signal. This is
a hard requirement of the design, not an optimization.

## The 1 MHz budget

All numbers in 100 MHz fabric clocks (10 ns), from the measured tables in
docs/DERISK.md and the constants in `rtl/apple_bus_write.sv:129-132`.

**The deadline.** The op is presented at `T_PRESENT` = phi0-fall + 2. The
core's byte is latched at `T_DIN` = phi0-rise + 44, and the low half of the
~98-clock cycle is ~49 clocks: the budget from `op_present` to the latch is
about **91 clocks**.

**The critical read.** Typical 11 clocks request-to-line through the real
controller (hardware: 10.8-11.0 cy). Worst is a refresh collision at ~37
clocks / 370 ns with the real part's 160 ns tRFC — and the refresh gate
already steers refreshes into the cycle's idle window (`mem_client`,
PH_REF 30-60), so at 1 MHz even that collision is engineered away rather
than merely tolerated. Either way: tens of clocks of margin against a
91-clock deadline. **No manual refresh scheme is needed**, as suspected.

**The whole transaction**, dirty victim, worst shape:

| phase | clocks |
|---|--:|
| critical-line read (includes activate) | ~11 |
| fifteen more fill beats, page hits, pipelined | ~15 |
| turnaround + row switch for the flush | ~5 |
| sixteen flush beats, page hits | ~17 |
| **total** | **~48 typical, ~75 with a refresh collision** |

Both inside one bus cycle, and the served byte left at clock ~11-15. So
even the pathological program — one that switches RamWorks banks and
touches a dirty page every single cycle — meets realtime with the engine
idle again before the next `op_present`. There is no cycle pattern at
1 MHz that gets behind.

The case that made the old design thrash is gone by construction: AUXMOVE
and double-hires alternate main and aux at the same addresses, which under
one direct-mapped space would be an eviction per access — with two banks it
is not even interesting. Misses exist only while RamWorks banking is live.
(The 2.8 MHz GS and the accelerated core are explicitly out of scope here;
the budget above is the 1 MHz argument only.)

## The floating bus reads the main bank

> **Reversed 2026-09-03 (branch `cxxx_work`).** The side copy is back in
> `rtl/fb_sim.sv`, written from a tap on the main bank's port A write
> (`mw_stb`, `mw_addr`, `mw_byte`: the strobe, address and byte on the
> clock the bank takes them), and the main bank's port B is idle.  The
> reason is the last paragraph below, answered: under acceleration writes
> land on arbitrary clocks, the shared port gave the scanner every other
> clock, and a cycle-correct byte wants a port of its own.  The section is
> kept as the record of the small-part design.

The floating-bus simulator keeps its own 18 KB side copy of the text and
hi-res pages because the authoritative image was in DDR3, behind a cache,
with no latency guarantee. The main bank removes the reason: the scanner's
predicted address can be read straight out of the authoritative BRAM.

The sharing is **cooperative, fixed slots in the phi0 frame — not an
arbiter, and not dual-port luck**. Everything that touches the main bank
already happens at known clocks of the ~98-clock cycle: the op's fetch just
after `op_present`, the committed write just after `T_DIN`. The scanner
needs one read per bus cycle, at a clock of our choosing; give it a reserved
slot that is neither of those, on the second port, and the same-clock
same-address cross-port collision that makes naive dual-port unsafe is
impossible by schedule rather than by comparison. The leftover slots on
that port serve the cold readers — the host's peek/memdump, the monitor's
readback.

Two things to hold onto: the side copy's *write monitoring* is deleted, not
shared — there is no second copy to keep in sync anymore; and the slot
argument leans on the 1 MHz regime, where writes land only at the commit
clock. Acceleration-land writes on arbitrary clocks and will need this
schedule re-derived — floating-bus service only matters during real bus
cycles, so the assumption should survive, but it must be re-proven, not
assumed.

## What this touches, and what it does not

| | verdict |
|---|---|
| classifier logic (`apple_mmu.sv`) | same distinctions, new output shape (wanted page id, not 24-bit PA); the `+1` adder deleted |
| RamWorks register, divert (`q_divert`) | semantics unchanged; raw value stored and compared |
| ROM (`apple_rom.sv`), I/O `$C0xx` | untouched — ROM beside the cache, I/O always BUS |
| `mem_cache.sv`, `cache_way_ram.sv` | replaced by the two banks + page engine |
| `mem_client.sv` | replaced or rebuilt: pipelined bursts, no per-op queue discipline; refresh window logic survives |
| `wb_arb` priority slot | kept; check the pre-emption residue against 16-beat bursts |
| floating-bus side copy + its write monitor | deleted; scanner reads the main bank in a reserved slot |
| HD DMA writes | on master these are real bus cycles through `apple_bus_write`, so they land in the banks like any op — verify, no new path expected |
| monitor / mismatch compare | reads the banks (which are now authoritative); the unwritten-memory-is-garbage rule stands |
| host peek/memdump | served from the banks; a DDR3-resident RamWorks page is either flushed on demand or read through the engine |
| host repo | untouched this pass; the bank-numbering convention decision recorded above |

## Open, for the implementation pass

- Port `sim/boot_tb.sv` (acceleration-only — it boots a real hdv from reset
  under Verilator and found both D$ bugs) back onto this branch as the
  validation harness, or build the page engine's own testbench first against
  the Micron model as `latency_tb`/`mem_ddr3_tb` did.
- The exact slot map of the phi0 frame: op fetch, commit write, scanner
  read, cold readers, and the page engine's BRAM side of fill/snapshot.
- Whether the aux tag store wants a shadow of the wanted-id per page for
  monitoring/debug, or the counters (`MEM_STAT` family) carry over as is.
- The small-part parameterization of the aux bank, if a build on the
  XC7A35T is wanted before the larger board arrives.
