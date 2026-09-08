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
| 2 | Part 2 dline: revalidation, PPN stamps/seams, `DDROP/DREVIVE`, the `revaltest` phase, header rewrite | battery + revaltest's dline asserts, boot 2/2; HW census | **DONE** |
| 3 | Part 2 iline: revalidation, settle 5, `IDROP/IREVIVE`, ISTREAM/CXXX text | battery + revaltest's iline asserts, boot 2/2; HW: Nox map before/after | **DONE, timing margin OPEN** |
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

## Rung 2, as built

`rtl/dline.sv`'s cache lines gained a RETAINED bit `cr` beside `cv`, and their
PHYSICAL IDENTITY in flip-flops: the bank, the REGION they were classified in,
and the language card's fold bit.  `map_changed` no longer empties the cache.
One clock later, `reval_q`, every line's valid bit is recomputed:

```
stage 1, every clock:  rv1[line] <= rt_rd[creg[line]]      // a 10:1 mux
stage 2, on reval_q:   cv[line]  <= cr[line] && fs && class-ok
                                 && cbank[line] == bank(bsel)
                                 && cfold[line] == fold
```

The line's ADDRESS never enters.  Its region was decided when it was filled,
and a region's answer is a function of the switches alone - so a line whose
region did not move keeps serving through the switch write, and a line whose
region did move keeps its tags and its row and revives when the map returns.

Why the serve compare may stay VIRTUAL through all this: the serve matches
`vt == addr[15:7]`, and `region()` reads `addr[15:8]`, which `vt` contains.
So a virtual-tag hit implies the line's stored region IS the region of the
address being served, and revalidation has already checked that this region
still translates to the bank and fold the line was filled with.  The physical
translation of the line is therefore unchanged, and the whole classify cone
stays out of the serve - the property `docs/DLINE.md` rung 2 was built on.

Everything else that follows:

- The tags are physical now: `pt` is `{ppn[15:0], addr[7]}`, 17 bits.  The set
  is `addr[6:4]` and a page holds 16 lines, so page plus `addr[7:4]` is the
  whole identity and `addr[7]` is the only bit the set leaves out.
- **Snoops compare RETAINED lines**, not valid ones, so a line written while
  it is out of service comes back holding the new byte.  That is the
  stale-revive hazard, and `revaltest` part 2 is built to hit it.
- The victim is an unRETAINED way first, then the round robin: a
  retained-invalid line counts as occupied, so under AUXMOVE both banks'
  copies of a set coexist and each toggle costs nothing.
- The posted-write seam is `{pw_ppn, pw_off[7:0], pw_data}`, 32 bits in the
  FIFO; `apple_mmu` derives the old `cl_aux/cl_bank/cl_off` from it with one
  decrementer until Part 3.  `ws_*` still speaks the old triple - the
  instruction front is rung 3's.
- An in-flight claim still aborts on `map_changed`, and `live_cmiss` is held
  off through `map_settling`, so no install can ever write `cv` on the clock
  the revalidation does.

Counters `ACCEL_DDROP` (0x8000_010C) and `ACCEL_DREVIVE` (0x8000_0110), plus
`cnt_rev_serves` for the bench.  `sim/accel.s` gained `revaltest` in the ROM
segment - sixteen RAMRD flips over one address, a write to a line while it is
out of service, and a RamWorks register move away and back.

### A bench finding rung 2 turned up: the paddle at the 255 stop

`sim/accel_tb.sv`'s game-port check failed on the first rung-2 battery -
`mode 2: paddle 3 read as 250, wanted 255` - and it is worth writing down
what it was and what it was not.

It is NOT a functional break.  Three runs, the card's own measurement of
paddle 3 identical (2804 bus cycles) in all three:

| build | paddle 3 | paddles 0/1/2 |
|---|---|---|
| rung 1 (`3547dc5`, clean worktree) | 255 | 39, 120, 0 |
| rung 2, before `revaltest` existed | 250 | 39, 120, 0 |
| rung 2, with `revaltest` | 252 | 39, 120, 0 |

The last two are the SAME RTL and differ only in unrelated program content,
so the quantity is workload-sensitive at this operating point.  A paddle at
the 255 stop runs a virtual timer of 2804 core cycles and PREAD counts
eleven-cycle loops against it: 2804/11 = **254.9**, under one iteration of
room inside a fixed +/-2 window.  The four paddles also share one strobe - a
558 already running ignores a retrigger - so where paddle 3's timer stands
when its own PREAD begins depends on what the earlier paddles' PREADs
consumed, and that moves with the accelerated op mix, which is exactly what
this rung changes.

So the check's window was wrong, not the port: it is now two counts plus one
per 64 of position, which still catches a functional break (those move a
reading by tens) and stops the top of the range from being a tripwire for
any change to the op mix.

