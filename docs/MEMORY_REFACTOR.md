# The physical memory rethink: a 24-bit page cache and switch-surviving fronts

Status: **rung 1 (the region table) DONE and proven on hardware, 2026-09-08;
branch `memory_refactor`, taken from master (fw `87cfbfa` / host `e9042c0`).
Build TIMING MET wns=+0.046 whs=+0.046 fail=0/61015.  Rungs 2-6 not started.
Not committed.**

This is the run sheet for the user's 2026-09-07 decision to make the card's
memory one PHYSICAL space.  `docs/PAGE_CACHE.md` still describes the two fixed
64 KB banks it replaces; that file is rewritten at rung 6, when the physical
page cache lands.

## Why

The card's memory today is two fixed 64 KB BRAM banks (`rtl/page_cache.sv`):
main tagless and authoritative, aux with one RamWorks tag per 256-byte page,
the ROM in its own 16 KB BRAM (`rtl/apple_rom.sv`).  Ahead of them two
1-clock fronts (`rtl/iline.sv`, `rtl/dline.sv`) hold 16-byte lines tagged
VIRTUALLY for the serve and physically for the snoops, and every soft-switch,
LC, bank-register or INTC8ROM change (`apple_mmu.map_changed`) flash-clears
both fronts.  The flash-clear is what makes the virtual serve compare sound;
it was chosen after a physically-tagged serve failed timing at -0.689 ns
(`docs/DLINE.md` rung 2) and, on the old `acceleration` branch, a 256-entry
page-TLB read on the fetch clock failed at -4.8 ns.

Two things prompt the rethink:

1. **A 65816 future.**  The design target is a fully 24-bit 65816 whose code
   and data may be anywhere in 16 MB with no concentration in the first
   128 KB.  There is then no privileged main bank: memory is one physical
   space, pages tagged by their 24-bit location, DDR3 behind everything, and
   the L2 is a true cache whose capacity and miss path decide the machine's
   speed.
2. **Map changes flush lines that did not move.**  On the animated Nox map
   ~59k switch writes/s (AUXMOVE's RAMRD/RAMWRT dance) each empty 10 I lines
   + 32 D lines that refill through the ~9-clock dispatcher, although the
   AUXMOVE caller (LC RAM) and AUXMOVE itself (ROM) live in regions those
   switches never touch.  After DLINE rung 5 the remaining front misses are
   plausibly dominated by these flushes.

## The decisions (the user's, 2026-09-07)

- **L2 becomes a physically indexed, physically tagged set-associative page
  cache**: 256-byte pages, **128 sets x 8 ways = 1024 pages = 256 KB** (SETS
  and WAYS parameters), hashed physical index, DDR3 behind everything, no main
  bank.  ONE cache for I and D (a 6502/65816 shares 256-byte pages between
  code and data; SMC is real).  A fully associative CAM was considered and
  rejected: for a working set scattered over 16 MB its zero-conflict advantage
  is statistically nil against a hashed 8-way index, while its cost grows with
  every entry, and capacity is exactly what the 65816 needs.
- **Miss path**: clean victims fill without a snapshot (~30 clocks); per-set
  tree-PLRU replacement.
- **Translation is a region table + per-line revalidation, never a lookup in a
  serve.**  The fronts keep their virtual-tag serve compares untouched.  On a
  map change each line's valid bit is recomputed against its stored physical
  identity; unaffected lines stay valid, affected lines keep data and tags and
  revive when the map returns.
- **The ROM is in the space**, at physical bank $FF, offsets $C000-$FFFF, as
  pages like any other (DDR3-backed, cached through ordinary entries); the ROM
  BRAM and its `r2_*` line port go away; the host loads it by writing physical
  memory through the card.
- **$Cxxx CPU addresses never translate to a RAM bank's $Cx pages**: those hold
  LC bank 1's $D000 by the fold.  $C000-$C0FF is BUS always; $C100-$CFFF is
  bank $FF (internal ROM) or BUS (a slot).
- **Build first, hardware census after** (census counters land with the RTL).

## The physical address space

- `PPN[15:0] = {bank[7:0], page[7:0]}`; byte address `{PPN, off[7:0]}`; 16 MB.
- bank 0 = main; bank 1 = auxiliary (RamWorks bank 0); RamWorks bank k = bank
  k+1; **RamWorks drops to 254 banks** (physical 1..254; `RW_BANKS` in
  apple_mmu, `kRwBanks` in the host); bank $FF = ROM.  This is the host
  mirror's existing convention (`strudelworks-host/src/apple_memory.hpp`:
  image bank 0 main, banks 1-255 the RamWorks banks), so a memdump of the
  mirror and the card's DDR3 image are again the same bytes in the same order.
- The LC fold stays inside a bank: `$0000-$BFFF`, LC bank-1 `$D000` at
  `$C000-$CFFF`, bank-2 `$D000` and `$E000-$FFFF` in place.
