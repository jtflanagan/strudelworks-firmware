# The physical memory rethink: a 24-bit page cache and switch-surviving fronts

Status: **FINISHED, 2026-09-08.  Rungs 1-5 DONE and proven on hardware; rung 6
NOT PURSUED by the user's decision (see "How this ends", last).
branch `memory_refactor`, taken from master (fw `87cfbfa` / host `e9042c0`).
Last bitstream **TIMING MET wns=+0.238 whs=+0.027 fail=0/70934**, 83 RAMB36 of
135: the >= +0.039 gate met six times over, and the long-chain tail SHORTER
than before the rung (181 endpoints at >= 14 levels against 269).  Simulation
at the pre-refactor check counts: accel_vl 98/0 both sweeps, the boot bench on
ProDOS 2.4.3 and nox_los.HDV at modes 0 AND 2, mem_integ 21/0, page_cache 52/0
at 128x8, 64x10 and 64x8.  On the animated Nox map: 569 pages filled, **ZERO flushed**, 0 late fills, 0
drops, mismatches plateaued at 5, and both fronts reproducing rungs 2-3 exactly.**

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
| 4 | Part 3 alone: `way_ram`, the new cache as `phys_cache` beside the old, `sim/phys_cache_tb.sv` sweeping the geometry, OOC synthesis | 128x8 / 64x10 / 64x8 pass, the il race sweep, the pressure round trip, the clean-victim path's answer | **DONE** |
| 5 | Part 3 integration: master_top, F_WAIT/C_WAIT, fb_sim tap, monitor, regfile, ROM as pages + host write path, `apple_rom` removed, mem_integ_tb | mem_integ 20 checks, battery, boot bench both images mode 0 vs 2 parity; the HW ladder | **DONE, on hardware** |
| 6 | Part 4 + docs; then the 64 x 8 build | | **NOT PURSUED** - Part 4 landed inside rung 5; the docs carry a SUPERSEDED banner instead of a rewrite |

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

### RESOLVED: the paddle-3 check was testing an unconnected input

The game-port check failed on the first rung-2 battery - `mode 2: paddle 3
read as 250, wanted 255` - and its reading then drifted with every rung: 255
(rung 1), 250 and 252 (rung 2, the two differing only in unrelated program
content on IDENTICAL RTL), 247 (rung 3).  Paddles 0/1/2 read exactly 39/120/0
throughout and the card's own measurement of paddle 3 stayed 2804 bus cycles
in every run.

**Paddle 3 is not connected on the machine** (the user, 2026-09-08).  The card
reads it saturated on hardware - `pdl 1215 1185 4000 4000`, and paddle 2 with
it - so PREAD's count for it was measuring an unconnected input, and drift
with no correlate in the connected paddles is exactly what that looks like.
The check is removed rather than tolerated: `sim/accel_tb.sv` now asserts on
paddles 0-2 only, at the original +/-2, and prints paddle 3's reading without
judging it.

The lesson worth keeping: two tolerance widenings went into that check before
the question "is this signal connected to anything?" got asked.  A measurement
that moves with unrelated changes while its neighbours stay exact is evidence
about the measurement, not the thing measured.

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

### The paddle-3 check, removed

Rung 3 moved that reading again (247).  It is gone now - paddle 3 is not
connected on the machine, so the check was asserting on an unconnected input.
See "RESOLVED: the paddle-3 check was testing an unconnected input" above.

### The long chains rungs 2-3 left, and what they cost

The user's steer, 2026-09-08: **look at the long logic chains rather than the
slack, because a chain that manages to meet timing is still a cause of timing
pressure.**  Counting chains at >= 12 levels (UberDDR3 excluded, it is not
ours) found the pressure immediately:

| source register | chains >= 12 levels |
|---|---|
| `u_cpu/pcl_reg[0]` | 88 (pre-existing: the CPU's own datapath) |
| `u_card/source_real_reg` | 81 (pre-existing) |
| `u_dline/dq_st_reg[3][1]` | 35 (the serve path) |
| **`u_mmu/rwb_p1_q`** | **64 - every one of them ours** |

And every single one of those 64 ended in a REVALIDATION COUNTER -
`cnt_reval_drop[16:31]` and `cnt_reval_revive[16:31]`, both fronts.  Not one
reached a valid bit or anything else functional.  The chain was `rwb_p1 -> the
bank mux -> an eight-bit compare -> a thirty-two input popcount -> a 32-bit
carry`: fifteen levels of logic to increment a statistic.

The fix is to root the books in registers.  `rv_ok`/`rv_c`/`rv_t*` and the
valid bits are copied into flops every clock, the popcount and the counter add
run off those copies a clock later, and the valid-bit update itself is
untouched at `reval_q`.  Two flops per line.

| | before | after |
|---|---|---|
| `rwb_p1_q` chains >= 12 levels | 64 | **0** |
| max logic depth, whole design | 22 | **18** |
| max logic depth, our RTL | 16 | **15** |
| tail >= 14 levels | 233 | **164** |
| WNS | +0.001 | **+0.024** |

The counters count the same events to the bit afterwards - D 5461/5153/32081,
I 783/489, unchanged - which is what says the change was free.

Finding one bug on the way: the per-slot increments in `iline`'s `reval_q`
block were still there.  The patch that was supposed to remove them had two
edits, the second one's assertion failed, and the script wrote the file only
at the end - so the first, successful edit was silently discarded and the
removal was reported as done when it had not happened.  It was harmless while
both increments sat on the same clock (the later popcount assignment simply
overwrote them, non-blocking), and moving the popcount to `reval_q2` split
them across clocks and both started counting: I drops went 783 -> 882.  An
unexplained counter change was worth chasing rather than accepting.

### STILL OPEN: the data front's serve chain

The deepest chain that remains in our RTL is fifteen levels,
`u_dline/dq_st_reg[1][0] -> u_cpu/{a,x,y,md}_reg[6..7]`, and it splits in half:

- **dline, 7 levels, 4.75 ns**: `dq_st` -> *1.067 ns of route* -> the tag
  LUTRAM (RAMD32) -> two LUTs for the nine-bit tag compare -> `cam_hit` (the
  four-way OR) -> `serve_hit` -> `d_din`.
- **cpu65c02, 7 levels, ~4.4 ns**: `d_din` -> the ALU operand -> the carry
  chain (`f_c_i_*`) -> the result mux -> the accumulator.

Half of it is the CPU's own datapath from `din` to `A`, which is not dline's
to shorten.  dline's half is close to minimal as it stands: a nine-bit tag
compare needs two LUT6 levels, then one to OR the four ways and one for
`serve_hit`.  The levers, none of them cheap:

- **A narrower virtual tag.**  `TW = 16 - 4 - IW`, and at `IW = 3` that is 9
  bits.  At `IW = 6` (64 sets) it would be 6 bits and compare in ONE level.
  That is a geometry change, and `docs/DLINE.md` records a 64 x 2 LUTRAM shape
  missing timing twice for a different reason (a 64:1 valid mux), so it wants
  measuring rather than assuming.
- **The 1.067 ns first hop** from `dq_st` to the tag LUTRAM at fanout 14 is
  route, not logic - more per-way register copies is the technique
  `docs/DLINE.md` already uses for exactly this.
- **`d_din`'s `!serve_hit & accel_din` term** is what puts the fully-reduced
  hit on the byte's cone.  It would go away if the sequencer's byte were zero
  whenever the front serves, but the two can both be ready in one cycle and
  `claim_q` is a clock behind, so that is real microarchitecture work.

### Rung 3's timing margin: spent, then most of it recovered

Rung 3 as first built spent the margin: three builds gave wns **+0.031,
+0.002, +0.001** against rung 1's +0.046 and +0.104, so the plan's >= +0.039
gate was not met.  Two things were done about it, in this order.

**The redundant launch gates.**  The first cut gated the fill launches
(`promote_go`/`scan_go`/`sw_taken`/`ew_taken`) on `map_settling`, which made
`miss_tag_q -> f_poff`'s clock enable the worst path in the design.  They were
unnecessary - `f_restart` carries `map_changed` and every install sits behind
it, so an install can never land on the clock stage 1's `rv1` would be stale.
Removing them dropped max logic depth from 22 to 16 with the revalidation
counts byte-identical.  It did NOT recover the slack.

**The counter chains** (the section above).  Rooting the revalidation books in
registers deleted all 64 of the `rwb_p1_q` chains, and that is what moved the
number:

| build | wns |
|---|---|
| rung 3, first three builds | +0.031, +0.002, +0.001 |
| after the counter fix | +0.024, **+0.041** |

**The latest build MEETS the gate at +0.041** (whs +0.062, `fail=0/62793`).
Be careful with one sample, though: build-to-build spread on identical source
is about +/-30 ps here, so the honest reading is that the counter fix bought
roughly 20-25 ps and the stack now sits *around* the gate rather than
comfortably above it.

Our deepest remaining chain is 16 levels; everything deeper in the design
belongs to UberDDR3's controller, which is not ours.  The next lever, if more
margin is wanted, is the data front's serve chain described above.

## Rung 4, as built

The physical page cache exists, passes its own bench at three geometries and
has been through out-of-context synthesis.  It is NOT wired into the design:
rung 4 builds it beside `rtl/page_cache.sv`, which still serves the machine,
and rung 5 does the swap.

**It is a new file, `rtl/phys_cache.sv`, not a rewrite of `page_cache.sv`.**
The plan says "page_cache.sv rewritten", and it will be - at rung 5, where
master_top changes anyway and the old file is deleted.  Rewriting it now would
have taken the whole battery red for the length of a rung (accel_tb, boot_tb
and mem_integ_tb all instantiate it), and rungs 1-3 are proven on hardware
against a design that builds.  So `phys_cache` is the module's name until the
integration renames it, and `sim/suite.sh battery` runs BOTH page caches.

### What it is

`SETS x WAYS` pages of 256 bytes - 128 x 8 = 1024 pages = 256 KB - physically
indexed and physically tagged, one cache for instructions and data, the DDR3
behind everything.  The set index is hashed, `ppn[6:0] ^ ppn[13:7]`, which is
what spreads the machine thinly: two of bank 0's pages land in each set, two of
bank 1's, and the ROM's sixty-four go one per set into half of them - five ways
of eight at worst.  An ordinary IIe therefore fills the cache and never evicts.

The pipeline is three clocks to a byte, the two-bank design's latency, and it
gets there by running the tag compare BESIDE the row read rather than in front
of it:

| clock | |
|---|---|
| P0 | the hashed set indexes every way's port A and the directory; the tags, valid, dirty and replacement bits are registered |
| P1 | WAYS tag compares against the entrant's page -> the one-hot hit way, the victim, registered.  **A write's decision is taken here** |
| P2 | the rows are out; one WAYS:1 row mux, one byte select; **a write lands** on its hit way's port A |
| P3 | `sub_en`/`sub_data` stand, `decided` pulses |

**The decision moved a clock earlier than the two-bank design's**, which
decided at P2 because it read its tag at P1.  Reading the directory at P0 - it
is indexed by the same preview the block RAMs are - is what buys that clock,
and the clock is what lets a write land at P2 as the plan asks.

### The landing reservation, and who else could want that clock

A write lands two clocks after its entrant, and no fill may read a page on the
clock a write to it lands.  The reservation is a register (`wl_v`), so it
refuses `il_ack` and `pw_take` with no cone at all.  What it does NOT refuse is
`op_present`, and the plan does not say why it need not.  It need not because
two guarantees already exist:

- an op's own landing sits inside its `busy` window (P0..P2), so the sequencer
  cannot present another op there; and
- a POSTED write's landing is covered by `rtl/accel_seq.sv`'s `d_pending` -
  **the sequencer dispatches nothing at all while the data front has a write
  short of the cache**, and dline's `drain_sr` holds `pending` for three clocks
  after `pw_take`.  A bus op cannot land there either: the front retires no
  writes during a bus cycle, so the FIFO is empty for the whole of one.

Both are invariants of other modules, so both are COUNTED here rather than
assumed: `cnt_land_clash` counts an entrant on a landing clock and
`cnt_ppn_clash` counts a classified op whose page is not the one its P0
indexed.  The bench asserts both are zero; they are the two ways this
structure could corrupt silently.

### One row mux, two consumers

The op's byte and a line request's row both need the WAYS:1 mux over the ways'
outputs, and the plan budgeted one.  They can share one because their mux
clocks can never coincide: a line request is refused on an op's P0, so its row
comes out one clock either side of the op's, never on it.  The select is a
single register written at every compare clock and read by whichever
transaction owns the next one.  That is ~300 LUTs not spent twice.

### The replacement tree at ten ways

Tree pseudo-LRU as designed: one bit per internal node, the victim walk
follows the bits, a touch walks the way's own index and flips the nodes it
passes.  The point of the tree over a used-bits scheme is that an update's new
bits are a function of the touched way ALONE - each set's bits need only an
enable, never a read of their own state.

`WAYS = 10` is in the sweep on purpose and is not a power of two, so the tree
has more leaves than there are ways.  The surplus leaves fold back onto the low
ways (`idx >= WAYS ? idx - WAYS : idx`).  That is a legal policy - every way
stays reachable and none is starved by more than the fold - and the sweep's
point is that the RTL builds and answers correctly at ten ways, not that ten
ways replace optimally.

### The directory in LUTRAM, and the invalidate walk

**This is what out-of-context synthesis was for.**  The first cut held valid,
dirty and the replacement bits in FLOPS, as the plan budgets them (2048 + 896),
and priced out at **11,425 LUTs post-route against the plan's thousand** - a
factor of eleven.  The flops are not the cost.  Each one needs its own
next-state select fed by a DECODED set index, two or three writers deep, and
that is two or three LUTs apiece: 2,944 flops bought about 8,000 LUTs of
select logic.

So the directory became one word per way per set in the distributed RAM that
already held the tags - `{valid, dirty, tag[15:0]}` - plus the replacement
tree in its own.  A write is then one addressed write and a read is the read
the tags were already doing, and the whole structure costs what the tags cost.

The price is that LUTRAM cannot be cleared in a clock, so **the invalidate is a
WALK again**: one set per clock, `invalidating` high across it, and a reset
walks it too.  That is not a new contract - it is `rtl/mem_cache.sv`'s, which
`rtl/accel_seq.sv` still honours (`fast_ok` carries `mem_invalidating`), and
which `page_cache.sv` tied low only because its valid bits were flops.
Nothing is served under a walk; `late_fills` keeps its meaning and the
walk's own refusals are counted separately (`cnt_iv_block`).

### The bench

`sim/phys_cache_tb.sv` holds a FULL MODEL of the cache - every set's tags,
valid, dirty and replacement bits, and the 16 MB physical image - and asserts
the DUT's directory equals it, way for way and bit for bit, at every phase
boundary and every 250 random ops.  The replacement policy is therefore not
merely plausible here: an eviction that chose a different victim, a dirty bit
that did not set, a tag that did not retire, all fail on the access that caused
them.  `sim/run_phys_cache_tb.sh` builds and runs it at **128 x 8, 64 x 10 and
64 x 8**; `sim/suite.sh` has it as bench `phys_cache`, in the battery.

Two of its phases are worth naming:

- **The landing reservation, swept.**  A line request is offered on each of the
  clocks k = -4 .. +4 around a write, where k is its clock relative to the op's
  P0 and the landing is k = 2.  The bench asserts what each must do: refused at
  k = 0 (the op's own P0) and k = 2 (the landing), granted everywhere else, and
  the row it returns is the PRE-write one before the landing and the POST-write
  one after.  That is the P+2 law in its new form, and it is where a fill would
  silently read a stale line.
- **The pressure round trip.**  `SETS*WAYS + 8` pages, each written with its own
  signature and then read back whole.  At 128 x 8: 1032 pages, 1069 fills, 44
  dirty flushes, every byte returned, and the DDR3 the stub holds equal to the
  model everywhere the cache is not holding dirty data.

### Rung 4's evidence

Simulation, 2026-09-08:

- `sim/run_phys_cache_tb.sh`: **52 checks, 0 errors at each of 128 x 8, 64 x 10
  and 64 x 8.**
- A cold read misses and answers in **19 clocks** with the stub at twelve
  clocks of latency - no snapshot on a clean victim - against a 1 MHz budget of
  ninety.  Every byte of a resident page stands **three clocks** after
  op_present, and a line request's row **three clocks** after its ack.
- The invalidate walks 128 sets in **127 clocks** with `invalidating` high
  across it, and a reset does the same from cold - both far inside the DDR3's
  calibration, which is what the machine actually waits for.
- Over 2500 random ops across the whole 16 MB: hits, misses, `served`,
  `MEM_FILLS` and `MEM_FLUSHES` all equal to the model's, `late_fills` zero,
  `cnt_land_clash` and `cnt_ppn_clash` zero.
- `sim/suite.sh battery` **35/35 PASS** - `accel_vl` 98 checks / 0 errors both
  sweeps, `mem_integ` 20 / 0, the OLD `page_cache` 19 / 0 (it still serves the
  machine and is untouched), `phys_cache` 52 / 0 at all three geometries,
  `fb_sim_vl`.  `sim/lint.sh` clean, `tools/check_ports.py` clean.
- No bitstream was built for this rung and none was needed: `phys_cache` is not
  in `build/build.tcl`'s file lists yet, so the card's design is bit-identical
  to rung 3's.

Out-of-context synthesis, `xc7a100tfgg484-2` at the design's own 10 ns:

| | LUTs | of those, LUTRAM | flops | RAMB36 | WNS | WHS |
|---|---|---|---|---|---|---|
| 128 x 8, the directory in FLOPS | 11,425 | 438 | 3,994 | 64 | +0.345 | +0.096 |
| **128 x 8, the directory in LUTRAM** | **2,746** | 498 | **1,061** | 64 | **+1.425** | +0.116 |
| 64 x 8, the directory in LUTRAM | 2,416 | 292 | 953 | 32 | +1.925 | +0.114 |

The restructure paid twice: 8,679 LUTs and 2,933 flops out, and **a full
nanosecond of setup slack back**.  Against the plan's budget - 64 RAMB36, ~3k
flops, ~1k LUTs - the block RAM is exactly as predicted, the flops are a third
of the estimate (the estimate assumed the directory was flops), and the LUTs
are 2.7x it: the budget counted the tags, the compares, one row mux and the
engine, and did not count the victim walk, the second row mux for port B, or
twelve counters.

**The DO-register question is settled: keep it.**  Both output registers on a
way's port A earn their place - the row is 128 bits wide, the way mux and the
byte select want a whole stage between them, and at 100 MHz the block will
route at 10 ns with 1.4 ns to spare.  Nothing here is asking for the clock
back.

Note also what the 64 x 8 line is for: it is the same LUTs and half the block
RAM, which is the cheap fallback if the integrated design turns out to want
its RAMB36 elsewhere.

### Three bugs this rung cost, all mine, all caught by the bench

**`il_done` arrived a clock late.**  Written as a REGISTER off the third stage
of the ack's shift register, it stood at ack+4 while the row stood at ack+3.
The bench times the ack-to-done distance rather than merely waiting for it, so
it said so on the first run.  It is combinational off the shift register now.
A registered done would have cost the fronts a clock per line for nothing.

**The bench committed before the bus's byte had settled.**  `data_sync` is
compared REGISTERED (`data_q`) at `op_commit`, so the byte has to stand at
least one clock before the commit; the task set both on the same negedge
whenever the access was slow enough to have used up its cycle.  94 monitor
mismatches on a coherent machine, all of them misses.  The old bench had three
clocks between the two by construction and never said why; this one does, and
says so.

**The directory was compared while the engine was still filling.**  `decided`
for a read miss pulses at the CRITICAL BEAT, fifteen beats before the retag,
so a check that ran as soon as the op returned caught the victim cleared and
the new tag not yet written.  `check_dir` waits for `busy` now.  Worth keeping
because it is a real property, not a bench artefact: between a miss's answer
and its retag the cache is one page short, and anything that reads the
directory in that window - a front's line request included - must be able to
take "not resident" for an answer.

### What rung 5 has to wire

- `master_top`: `phys_cache` in place of `page_cache` (and the module renamed
  to `page_cache`, the old file deleted), `rtl/apple_rom.sv` and its `r2_*`
  port gone, `way_ram.sv` into `build/build.tcl`'s file lists.
- The fronts move from "`il_ok` with the ack" to "`il_done` at ack+3": iline's
  `F_REQ -> F_WAIT` and dline's `C_REQ -> C_WAIT`, and the stale-done law
  (page_cache holds `il_busy` until the front leaves its wait state).  `il_src`
  is already booked per front here (`cnt_il_i`/`cnt_il_d`).
- `pw_ppn`/`pw_off` go to the cache directly from dline's FIFO, beside
  `pw_take` - apple_mmu needs no new preview for a posted write, which is why
  the module takes them as its own ports.
- `fb_sim`'s tap is already the right shape: `mw_stb` fires for every byte
  landing in physical bank 0, the write miss's patch included.
- `MEM_CTRL[27:24]` becomes `MEM_PAGES_LOG2` from a master_top parameter, and
  `MEM_FILLS`/`MEM_FLUSHES`/`MEM_DECLINES` land at 0x8000_0114..
- `accel_seq` already honours `mem_invalidating`; with the walk back it
  matters again, and the reset walk (SETS clocks) finishes long before the
  DDR3 calibrates.

## Rung 5, as built

The physical page cache is the card's memory now.  `rtl/page_cache.sv` is the
module rung 4 built as `phys_cache`; `rtl/bank_ram.sv` and `rtl/apple_rom.sv`
are gone, and with them the two fixed 64 KB banks and the ROM's own block RAM.

### The ROM stopped being special

`rtl/apple_rom.sv` held the IIe's 16 KB in a block RAM of its own and served it
from there, with a second port the instruction front pulled ROM lines through
four bytes at a time (`r2_*`, four states of iline's fill engine).  All of that
is gone.  The ROM is physical bank $FF, pages $C0-$FF, cached like anything
else - which means a ROM line is fetched by the same line port a RAM line is,
installed in the same slots, revalidated by the same rule, and snooped by the
same compare.  iline lost its `t_rom`/`cam_rom` per-line flag, its `F_R0..F_R3`
states, its ROM staging buffer and its `r2_busy` invalidation, and `rv_ok` lost
its `is_rom` argument: a line's own BANK says which class the region table must
still be naming, because the ROM's bank is $FF and nothing else's is.

`rtl/rom_loader.sv` replaces it - the same MEM_ROM message on the wire, turned
into 16384 PHYSICAL WRITES through the posted-write seam, arbitrated in
master_top behind the data front's.  After the load the ROM's sixty-four pages
sit in the cache, dirty, and hit like any other page.

**Two things about that had to be worked out rather than assumed.**

*The rate.*  A chunk arrives at up to a word a clock and a byte leaves every
four clocks, so the link delivers sixteen times faster than the seam drains.
The loader therefore stages one chunk (512 bytes) and the host waits for its
`busy` to fall before sending the next; a chunk that arrives under a drain is
counted as an OVERRUN and dropped WHOLE, so `rom_ok` never sets and the machine
runs from its own ROM - a visible failure rather than a ROM with a hole in it.
`swhost`'s status prints the overrun count.

*The window, and this one is a real hazard the plan does not mention.*  The
page cache serves one miss at a time and an op that misses while the engine is
busy is counted (`late_fills`) and NOT served - which for a WRITE means the
byte is lost.  That never happened before because ONLY OPS started fills, and
ops are ninety-eight clocks apart while a fill is fifty: the engine was always
idle before the next one.  The loader is the first thing that can start a fill
asynchronously, and the first byte of each of the ROM's sixty-four pages is
exactly such a fill.  So the loader offers a byte only just after a bus cycle
has begun - where a fill has the whole cycle to finish in - or when the machine
has presented nothing for long enough that there is no cycle to be inside.
`sim/mem_integ_tb.sv` caught this on its first run, as one late fill.

### The line port grew a `done`

The old port answered `il_ok` WITH the ack and put the row on the bus two
clocks later.  A physically indexed cache cannot do that: whether it holds a
page is the answer to a tag compare that has not run yet at the grant.  So
`il_ack` grants, and `il_done` stands exactly three clocks later with `il_ok`
and `il_row` together.  Both fronts' wait states follow it - iline's `F_W1`,
dline's `C_W1` - and master_top registers which front was granted (`il_src_q`)
so the one `done` reaches the one that asked.  A decline costs four clocks
where it used to cost one, which matters not at all: with the whole machine
and its ROM resident in a 256 KB cache, a decline is a cold-start event.

### Everything that assumed a privileged main bank

- The fronts' requests speak `{ppn, line}` rather than `{aux, bank, off}`;
  dline's shadow names bank 0's pages 0 and 1 explicitly (it only ever fills
  while the zero page and stack ARE main memory, its `zs_main_q`), and its
  last old-triple carriers - `m_aux_q`, `m_bank_q`, the transaction copies -
  are retired, along with `d_aux` and iline's `p_cls`/`p_aux`/`p_off`/`rw_bank`.
- `card_byte(ppn, off)` is how the benches read the card's memory now: hash the
  page to its set, scan the ways, read the one that holds it, else the DDR3.
  `card_main` and `card_aux` are two lines on top of it.
- The benches' DDR3 stubs back the whole 16 MB: main and the ROM are in the
  DDR3 now, not just the RamWorks banks.
- `MEM_CTRL[27:24]` is log2 of the cache's PAGES (10), from master_top's
  `MEM_SETS`/`MEM_WAYS` through `card_link`.  `MEM_FILLS`, `MEM_FLUSHES`,
  `MEM_DECLINES` at 0x8000_0114.., and `MEM_ROM` at 0x0120 for the load's flow
  control.

### The three bugs rung 5 cost, all mine, all found by running

**The loader can start a fill, and nothing else ever could.**  See THE WINDOW
above.  `sim/mem_integ_tb.sv` reported it as one late fill on the first run,
which is exactly what the counter is for.

**The benches outran the seam.**  `boot_tb` and `accel_tb` sent their 32 ROM
chunks back to back, so thirty-one were dropped, `rom_ok` never set, and every
ROM fetch went to the bus.  The boot bench's shape said it precisely: the disk
booted, `bad 0 mism 0` throughout - correct, because the machine was reading
its own ROM over the bus - while the turbo count FROZE at 325,559 and bus reads
climbed to 295,000.  A machine that is perfectly correct and accelerates
nothing is what a missing ROM looks like now.

**The data front popped its FIFO on writes that were not its own.**  The posted
seam has two producers now, and `pw_take` says only that SOMETHING was taken.
dline was wired to it directly, so for each of a ROM load's 16,384 takes it
discarded one of its own queued writes.  Two benches said so at once, in two
different languages: the accel battery counted 1015 monitor mismatches whose
last was a read of $0000 the card answered 00 to and the machine answered 38,
and the boot bench's drain accounting came out 131,072 too high - 16,384 for
the ROM, and the rest dline's own writes going round again.  The fix is one
term: a front is told a take is ITS take only when it was the source.

The general lesson is the one the seam's name hides.  "Arbitrated with dline's
FIFO" is a single clause in the plan, and it costs three signals: who offers,
who is told they were taken, and who may offer at all.  Getting two of the
three right is a design that works until the second producer runs.

### Rung 5's evidence

Simulation, 2026-09-08 - every bench at its pre-refactor check count:

- `sim/run_accel_vl.sh`, both sweeps: **98 checks, 0 errors** each, the count
  rung 3 left.  The revalidation books are rung 3's to within the program's own
  jitter: D 5481 drops / 5154 revives / 31740 revived-line serves, I 777 / 483.
  Mode 2's fast-op census shows **1024 ROM ops** - the ROM served as cached
  pages, at a fast op's cost.
- `sim/run_mem_integ_tb.sh` **21 checks, 0 errors** (20 before, plus the ROM
  load's own), no late fills, no drops.  It runs under Verilator now.
- The boot bench, ProDOS 2.4.3 and nox_los.HDV at mode 2: **PASS** each - the
  image equals the reference in every bank, the disk boots, and every posted
  write drained through the classified stage exactly once (9,165,238 and
  1,279,134) beside the ROM's 16,384.
- `sim/run_page_cache_tb.sh` 52 checks x 3 geometries, `reg_map`, `lint`,
  `tools/check_ports.py`: all clean.  The host cross-builds.

**The boot bench at MODE 0 found a gap in its own reference, not in the card.**
A handful of `$C4xx` reads disagreed - but `MB_SLOT = 4`, so that page is the
Mockingboard's, and the ProDOS slot scan reads VIA registers there that the
reference explicitly does not model (it answers FLOAT).  The card agreed with
the machine on every one.  The bench already carries that exemption on the
FAST-read path; the BUS-read path never got it, which is why only mode 0 sees
it - with the core accelerated those reads are fast ops.  Mode 0 had not been
run since before the Phasor went into slot 4.  The exemption is on both paths
now.

### Rung 5's timing: spent, then more than recovered

    build 1, as integrated       wns=+0.007  whs=+0.045   fail=0/67856
    build 2, as integrated       wns=+0.018  whs=+0.030   fail=0/67856
    build 3, the row array sliced  **wns=+0.238  whs=+0.027   fail=0/70934**

Against the plan's >= +0.039, and rung 3's +0.024/+0.041.  The first two
samples fell either side of the +/-30 ps spread and both fell short, so the
integration really did cost about twenty picoseconds; the third recovered ten
times that.  83 RAMB36 of 135 where the design had 59.  The long-chain tail
came out SHORTER than before the rung: 181 endpoints at >= 14 levels against
269.

**It was never the new cache.**  Counting long chains by source register - the
user's method - puts `u_cache` nowhere: the leaders were `u_vbl/locked_reg`
(2169), `u_merge/q_reg` (2127), `u_cpu/pcl_reg` (500), `u_dline/spl_v_reg`
(483), every one pre-existing.  The critical path was the one rung 3 recorded
as STILL OPEN - the data front's one-clock serve into the CPU's datapath,
`u_dline/dq_sx_reg -> u_cpu/md_reg`.  Routed, it read:

    dq_sx_reg[1][1] -> net (fo=128)          1.282 ns   the row LUTRAM's address
                    -> RAMD32 + route        1.050 ns
                    -> lb_byte i_29/17/6/2   2.246 ns   FOUR LUT levels of byte steering
                    -> d_din -> the CPU                ~1.0 ns

### The lesson: it was wide, not deep

The user asked whether the chain could be cut by giving the cache another cycle
of latency.  It could - the path halves at the LUTRAM almost exactly - but the
report says the price was not necessary, and why is the part worth keeping:

    every LUT on that path costs 0.105 ns, and there were five of them
    ONE NET cost 1.282 ns

Not a deep chain: a WIDE one.  1.282 ns is a single hop from a flop to 128
RAMD32 address pins that share it, before any logic runs.  dline already
replicates that register per way, and its own comment records the previous
round of this same argument - but per-way is as far as replication can go while
a way's row array is one 128-bit object, because every bit of that object
shares one address.

So the ARRAY is sliced rather than the register replicated: four 32-bit arrays
per way, each with its own address copy at a fanout of 32.  The same RAM bits,
the same latency, twelve more flops, no cycle given up - and +0.007 became
+0.238.  The accel battery came out at 98 checks 0 errors with the revalidation
books byte-identical (D 5481/5154/31740, I 777/483), which is what says the
change was a restructuring and nothing else.

**The rule to carry forward: when a first hop costs a third of the period and
the logic after it costs a tenth, the answer is not a pipeline stage - it is
asking what that one net has to reach.**

And what a cycle would have cost, since the question was asked: the limiter is
the FRONT, not the 256 KB cache.  The page cache is already a three-clock hit
and closed out of context at +1.425, so a cycle there is cheap and buys
nothing.  The front's serve is one clock by design and covers about 13% of ops
(8.9M of 66.3M in the ProDOS boot), so a second clock there is roughly 8-9% of
the machine's speed.  The expensive cycle was the only one that would have
helped.

### The next lever, if margin is ever wanted again

The user's second question - how much of the path is steering to the exact byte,
and could that happen in parallel - names it.  Byte steering was 2.246 ns of a
5.7 ns path, four LUT levels of 16:1 mux run AFTER the RAM read, even though
the byte index (`dq_ix_cam`) is registered from `d_pred` at the same moment the
row address is.  Two ways to collect it, unbuilt:

- Write the mux as two explicit 4:1 stages.  A 16:1 select needs two LUT6
  levels; synthesis built four plus MUXF7s out of the variable part-select.
- Better: fold the slice select into the ADDRESS.  The array is 8 deep x 128
  wide today, so every RAMD32 holds 8 of its 32 entries and the width is paid
  for in mux depth.  Reshaped to 32 deep x 32 wide, addressed by
  `{set, dq_ix[3:2]}`, the depth is native to a RAMD32, the steering collapses
  to ONE 4:1 level on `dq_ix[1:0]`, and it costs 32 RAMD32s instead of 128.
  The price lands where it is cheap: an install writes a line, so it becomes
  four writes instead of one - and installs are the miss path (2488 in a whole
  ProDOS boot), while SPLICES get cheaper (one 32-bit slice write instead of a
  128-bit read-modify-write, and there are nine million of those).

### Rung 5 on hardware, the animated Nox map

Loaded onto the card, ROM and all, and taken to the measurement screen by the
user's route (reboot, the main menu, Return, 1 - the memory note
`nox-measure-screen`).  The screen's own menus and maps are HGR, so the text
screen shows only graphics memory decoded as text: `screenshot`, not
`wait_for_text`.

**The memory census, and it is the whole point of the rung:**

    1024 pages, 256 KB; image ready
    hits 97,870,446   misses 569   served 92,745,055
    mismatches 5   late fills 0   drops 0
    pages: 569 filled, 0 FLUSHED, 280 line requests declined

- **569 fills, and 569 misses, and nothing else, ever.**  A 128 KB IIe is 512
  pages and the ROM is 64, so 576 is every page the machine has; the cache
  faulted in 569 of them once and then stopped missing.  Between two readings
  the hit count went from 9.5 million to 97.9 million and the miss count did
  not move.
- **ZERO FLUSHES.**  Nothing has ever been evicted, which is the rung's gate
  and the whole argument for the hashed index: bank 0's two pages per set,
  bank 1's two, the ROM's one, five ways of eight, and nothing collides.
- late fills 0 and drops 0 - the counters that must read zero.
- mismatches plateaued at **5**, the same five rung 2 measured on hardware.
- 280 declines: the cold-start line requests, before their pages were resident.
- The ROM load itself: `mmiss=64` immediately after the host sent it, exactly
  one fill per ROM page, and `mrom=1`.

**The fronts, unchanged from rungs 2 and 3 on the real machine:**

| | rung 5 | rungs 2-3 |
|---|---|---|
| D lines dropped per map change | **16.15** of 32 | 16.1 |
| of those, revived | **95.66%** | 95.7% |
| net refills per map change | **0.70** | 0.70 |
| I front drops / revives | **0 / 0** | 0 / 0 |

**Speed: 66-78x over four intervals, and NO CLAIM IS MADE FROM IT.**  Two
measurement hazards showed up and both are worth recording:

- The op counters are 32 bits and WRAP.  One interval read turbo going
  backwards, 2,760,226,267 to 498,727,694.
- `maps` and the drop/revive counters come back on a SLOWER POLL ROTATION than
  the op counters.  Consecutive reads gave map deltas of 328,358 / 328,374 /
  328,385 no matter how long the interval - a rotation's worth, not an
  interval's.  So maps-per-1000-cycles from consecutive reads is meaningless,
  and the normalised ratio rungs 1-3 used cannot be computed this way.  What
  IS valid is a ratio of two fields from the SAME snapshot, which is why the
  drop/revive figures above stand.

Rung 1's single sample on this screen was 86.25x.  Whether 66-78x is a
regression, the same, or a different phase of the same game is NOT ESTABLISHED
by these readings, and the matched A/B the run sheet has owed since rung 2 -
both bitstreams, the same route, the same elapsed time, counters cleared - is
still owed and is now the only way to settle it.

**One hardware incident, and its cause is known.**  Between two swhost
restarts the card dropped off the USB bus - `FAULTED: device gone` in the log,
then LINK DOWN, DDR3 not calibrated, the cycle counter frozen and the FT601
re-enumerating at a new address.  The FT601 is a separate chip from the FPGA
and enumerates whatever the FPGA is doing, so that picture is an FPGA that lost
its configuration: the bitstream lives in volatile SRAM (the memory note
`pi-reboot-wipes-bit`).  Reloading it and restarting swhost recovered
completely.  Nothing about the rung's RTL is implicated; the card is
USB-powered and sits near its budget (`power-budget`).

## How this ends

The user's decision, 2026-09-08: **rung 5 is an acceptable finish.**  The card's
memory is one 24-bit physical space, the machine and its ROM live in a 256 KB
physically-indexed cache that never evicts, and both fronts survive a map change
as rungs 2 and 3 built them to.  Performance on the real machine, across several
disk images the user drove himself, is close enough to the old design that no
regression is noticeable - which was the bar, since this refactor was for the
65816's sake and not for speed.

**What was deliberately NOT done, so nobody goes looking for it:**

- **Rung 6's doc rewrite.**  `docs/PAGE_CACHE.md`, `MEMORY.md`, `ISTREAM.md`,
  `ACCELERATION.md` and `BOOT_BENCH.md` still describe the two-bank design and
  the ROM's own block RAM.  Each now opens with a SUPERSEDED banner naming what
  replaced it; the living description is `rtl/page_cache.sv`'s header and this
  file.  A banner is not a rewrite and is not pretending to be one.
- **Part 4 of the plan** is not outstanding: it landed inside rung 5 (the new
  register words, `mem_ctrl_pages_log2`, the poll list, the atomics,
  `mem_report`'s pages/fills/flushes/declines, and `mem status` on the control
  socket).  The one leftover is a stale comment in the host's
  `src/apple_memory.hpp` about image banks 1-255, which is now the card's
  convention too.
- **The 64 x 8 build**, the cheap fallback geometry: proven in the geometry
  sweep and out of context (same LUTs, half the block RAM) but never built into
  a bitstream.  `MEM_SETS`/`MEM_WAYS` in `master_top` are the whole change.
- **The matched A/B for a speed claim**, owed since rung 2 and now closed
  unpursued: judged on the real machine instead.  No x-factor claim is made
  anywhere in this document, and the reasons the derived ratio cannot carry one
  are recorded above (32-bit counters that wrap; `maps` on a slower poll
  rotation than the op counters).
- **The rest of rung 5's scripted ladder** - `ramworks_test.sh`, `mem_test.sh`,
  `fb_test.sh` - not run.  `ramworks_test.sh` is the one that would matter most
  if this is ever picked up again, because RamWorks banks moved to physical
  k+1 and dropped to 254.

**Where the design goes next, if it goes anywhere:** the 65816 this was all
for.  `xlate()` already takes a 24-bit address and maps banks >= 2 to
themselves; the `flat` input the plan describes is unbuilt but the function's
shape allows it.  And if timing margin is ever wanted again, the byte-steering
lever above is written up and unbuilt.