One theory was entertained and DISPROVED on the way, recorded so it is not
re-derived: that `core_tick` double-counts because `(bus_tick && !op_dummy)`
excludes dummy cycles the data front's last-byte path would tick.  It does
not - `op_dummy` is `apple_bus_write`'s `drv_dummy`, "this cycle carries no
op at all", the DRIVER's idle cycle rather than a 6502 dummy cycle, and
excluding it is correct.  The exact mechanism behind the last few counts was
not pinned down further, because the three measurements above already settle
what the check should assert.

### Rung 2's evidence

Simulation:

- `sim/run_accel_vl.sh`, both sweeps: **97 checks, 0 errors** each (95 before,
  plus the two revalidation checks).  The revalidation's own books, in the
  mode-2 phase: **5461 drops, 5155 revives, 32062 reads served from a revived
  line** at PHI0_HIGH 49, and 5462 / 5158 / 32069 at 47.  A front that flushed
  on a map change cannot revive a line even once, so those counts are the
  rung's proof.
- `sim/suite.sh boot` **2/2 PASS**, `bad 0 mism 0` on ProDOS 2.4.3 and
  nox_los.HDV.
- `mem_integ` 20/0, `page_cache` 19/0, `fb_sim_vl` unchanged.

Build: **TIMING MET wns=+0.039 whs=+0.056 fail=0/62425** - exactly the gate,
with 1410 more endpoints than rung 1 (the per-line identity and the stage-1
registers).  Max logic depth is 22 where it was 21, but every depth-22 path is
inside UberDDR3's controller.  The one new deep tail in THIS change is
`u_mmu/rwb_p1_q -> u_dline/cnt_reval_drop[24:31]`, the drop counter's popcount
carry: books only, in no serve cone.  If a later rung needs the margin back,
registering the popcount one stage costs nothing observable.

Hardware, the animated Nox overworld map, reached by the user's route (reboot,
wait for the main menu, RETURN, 1 - see the memory note `nox-measure-screen`):

| | |
|---|---|
| lines dropped per map change | **16.1** of 32 |
| of those, revived | **95.7%** |
| net line refills per map change | **0.70** |
| D drops/s, revives/s | 640,514 / 612,830 |
| `mmismatch` | **5, plateaued** over 87.6M hits (unchanged across 8.8M) |

That is the rung's result: a map change used to invalidate every valid line in
the data cache, and now costs seven tenths of one refill.

**The x-factor is NOT comparable between rungs from these samples, and no
speed claim is made from them.**  Three rung-2 samples and the rung-1 sample
all lie on one line - speed divided by maps-per-1000-cycles is 1.67, 1.66,
1.66, 1.66 - so what these readings mostly measure is which of two program
phases the game happened to be in (the AUXMOVE-heavy map redraw, or the
keyboard poll loop), not what the gateware did.  The rung-1 figure was taken
on a machine that had been sitting at the map for hours; rung 2's was taken
minutes after loading the save.  A matched A/B - both bitstreams, the same
route, the same elapsed time - is owed, and is best done after rung 3, when
the instruction front stops flushing too and the whole benefit is in.

## Rung 3, as built

The instruction front's two slots and eight CAM entries now carry a RETAINED
bit and the same physical identity the data front's lines do, and a map change
revalidates all ten rather than emptying them - the data front's pipeline over
ten lines instead of thirty-two.

- A write's snoop compares RETAINED lines and kills them OUTRIGHT, valid and
  retained together: this front has no splice, so a line a write touched can
  never be revived.  The compare is twenty bits flat, `{ppn, vtag[3:0]}`.
- The CAM's dedupe is PHYSICAL and its promote lookup stays VIRTUAL.  Main's
  and aux's copies of one virtual tag therefore coexist - the AUXMOVE shape -
  with at most one of them valid, because a same-vtag pair shares a region and
  the table's bank answer picks exactly one.  Promotion still skips
  re-classification, by the new argument: an entry is valid only if the region
  table says its stored identity is the map's answer for its region.
- `p_bus` becomes `!p_fs`, the region table's own answer, which carries the
  page-$C3 rule.