- DDR3: `page_client.line_to_wb({PPN, line[3:0]})`, the existing 20-bit line
  shape (row = PPN[15:3], a page's 16 lines in one row); main is rows 0..31,
  ROM rows 8160..8191.  Nothing persists across power cycles: no migration.
- Read translation of a 65C02 address A (B = bank 0 or 1+rw_bank by the
  switches; B' uses ALTZP):

| CPU address | reads translate to |
|---|---|
| $0000-$BFFF | {B, A[15:8]} (zp/stack by ALTZP; text1 by 80STORE/PAGE2; hires1 by 80STORE+HIRES/PAGE2; the rest by RAMRD, RAMWRT for writes) |
| $C000-$C0FF | BUS |
| $C100-$CFFF | internal ROM page: {$FF, A[15:8]}; else BUS; $CFFF always BUS |
| $D000-$DFFF | LC read: {B', lc_bank2 ? $Dx : $Cx}; ROM: {$FF, $Dx} |
| $E000-$FFFF | LC read: {B', A[15:8]}; ROM: {$FF, A[15:8]} |

- A write that lands nowhere (BUS, ROM class, LC write-protected) has
  `cl_wr_image = 0`; the write translation never yields bank $FF as a landing
  page.
- 65816 readiness: `xlate` takes a 24-bit input; banks >= 2 map to themselves
  (cls RAM, fs 1); banks 0/1 go through the region table.  A future `flat`
  input (a card register or the machine's own switch, NOT the E flag: the map
  is the system's, not the CPU mode's) makes every bank-0/1 entry identity
  (RAM, own bank, no fold, fs 1) with one BUS-class I/O window, so bank 0's
  $C000-$CFFF exposes LC bank 1 directly; a mode change is one map change and
  one revalidation, and in the flat view `map_changed` never fires.  Not built
  now; the function's shape allows it.

## The rungs

Each rung: sims green, build WNS >= +0.039 and no new deep tail in
`build/depth_baseline.txt`, then hardware.  Explain the change before every
run; Verilator only.

| rung | what | gate | status |
|---|---|---|---|
| 1 | Part 1: region table + PPN export + `ACCEL_MAPS`, RamWorks 254, host words | pure refactor: `run_mmu_xlate_tb.sh`, accel battery both sweeps, cpu_predict, boot bench 2/2, mmu_trace assert if a capture exists; HW: maps/s baseline on the animated Nox map | **DONE** |
| 2 | Part 2 dline: revalidation, PPN stamps/seams, `DDROP/DREVIVE`, the `revaltest` phase, header rewrite | battery + revaltest's dline asserts, boot 2/2; HW census | not started |
| 3 | Part 2 iline: revalidation, settle 5, `IDROP/IREVIVE`, ISTREAM/CXXX text | battery + revaltest's iline asserts, boot 2/2; HW: Nox map before/after | not started |
| 4 | Part 3 alone: `way_ram`, new `page_cache`, rewritten `sim/page_cache_tb.sv` sweeping the geometry, OOC synthesis | 128x8 / 64x10 / 64x8 pass, the il race sweep, the pressure round trip, the clean-victim path's ~30-clock answer | not started |
| 5 | Part 3 integration: master_top, F_WAIT/C_WAIT, fb_sim tap, monitor, regfile, ROM as pages + host write path, `apple_rom` removed, mem_integ_tb | mem_integ 20 checks, battery, boot bench both images mode 0 vs 2 parity; the HW ladder | not started |
| 6 | Part 4 + docs: PAGE_CACHE.md rewrite, MEMORY.md, DLINE.md, ISTREAM.md, CXXX.md, PROTOCOL.md, DDR3_USAGE.md; then the 64 x 8 build | | not started |

## Rung 1, as built

`rtl/apple_mmu.sv`'s `classify()` is gone.  In its place: ten REGIONS of the
16-bit space (`R_ZP $00-01 | R_TXT $04-07 | R_HGR $20-3F | R_RAM the rest <
$C0 | R_IO $C0 | R_CXL $C1,$C2,$C4-$C7 | R_C3 $C3 | R_C8 $C8-$CF | R_LCD $Dx |
R_LCE $Ex-$Fx`), two REGISTERED ten-entry tables `rt_r_q`/`rt_w_q` recomputed
every clock from the switch registers, and `xlate(va[23:0], rw)` — a mux into
the table, the language card's fold, and the bank the entry's side names.
Every question the module answers goes through it, so they cannot drift apart.

An entry is `{cls[1:0], wr, bsel[1:0], fold, fs}`.  `fs` ("front-servable")
replaces the fronts' own `cls != BUS` and carries iline's page-$C3 rule:
`R_C3.fs = (cls == ROM) && intc8rom`, so a $C3 line drops when the latch
clears and revives when it sets.  Two byte-level facts stay explicit
overrides: `$CFFF` inside `xlate`, and iline's `$CFF0` line in `excl()`.

New outputs, none consumed yet: `cl_ppn`, `pf_ppn`, `p_ppn/p_reg/p_fold/p_fs`,
`d_ppn/d_reg/d_fold`, `rt_rd_flat` (the ten read entries packed, 70 bits),
`rwb_p1`, and `map_settling` (`map_changed` and the two clocks after it).
`ACCEL_MAPS` counts `map_changed` in `accel_seq` and reads at
`0x8000_0100`; `0x0104-0x0110` are reserved for the fronts' drop/revive
counters and `0x0114..` for the page cache's.

**The one behavioural change** is that the tables stand ONE CLOCK BEHIND the
switches — the same clock `map_changed` rises on.  Nothing may read them in
that clock.  Nothing does: a switch-changing synthetic commit holds
`turbo_ok` and the dispatcher's `settled` for four clocks (`accel_seq.sv`'s
`swi_sq`, three of them after the commit's own), the table is new on the
second; INTC8ROM is set at the `op_present` of a $C3xx access that always
rides the sequencer, whose next present is at least four clocks later; and
every other map change — the bank register, $CFFF, an override's $C000/$C004,
a reset — happens on a BUS commit, about a hundred clocks from the next
present.  `map_settling` is exported for rung 3, which grows the settle to
five and makes this airtight for the fronts as well.

What proves it: **`sim/run_mmu_xlate_tb.sh`**, a new bench that holds the old
`classify()` verbatim beside the new ports and sweeps every reachable map —
rom_ok x 2, the language card's 8 states, the nine other switch bits, two
RamWorks banks = 16384 maps, each over all 256 pages and the four byte-level
addresses that matter, read and write.  It checks the class and the
write-lands-in-the-image bit against the old function, and the PPN, `fs`,
region and fold against an independently written model of the decided space.
**16384 maps, 33,347,584 checks, 0 mismatches.**

### Rung 1's evidence

Simulation, all green on 2026-09-08:

- `sim/run_mmu_xlate_tb.sh` (the full sweep): **16384 maps, 33,347,584 checks,
  0 mismatches**.
- `sim/suite.sh battery` **33/33 PASS** - `accel_vl` 95 checks / 0 errors,
  `mem_integ` 20 / 0, `page_cache` 19 / 0, `fb_sim_vl`.  Every check count is
  the pre-refactor baseline's, which is what "pure refactor" had to mean.
- `sim/suite.sh cpu` **4/4 PASS** (`cpu_predict` included).
- `sim/suite.sh boot` **2/2 PASS** - ProDOS 2.4.3 and nox_los.HDV, `bad 0
  mism 0` both.
- `sim/mmu_trace_check.cpp`'s new assert - `cl_ppn` against the index the
  checker already reconstructs - reports 0 disagreements.  No real capture
  exists on disk; this ran against a synthetic one.

Build: **TIMING MET wns=+0.046 whs=+0.046 fail=0/61015** (the baseline bit was
+0.039 / +0.033 at 60889).  The depth audit reports 140 new tail endpoints,
none of them in this change's cones: 102 from `u_regfile/accel_mode_reg[0]`
into `u_filter`, 31 from `u_dline/dq_st_reg[1][1]` into the CPU (a source the
baseline already carries, with different destinations), 4 from `u_vbl/pal_reg`
and 3 inside UberDDR3.  Two builds of THIS SAME source, minutes apart, differed
by +0.104 vs +0.046 WNS and 1367 vs 3612 paths at >= 10 levels - the build
stamp is a compiled-in constant, so placement moves run to run and the depth
audit is noisy at this granularity.

Hardware, the animated Nox overworld map (mode 2, unlimited, swint on):

| | |
|---|---|
| maps/s | **51,588** |
| maps per 1000 bus cycles | 51.6 - one map change every ~19 cycles |
| speed over the interval | 86.25x (440.3M ops over 5.105 s of Apple time) |
| maps per 1000 ops | 0.60 |

Measured as the delta of `ACCEL_MAPS` and `ACCEL_CYCLES` over one interval, the
rate taken from the card's own 1 MHz cycle counter rather than wall clock.  This
corroborates the ~59k switch-writes/s the rethink was argued from, and it is the
denominator rungs 2 and 3 are measured against: each of those 51.6k/s map
changes today empties 10 I lines and 32 D lines.

**Read `ACCEL_MAPS` only on a RUNNING machine.**  `map_changed` is held high
for every clock of a reset (`rst || !res_sync || ...`), so a card sitting at
the boot menu counts clocks, not map changes - the first hardware read after
the load said 11,453,040 for a machine that had executed nothing.

### Two guards this rung added

- `tools/check_ports.py` (`sim/suite.sh` bench `ports`): every named port
  connection in `rtl/` and `sim/` against the instantiated module's declared
  ports.  `sim/lint.sh` cannot lint `master_top` - it instantiates Xilinx
  primitives Verilator will not resolve - so a `.port()` the target does not
  have costs a ten-minute Vivado elaboration to find.  This rung paid that
  once: `ACCEL_MAPS` needed threading through `card_link`, which wraps the
  register file, and `master_top`'s `.accel_maps` was attached to `card_link`,
  not `wb_regfile`.
- `sim/run_mmu_xlate_tb.sh` with `+quick` (bench `mmu_xlate`): 256 maps in
  seconds, in the quick set.  The full 16384-map sweep is the rung gate, run
  once.