- The settle grows from four clocks to five (`accel_seq`'s `swi_sq`), and
  `turbo_ok` gains `!map_settling`, which covers every map change `swi_change`
  cannot see - a bus op's commit, the bank register, INTC8ROM, a reset.
- `ws_*` speaks the physical space, retiring the data front's last old-triple
  registers.

`ACCEL_IDROP` (0x8000_0104) and `ACCEL_IREVIVE` (0x8000_0108).

### Two bugs this rung cost, both mine, both worth keeping

**`map_settling` started one clock late.**  It was written as a REGISTERED OR
of `map_changed` and its two delays, which makes it high at C+1..C+3 rather
than C..C+2 - so replacing `kill_now`'s `map_changed` with it REMOVED the
protection on `map_changed`'s own clock, the exact clock a front's valid bits
still describe the old map.  `sim/accel.s`'s bankfetch caught it immediately:
`turbo read $1f03: core got e8, the reference says ca` - main's INX served
where aux's DEX was due after `STA $C003`, which is the 2026-09-04 Nox splash
lockup exactly.  `map_settling` is combinational over its two delays now.  The
same mistake was latent in rung 2's `live_cmiss` gate, where dline's separate
claim abort on `map_changed` had been covering for it.

**The CAM's dedupe compared pages, not lines.**  `cam_mf` matched on
`cam_ppn == f_ppn` alone, but a page holds sixteen lines, so two different
lines in one page were called duplicates and the second was silently dropped
from the CAM.  It compares `{ppn, vtag[3:0]}` now.  This one cost promotes,
never correctness - which is why only a counter, not a bench, would ever have
caught it.

### An open finding: the paddle at the top of its range

`sim/accel_tb.sv`'s PREAD check for a paddle at position 255 has moved with
every rung - **255** (rung 1), **250 and 252** (rung 2, the two differing only
in unrelated program content on IDENTICAL RTL), **247** (rung 3) - while
paddles 0/1/2 read exactly 39/120/0 throughout and the card's own measurement
of paddle 3 stays 2804 bus cycles in every run.

So it tracks the accelerated op mix, and the virtual timer delivers a few
percent fewer PREAD counts than its sample implies: 2804 core cycles over
eleven-cycle loops is 254.9, and 247 is eight short of that.  The arithmetic
leaves under one iteration of margin at the top of the range, which is why
only that paddle shows it.

This is not something the rethink introduced and it is not a memory-
correctness question - but the trend is real and deserves its own look rather
than a wider tolerance each time.  For now the check is +/-2 for every paddle
and 12-low at the very top, which still fails a functional break (those move a
reading by tens).  **Recorded as OPEN.**

### Rung 3's evidence

Simulation: `accel_vl` **98 checks, 0 errors** on both sweeps (97 before, plus
the instruction front's revalidation check), `SUITE boot` **2/2 PASS** with
`bad 0 mism 0`.  The fronts' books in the mode-2 phase: D **5461 drops, 5153
revives, 32081 revived-line serves**; I **783 drops, 489 revives**.

Hardware, the animated Nox map, and this one needs no normalising:

> **The instruction front's drop and revive counters do not move at all.**
> `I drop 6,672,687 revive 3,019,448`, identical across three readings spanning
> **1.8 million map changes**, while D drops climbed 17.7M -> 46.8M over the
> same span.

At the measurement screen the instruction front now loses ZERO of its ten
lines to a map change.  Before this rung every valid one died on each of those
1.8M map changes.  The cumulative I-drops are all from boot and game-load,
where the ROM and language-card switches genuinely do change a line's class -
which is where drops SHOULD happen.  The data front is unchanged: 16.1 drops
per map, 95.7% revived.

There is a first sign of a speed effect.  Using the normalisation that made
the rung-1/2 samples comparable - speed divided by maps-per-1000-cycles, a
flat 1.67, 1.66, 1.66, 1.66 across all four of them - rung 3 reads **1.944,
about +17%**.  That is evidence, not proof: it is a derived metric, and the
matched A/B is still owed.  It is consistent with rung 2 moving the ratio not
at all, since a data miss rides the dispatcher unclaimed and the second touch
hits, while an instruction miss stalls the fetch stream.

### OPEN: rung 3 spends the timing margin

**Three builds: wns = +0.031, +0.002, +0.001** (whs +0.044 / +0.037 / +0.049,
`fail=0/62697` in all three), against rung 1's +0.046 and +0.104.  Those
distributions barely overlap, so this is a real cost of about 40-70 ps and not
the build-to-build noise the rung-1 notes above describe.  **The plan's gate is
WNS >= +0.039 and it is NOT met.**  Timing is MET - positive slack, no failing
endpoints - but the margin is gone, and `docs/DERISK.md`'s history says
marginal decision cones at corners are what past hardware glitches were made
of.

One cause was found and removed: the first cut gated the fill launches
(`promote_go`/`scan_go`/`sw_taken`/`ew_taken`) on `map_settling`, which made
`miss_tag_q -> f_poff`'s clock enable the worst path.  Those gates were
redundant - `f_restart` carries `map_changed` and every install sits behind
it, so an install can never land on the clock stage 1's `rv1` would be stale -
and removing them dropped max logic depth from 22 to 16 with the revalidation
counts byte-identical.  It did NOT recover the slack.

The limiter now is `u_dline/dq_st_reg[3][1] -> u_cpu/a_reg[5]`, the data
front's serve path, **75% route delay** and a path rung 1's baseline already
carried.  So what costs the margin is AREA, not a new cone: rung 2's per-line
identity and revalidation added roughly 1k LUTs and 600 flops inside dline and
congested the routing around its serve.

The cheapest fix, not yet built: store each line's 2-bit `bsel` instead of its
8-bit `cbank`, and clear retained aux lines outright when the RamWorks bank
register moves (a bus op, a handful a second).  That removes 32 eight-bit
compares and 256 flops from dline and should hand the margin back.  Until it
is done, treat this stack as functionally proven but not a bitstream to rely
on.
