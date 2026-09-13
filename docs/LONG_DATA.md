# Long data: the data front serves the OTHER bank class

Status: 2026-09-13, branch `long_data`. RUNG 3 (THE CHIPSET'S FAST READS, ANY
PAIR BANK, AND THE SHADOW[6] CLAIM FIX) ON HARDWARE, UNCOMMITTED ("Rung 3, as
built"): Arkanoid's attract loop 77x with the serve against 52-56x without,
alternating windows on one bit (gs_lr3 MET +0.003); mirror mismatches 0;
XMAS 11/0 with dispatcher fast ops -75%; GS/OS 12/0; floor, battery 35/35,
the new gs_io claim bench and the map-oracle sweep green.  Rungs 1-2 are
fw 06fc761 / 472aafd.

RUNG 2 (WRITES INTO $02-$7F POSTED)
ON HARDWARE ("Rung 2, as built"): GS/OS 12/0 with its disk
unchanged, 1.42 M writes posted into $02-$7F, dispatcher fast ops -38%, clocks
-2.9%; XMAS 11/0; boot_gs at the KEGS floor; IIe battery 35/35 with accel_vl
unchanged (280,000,000 clocks).  Build `gs_lr2` TIMING MET wns +0.027 whs
+0.033, 0 of 96,505 failing, no data-front chain in the tail.  On the card, the
idle Finder: 17.6 M writes posted into $02-$7F in 50.7 s, mirror mismatches 0,
PLAIN 62.71x (rung 1's window: 61.57x; not an A/B).

RUNG 1 (READS) ON HARDWARE,
fw 06fc761: the two-entry bank table, `cvo` and the OTHER serve arm in
`rtl/dline.sv` ("Rung 1, as built").  Sims: boot_gs at the KEGS floor (10
checks), GS/OS 12/0 and XMAS 11/0 at 20 M instructions (the ways serve 85.2%
and 92.8% of their OTHER-memory reads), the IIe battery 35/35 with accel_vl's
clock count unchanged (280,000,000).  Build `gs_lr1` TIMING MET wns +0.004
whs +0.041, 0 of 96,505 failing, no new tail on the tag leg.  On the card, the
idle Finder at the unlimited target: 81.1% of OTHER-memory reads served by
the ways (90.0% find their bank in the table), mirror mismatches 0, PLAIN
61.57x in a 35.7 s window (no A/B yet: no lever turns the arm off alone).

RUNG 0 ON HARDWARE; THE TABLE IS TWO ENTRIES (user decision, from rung 0's
numbers):
`rtl/bank_census.sv` on the IIgs build (DBG_SEL[7:6] = 1), cross-checked count
for count against the bench's census on the suite point, the XMAS demo and
GS/OS (20 M instructions each); build `gs_bcensus0` TIMING MET wns +0.013
whs +0.035, 0 of 95,666 failing, the census in no deep path, ~+400 LUTs and
~+225 flops, bit stamp 2026-09-13 13:12:51 - loaded and measured on the GS/OS Finder at the
unlimited target from a fresh boot (see "On hardware"). The bench census is fw a8d2d76. The gate workload (GS/OS off `system6.hdv` in the bench) is
CLEAN to 20 M instructions: 11 checks, 0 errors, 1858 blocks read, 3 written.
Its 17 errors on master were all the bench's (docs/GS.md, "The GS/OS bench's
disk failures were the bench's"); the machine's run is clock-for-clock the
one the census below was taken on, so the numbers stand.

## The problem

`rtl/dline.sv` serves a IIgs data cycle in two clocks when its bank is of
class ZERO or DBR (`rtl/cpu65816.sv` `d_pred_bcls`). Each cache line carries
two precomputed bits - `cvz` (the line's virtual bank is zero, set at install)
and `cvd` (it is the DBR as it stands, recomputed on every map change) - and
the serve reads `dq_b0 ? cvz : (dq_d && cvd)` beside the valid bit. No bank
byte is compared in a serve cone; wider tags were rejected on the known worst
path (docs/GS.md, "Fronts with a bank byte").

A class-OTHER candidate - a bank loaded from `din` (absolute long, `[dp]`,
`[dp],Y`, the block moves), an index carried across a bank edge, or PBR data
with PBR non-zero - is refused by the ways. Two small paths serve some of it
today: the LAST BYTE (24-bit compare, one byte) and the LAST ROW (`lr_*`,
docs/DLINE.md: the line the dispatcher's last data read came from, a 20-bit
line compare), which catches the second byte of a 16-bit read after a miss.
Everything else rides the dispatcher at ~10 clocks.

## What the census says

At every edge the candidate registers (the core moves with `d_pred_v`), the
bench counts the class and direction. An OTHER cycle into `$C000-$CFFF` of a
pair bank ($00/$01/$E0/$E1) is I/O or slot ROM and is counted apart: no line
can serve it. For the rest ("OTHER memory") it asks whether the bank is among
the last 1, 2 or 4 DISTINCT OTHER memory banks - a k-entry table with
least-recently-used replacement, ZERO/DBR cycles in between touching nothing.

20 M instructions each, mode 2, unlimited target:

| workload | data cycles | ZERO | DBR | OTHER I/O | OTHER memory | in last 1 | last 2 | last 4 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| ROM boot (250 k instr) | 42 k | 50.5% | 48.9% | - | 0.6% | 94% | 98% | 98% |
| XMAS demo (`--fd35 --button=5500000`) | 12.0 M | 37.8% | 15.4% | 39.7% | **7.2%** | 87.6% | **99.8%** | 100% |
| GS/OS boot (`--hdv=system6.hdv`) | 26.6 M | 67.8% | 12.7% | 0.5% | **19.0%** | 87.9% | **94.9%** | 97.8% |

- **One entry is not enough; two is the knee.** The misses at one entry are
  code alternating between two banks: `MVN` (19% of GS/OS's OTHER memory)
  reads the source bank and writes the destination bank on every byte, and
  the demo's `LDA [dp],Y` / `STA [dp],Y` copy loops do the same. XMAS
  intervals that read 55% at one entry read 99% at two.
- **Writes matter.** GS/OS: 15% of OTHER memory is writes (`$B7 LDA [dp],Y`
  42%, `$54 MVN` 19%, `$97 STA [dp],Y` 11%, `$AF LDA long` 10%). XMAS: 51%.
- **Where the banks are.** GS/OS: $7F 25%, $E0 19%, $E1 14%, $00 9%, $7B-$7E
  17% - 44% of it in the pair banks, where the map and SHADOW apply. XMAS:
  $07/$0F/$0E/$03/$08, ordinary RAM.
- **Caveat.** The GS/OS bench is now clean to 20 M instructions and the
  machine's run did not change with the fixes, so these numbers stand - but
  its tail (13 M-20 M) is one flat loop, a third of the sample, and what
  GS/OS is doing there is not known. The figures are a bench boot and a demo
  until rung 0 repeats them on hardware, on the Finder and a desktop app.
- **Not this design, but found by it.** 40% of the demo's data cycles are its
  VBL wait, `LDA $E1C019` / `LDA $E1C02E`, `BPL` - OTHER-class I/O on the
  dispatcher. Serving those registers the way the pair's `$C000` is served
  (`dq_kbd`) is a separate, cheaper lever.

## On hardware (rung 0, 2026-09-13)

`gs_bcensus0` on the card; GS/OS 6.0.1 off `system6.hdv` from a fresh start
of swhost on `gs_census.conf` (on the Pi: `gs_test.conf` with
`accel_ratio = 0`, the unlimited target - every `system6.hdv` conf there is
capped at 2.8); the counters cleared at the Finder and read back to back in
under 0.2 s.

| window | data cycles | OTHER memory | of it writes | OTHER I/O | in last 1 | last 2 | last 4 | the table at the read |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| the Finder, idle, 120 s | 2,561 M | 17.2% | 13.8% | 0.0% | 84.7% | 91.0% | 95.3% | $08 $7F $E1 $05 |
| opening System, then Fonts (97 items), 66 s | 1,567 M | 20.4% | 16.4% | 0.0% | 82.9% | 96.2% | 98.3% | $E0 $7B $05 $E1 |

The position counters sum to the reads and writes to within what ran during
the read (162 k and 242 k).  The first readings, taken under `gs_test.conf`'s
2.8x cap, are WITHDRAWN: a census that sizes the accelerated front is taken
at the unlimited target.

- **The share:** 17-20% of data cycles, about a sixth of it writes - the
  bench boot's 19%.
- **Two entries is where the work is.** Opening folders, one entry catches
  83% and two 96%; the idle Finder's event loop rotates among more banks
  (91% at two).  Four entries add 2-4 points over two, and 2-5% of OTHER
  memory is in none of the last four.
- **The pair banks are in the table on every read** ($E0/$E1 beside GS/OS's
  $05/$08/$7B/$7F), so the pair-bank risk below is the main case, not a
  corner.
- **Still unmeasured:** an application with its own heap traffic.
- **The counters are 32 bits.** At the unlimited target the Finder predicts
  about 21 M data cycles a second, so item 0 wraps after about 200 s: read a
  window inside that, or widen the counters.

## The design

The user's idea, taken where the core actually knows the bank: **predict the
OTHER bank, do the per-line bank compare early into registered bits, and
verify the prediction with one small compare at serve.** The prediction is
not a look-ahead into the microcode - for `din`-loaded banks the core knows
the value one cycle before the access, in `d_pred`'s own late cone - but the
recent OTHER banks, which the census shows repeat.

1. **The bank table.** `BT_K = 2` entries `ob[e]` - DECIDED (the user,
   2026-09-13, on rung 0's hardware numbers: two entries catch 96% of the
   Finder's folder-opening traffic, and four would add only 2-4 points for
   twice the per-line bits and compares) - each with a valid bit and
   one LRU bit between them. An OTHER memory data cycle that the ways did not
   serve loads its bank into the table at its retire (a hit on an entry
   refreshes the LRU bit; a miss replaces the least recent). Registered,
   rooted at the retire, never on the serve path.
2. **Per-line bits, computed early.** Each line gets `cvo[e]`: its virtual
   bank (`cvbank`, already stored) equals `ob[e]`. Written in three places,
   exactly as `cvd` is:
   - at install: `cvo[e] <= (m_vbank_q_t == ob[e])`;
   - when entry `e` is replaced: every line's `cvo[e]` recomputed on the
     next clock (32 lines x one 8-bit compare against a register - shallow);
   - revalidation leaves `cvo` alone (a map change moves `cv`, not a line's
     virtual bank).
   While entry `e`'s bits are being rewritten it is unusable for one clock
   (`ob_settle[e]`) - a miss, never a stall.
3. **The serve.** The candidate keeps its register-only discipline:
   `dq_o <= (d_pred_bcls == BCLS_OTHER)` at `cyc_en`, like `dq_d`. In the serve
   cycle, register-rooted, `om[e] = ob_ok[e] && (dq_addr[23:16] == ob[e])`
   - two 8-bit compares of registers, fanout one each - and the way's hit
   becomes

   ```
   dq_b0 ? cvz : dq_d ? cvd : (dq_o && ((om[0] && cvo[0]) || (om[1] && cvo[1])))
   ```

   The exact bank still decides the serve, so a wrong prediction is only a
   miss. ZERO and DBR paths are untouched and keep their two clocks.
4. **I/O stays out.** A pair bank's `$Cxxx` never serves (the existing
   `dq_addr[15:12] != 4'hC` rule on the paths that need it), and an I/O cycle
   does not load the table.
5. **Writes, separately.** Posted writes retire today only in bank zero
   outside the shadowable regions. Banks $02-$7F have no SHADOW duplicate
   and nothing in them moves under a map change, so writes there - DBR class
   as well as OTHER - can post through the existing FIFO. Pair-bank OTHER
   writes stay on the dispatcher.

**The fallback is the user's original shape: a second pipeline clock for
OTHER only.** If the two compares on the tag leg cost the path, register
`om[e]` a clock later and serve OTHER at three clocks. It is still a third
of the dispatcher's cost, and ZERO/DBR keep their two clocks either way.

## Rungs

Each rung: sims green (Verilator: dline bench, the battery, `boot_gs_tb` at
the suite point and the KEGS floor), the build MET with the long-chain census
read by source register, then hardware. Explain before every run.

| rung | what | gate |
|---|---|---|
| 0 | **The healthy gate workload, and the census on the card.** Fix the GS/OS bench landing failure. Commit the bench census. Card counters for OTHER-memory data cycles and table hits at 1 and 2 entries (a debug item), read on the Finder and one ORCA/C desktop app | bench GS/OS boot clean past 20 M instructions; HW numbers in this doc - **DONE: the bench (a8d2d76), `bank_census` MET and cross-checked, the Finder measured on hardware at the unlimited target ("On hardware"); a desktop application still unmeasured.** Read it: clear with a W1 of ACCEL_CTRL[31] (read ACCEL_CTRL first and write it back with bit 31 set - the register also holds the mode, target and `fronts_dis`), then `regw 80000130 4N` / `reg 80000134` for item N: 0 data, 1 OTHER-memory reads, 2 writes, 3 I/O, 4 last, 5 second, 6 third-or-fourth, 7 miss, 8 the table |
| 1 | **Reads.** The table (K = 2), `cvo`, `dq_o`, the serve arm; installs allowed for OTHER-class misses (check `live_cmiss`/C_OPW for class gates); `cnt_ob_serves` counted | OTHER-memory reads served / predicted, from the bench and the card; KEGS floor and battery unchanged; timing MET, no new deep tail on the tag leg (else the 3-clock fallback) - **GREEN IN SIMULATION 2026-09-13 ("Rung 1, as built"): GS/OS 85.2% served, XMAS 92.8%, floor and battery unchanged; build and card pending.** Read it: `regw 80000130 8N` / `reg 80000134`, N as listed there |
| 2 | **Writes into $02-$7F posted**, every class | GS/OS bench clean; mirror mismatches unchanged on HW; the desktop ratio - **GS BENCHES GREEN 2026-09-13 ("Rung 2, as built"): GS/OS 12/0, disk unchanged, 1.42 M posts into $02-$7F, dispatcher fast ops -38%; XMAS 11/0; floor unchanged; IIe battery 35/35, accel_vl 280,000,000 clocks; `gs_lr2` MET +0.027; ON THE CARD: 17.6 M posts into $02-$7F in 50.7 s on the Finder, mirror mismatches 0, PLAIN 62.71x.** Read it: `regw 80000130 86` / `reg 80000134` |
| 3 | **Optional.** The `$E1C019`/`$E1C02E` poll served like `$C000` (K stays 2: decided) | the demo's PLAIN ratio - **DONE ON HARDWARE 2026-09-13, widened (the user's rule) to every side-effect-free chipset register in any bank the I/O page is in, with the SHADOW bit 6 claim bug fixed: Arkanoid 77x on / 52-56x off on one bit, XMAS dispatcher fast ops -75% ("Rung 3, as built").** Read it: `regw 80000130 87` / `reg 80000134`; the A/B lever is swint, ACCEL_CTRL[28] |

## Rung 1, as built (2026-09-13)

All in `rtl/dline.sv`, at `GS` only (on the IIe `dq_o` is a constant zero and
every new term folds away).

- **`dq_o` is not a new register.** The core's class code takes three values,
  so OTHER is `!dq_b0 && !dq_d` - no third load on `d_pred_bcls`'s late cone.
- **The table updates from the candidate, not from the retire.** On the clock
  after the core moved (`fc_q`) `dq_*` names the cycle about to run; the update
  is rooted there, nowhere near `cyc_en`.  A bank already in the table refreshes
  its recency, a new one takes an empty entry or else the least recent.  Reads
  and writes both take part (the census counted both, and `MVN` needs its
  destination bank beside its source).
- **Two exclusions from the table:** I/O (a pair bank's `$Cxxx`) and ROM 3's
  banks `$FC-$FF`.  No line is ever held for either, so an entry spent on them
  could serve nothing - this can only raise the hit rate over the census's.
- **`cvo[e]`** is written at the install against the entry as it stands, and for
  every line on the clock after entry `e` is replaced (`ob_set`); `ob_ok[e]` is
  low for that one clock.  The install is assigned after the rewrite in the same
  block, so a line installed on the rewrite's own edge keeps its own answer.
  Revalidation leaves `cvo` alone.  All `cvo` writes are in the claim engine's
  one `always_ff` (multi-driven registers gate).
- **The serve arm** is the third branch of each way's hit:
  `dq_b0 ? cvz : dq_d ? cvd : (om[0] && cvo[0]) || (om[1] && cvo[1])`, with
  `om[e] = dq_o && ob_ok[e] && (dq_addr[23:16] == ob[e])`.
- **No new claim rule was needed.** `live_cmiss` has no class gate, so OTHER
  misses already installed lines (which nothing could serve).  A mid-stall rise
  of the hit (an entry settling while the dispatcher runs the op) cannot
  double-serve: a front retire needs `turbo_ok`, which is `S_DECIDE` only, and
  at GS the registered claim.  A duplicate line (claimed while its bank was not
  yet in the table) is the same physical line, spliced by the same physical tag,
  so the ways' one-hot OR sees two equal bytes.
- **The books, DBG_SEL[7:6] = 2** (`regw 80000130 8N` / `reg 80000134`), all
  cleared by the ACCEL_* pulse: 0 OTHER-memory read candidates (the table's
  eligible reads), 1 of them with the bank settled in the table on their first
  clock, 2 served by the ways through an entry, 3 served by the front at all
  (last row and last byte included), 4 entries replaced, 5
  `{ob[0], ob[1], 11'd0, lru, v[1:0], ok[1:0]}`.  The GS bench prints the same
  as `bank table:`.

**In simulation** (Verilator, mode 2, the unlimited target, 20 M instructions;
against the census runs `bcard_*` on fw d01d653):

| run | result | OTHER-memory reads | bank in the table | served by the ways | entries replaced | dispatcher fast ops | clocks |
|---|---|---:|---:|---:|---:|---|---|
| suite point (250 k, KEGS floor 67,398) | PASS at the floor, 10 checks 0 errors | 15 | 15 | 13 | 3 | 16,485 -> 16,479 | - |
| XMAS demo (`--fd35 --button=5500000`) | PASS, 11 checks 0 errors | 404,915 | 404,071 (99.8%) | 375,581 (**92.8%**) | 1,364 | 6.62 M -> 6.59 M | 232.7 M -> 232.5 M |
| GS/OS (`--hdv=system6.hdv`) | PASS, 12 checks 0 errors, disk 1858 read / 3 written / 451 statuses / 2312 execs as before | 4,250,748 | 4,036,281 (95.0%) | 3,620,759 (**85.2%**) | 238,627 | 4.46 M -> 3.75 M | 410.3 M -> 405.7 M |

- **The traces part company, on timing.** XMAS at instruction 2,382,232, in a
  bank-zero wait loop polling a timer (`$00/0879`); GS/OS at 998,647, where the
  baseline takes an interrupt inside a `STA [dp],Y` clear loop and this run
  takes it laps later.  The machine's interrupt sources run on clocks, so a
  faster front moves them; the work either side is count for count the same
  (XMAS's OTHER memory in the 2 M-3 M interval: 66,547 / 44,361 writes in both
  runs; GS/OS's disk traffic identical).  So trace equality is not this rung's
  oracle, and the GS bench has no per-byte one either (boot_tb's reference
  memory has no GS twin) - the bench's checks, the disk and the KEGS floor are.
- **Where the rest goes.** GS/OS: 5% of OTHER reads find their bank not yet in
  the table (238 k replacements - the idle loop rotates among more than two
  banks, as the card's census said), and a further 10% find the bank but no
  line in the 8x4 cache: the pair-bank lines compete with bank zero's for the
  same 32 lines.  That second number is cache capacity, not the table.
- **The build, `gs_lr1`: TIMING MET** wns +0.004 whs +0.041, 0 of 96,505
  failing, max depth 18 (4171 paths >= 10, 188 at >= 14); synthesis 0
  undriven nets, 0 multi-driven registers.  The worst path is the instruction
  front's (`u_iline` `exp_q -> i_byte_q`, 14 levels), not the tag leg.  The
  long-chain census for the data front: `sv_hit_q` 11 levels (slack 1.881),
  `claim_q` and `sv_byte_q` not in the >= 10 list, `cmiss_q` 11 (2.162); the
  table registers (`ob*`, `cvo`) nowhere in it.  The new counters
  `cnt_ob_serves`/`cnt_ob_any` sit at 11 levels (slack 0.913/1.144), rooted at
  the core's `ir` into their clock enables through `r_retire` - the shape
  `cnt_cam_serves` (11, 1.314) and `cnt_lr_serves` (11, 1.242) already have.
  No fallback needed.
- **On hardware** (`gs_lr1` loaded, swhost fresh on `gs_census.conf`, GS/OS
  to the Finder with GSHardDrive's window open, idle, the unlimited target;
  counters cleared at the Finder and read back to back in 7 ms by a one-shot
  script on the Pi's control socket), a 135 s window:

  | counter | count | share |
  |---|---:|---:|
  | data cycles (census item 0) | 2,871,528,332 | |
  | OTHER-memory reads the table may serve | 421,738,951 | 14.7% of data cycles |
  | ...bank settled in the table | 379,481,712 | **90.0%** (rung 0's two-entry figure: 91.0%) |
  | ...served by the ways | 342,108,322 | **81.1%** (90.2% of those found) |
  | ...served by the front at all | 344,193,730 | 81.6% |
  | entries replaced | 43,595,531 | one per ten reads |
  | the table at the read | `$E1 $7F`, both valid and settled | |

  The census's own OTHER-memory reads (424,786,436) exceed the table's
  candidates by the ROM banks `$FC-$FF` it excludes.  **The mirror stayed
  clean:** `mmismatch=0` after the boot and the window, and dropped, torn,
  lost, unknown, verr, refused, link resets, overflows and retries all zero
  (`fbmismatch` is the floating-bus compare, present on the census bit before).
  The desktop draws correctly.  **The accel report's 32-bit counters wrap in a
  window this long at this speed** (PLAIN's core count read 4,048,838,692 over
  134,959,302 bus cycles, which is "30.00x" only modulo 2^32): ratios are read
  from a window under ~70 s.  A second window of 35.7 s on the same scene:
  **PLAIN 61.57x** (2,198,602,831 core over 35,711,670 bus cycles), the census
  48.38x (967 M turbo + 687 M dline + 83 M dispatcher fast + 32 k bus ops);
  fast by kind RAM 26.4 M, WR 25.1 M, I 18.8 M.  So the 135 s window was
  ~61.8x before the wrap.  This is NOT an A/B: no lever turns the OTHER arm
  off alone, and the last recorded desktop figure (60.5x, fw 13146b4) is a
  different bit and scene.  An A/B wants a chicken bit on the arm (`om` forced
  to zero) - cheap, one register term - if the gain has to be named.
- **The clock saving is small in GS/OS's boot** (-1.1% of clocks for the same
  instructions: 710 k dispatcher ops at ~7 clocks each); the ratio that matters
  is the card's on the Finder, where OTHER memory is 17-20% of data cycles.

## Rung 2, as built (2026-09-13)

Writes into banks `$02-$7F` post, of every bank class.  One term in
`rtl/dline.sv`:

```
w_hi   = GS && !dq_addr[23] && (dq_addr[22:17] != 0)       // banks $02-$7F
w_serv = wr_en && dq_wv && !rwb_nz_q &&
         ((dq_addr[15:14] != 2'b11 && (!GS || dq_b0)) || w_hi)
```

- **Why a virtual qualifier is exact there.** `rtl/apple_mmu.sv` xlate classes
  `$02-$7F` as RAM, its own physical bank, write-enabled, no switch and no
  SHADOW bit, under every map; `GS_RAM_BANKS` is 128 and never overridden, so
  none of those banks is void.  So the whole 64 KB posts, `$C000` up included,
  and a write there never owes a duplicate (`d_sh` is 0, `dup_go` never fires).
- **Nothing downstream assumed bank zero.**  The stamp is the MMU query's
  `d_ppn` (bank in its high byte); the splice into the shadow, the ways and
  the last row, the claim abort and the instruction front's snoop all compare
  physical pages; the page cache keys a posted write by `cl_ppn` and sends a
  non-resident page to its miss engine like any write (`pw_ready` waits for
  the engine to be idle); the host mirror classifies every write with its bank
  (`classify_at(e.bank, ...)`).  `apple_mmu`'s drain still derives the IIe's
  `cl_aux`/`cl_bank` pair from the page, which reads nonsense for bank `$7F` -
  but the instruction front is its only consumer and never reads it.
- **The splice-clock assertion widened to 24 bits** (`spl_addr`): with other
  banks posting, a 16-bit compare would fire on `$7F/1234` written then
  `$00/1234` read.
- **Pair-bank OTHER writes stay on the dispatcher** (a long write into
  `$00/$01/$E0/$E1` names the map and SHADOW), as the design said.
- **The book:** `cnt_post_hi`, writes retired into `$02-$7F`, DBG_SEL item
  `0x86`; the GS bench prints it on the `bank table:` line.

**In simulation** (Verilator, mode 2, unlimited, 20 M instructions; against
rung 1's runs `lr1_*`):

| run | result | writes posted into $02-$7F | all posted writes | dispatcher fast ops | clocks | posted misses |
|---|---|---:|---:|---|---|---|
| suite point (250 k) | PASS at the KEGS floor 67,398, 10 checks 0 errors; every counter as rung 1's | 0 | 10,682 | 16,479 | - | 1,032 |
| XMAS demo | PASS, 11 checks 0 errors, clashes 0 | 372,902 | 988,618 -> 1,352,903 | 6.59 M -> 6.24 M | 232.5 M -> 229.2 M (-1.4%) | 1,445 -> 2,535 |
| GS/OS | PASS, 12 checks 0 errors, disk 1858 / 3 / 451 / 2312 as before, clashes 0 | 1,416,056 | 6.82 M -> 8.24 M | **3.75 M -> 2.33 M (-38%)** | **405.7 M -> 394.0 M (-2.9%)** | 1,553 -> 3,746 |

- **The posted misses doubled**, as they should: a posted write into a bank
  whose page is not resident is the page cache's miss engine's to land, and
  `$02-$7F` pages are resident less often than bank zero's.  The bench's checks
  and the disk's landing checks are clean over it.
- **The IIe battery 35/35**, accel_vl 98 checks and 280,000,000 clocks as
  before (`w_hi` is a constant zero there).
- **The build, `gs_lr2`: TIMING MET** wns +0.027 whs +0.033, 0 of 96,505
  failing; synthesis 0 undriven nets, 0 multi-driven registers.  The worst path
  is the instruction front's (`u_iline` `miss_tag_q -> f_reg`, 12 levels).
  The write side of the data front is shallow: `spl_v` 11 levels (slack
  1.330), `spl_ppn` 11 (1.688), `cnt_post_hi` 11 (1.716), the posted FIFO and
  `spl_sh` not in the >= 10 list.  Depth: 3177 paths >= 10 (gs_lr1 4171),
  366 at >= 14 (gs_lr1 188).  **That tail is not this rung's**, counted by
  source and end register: 193 are the bus event filter (`source_real ->
  u_filter`), 66 the audio accumulators, 36 the dispatcher's state into the
  core's microcode ROM, the rest DDR3, the TX ring and the arbiter; the data
  front has only its two old chains there (the core's `ir` into `dq_addr`, the
  prediction's late cone; `cv_q` into the revalidation counter).  None of those
  families was touched: placement spread.  (gs_lr1's own report was
  overwritten, so the comparison is by family, not path for path.)
- **On hardware** (`gs_lr2` loaded, swhost fresh on `gs_census.conf`, GS/OS
  to the Finder - the desktop byte-identical to rung 1's screenshot - idle, the
  unlimited target; cleared at the Finder, read back to back in 7 ms), a
  50.7 s window, beside rung 1's 35.7 s one:

  | | rung 1 | rung 2 |
  |---|---:|---:|
  | **PLAIN** | 61.57x | **62.71x** |
  | the census ratio | 48.38x | 51.09x |
  | writes posted into $02-$7F (item `0x86`) | - | 17,611,576 (0.35 M/s) |
  | dispatcher fast writes (WR) | 0.70 M/s | 0.44 M/s (-37%) |
  | dispatcher fast ops per bus cycle | 2.33 | 2.08 |
  | dline ops per bus cycle | 19.1 | 20.5 |
  | OTHER-memory reads served by the ways | 81.1% | 81.1% |

  The census counts 25,971,074 OTHER-memory writes in the window: the 17.6 M
  posted are the part in `$02-$7F`; the rest are long writes into the pair
  banks, which stay on the dispatcher (and DBR-class writes into `$02-$7F` are
  in item `0x86` but not in the census's OTHER count).  **The mirror stayed
  clean:** `mmismatch=0` after the boot and after the window; dropped, torn,
  lost, unknown, verr, refused, link resets, overflows and retries all zero;
  `fbmismatch` (the floating-bus compare) as on the earlier bits.  PLAIN is up
  1.9% on rung 1's window - a different bit and window, so NOT an A/B, but the
  bench's direction (-2.9% of clocks on GS/OS's boot).
- **Rungs 1 and 2 together on GS/OS's boot:** dispatcher fast ops 4.46 M ->
  2.33 M, clocks 410.3 M -> 394.0 M for the same 20 M instructions.

## Rung 3, as built (2026-09-13)

The chipset's side-effect-free registers served by the data front, in any bank
the I/O page is in and of any bank class - the user's rule: `$00`, `$01`,
`$E0` and `$E1` name one register - and the claim bug that rule exposed.

- **One definition of the I/O page, `rtl/gs_iopage.vh`.**  `gs_is_io(bank,
  flat)`: `$E0/$E1` always, `$00/$01` only while SHADOW (`$C035`) bit 6 is
  clear (KEGS `fixup_shadow_iolc`; with it set the fast pair's `$C000-$FFFF` is
  RAM).  Included by `rtl/gs_io.sv` (its claim) and `rtl/dline.sv` (its serve),
  and checked against the KEGS-derived oracle in `sim/mmu_xlate_gs_tb.sv` at
  every `$C0xx` point of every map it sweeps.
- **THE BUG IT FIXED.**  `gs_io` claimed `$C0xx` in any pair bank with no
  SHADOW term (`pair_bank(bank)`), and `master_top` ORs that claim into the
  dispatcher's internalized-op flag, whose byte beats memory's
  (`swi_q ? swi_byte_q : mem_sub_data`).  Under the inhibit a `$00/C019` read
  took the chipset's byte over the RAM's, and a `$00/C047` access - a RAM
  write - ran the register's side effect and cleared the timer interrupts.
  Found by reading; no software measured here sets the bit.  (The IIe
  build's own internalized reads and slots, `apple_mmu` `q_swi`/`q_slot`, are
  off at GS - `sw_int = !GS && ...` - so this was the only claim with the hole;
  the host mirror's classify already had `in_io && !flat`.)
- **The fast-read set** (`gs_fr_sel`): `$C011-$C01F` (the status page, `$C019`
  with the VBL bit), `$C021`, `$C022`, `$C023`, `$C025`, `$C027`, `$C029`,
  `$C02B`, `$C02D`, `$C02E`, `$C02F`, `$C035`, `$C036`, `$C041`, `$C061`,
  `$C062`, `$C068` - every register whose read changes nothing.  Out, because the
  read does something: `$C010`, `$C024`, `$C026`, `$C030`, `$C033/$C034`,
  `$C038/$C039`, `$C03C-$C03F`, `$C046`, `$C047`, `$C0Ex`; `$C000` keeps its
  own serve with the `kbd_rd` pulse its auto-repeat counts.
- **The bytes, `gs_io` `fr_vec`:** 31 x 8 bits composed as the read mux
  composes them (the switches from new `apple_mmu` `swi_stat_bits`, `$C023` and
  `$C041` from new `gs_intc` outputs, `$C027` from a new `gs_adb` output),
  registered once in `master_top` like `kbd_byte_q`.  A simulation assertion
  in `gs_io` compares the vector's byte with `rd_byte` on every internalized
  read the dispatcher retires, in every bench.
- **The serve, `dline` `io_hit`:** from the registered candidate in the serve
  cycle - `gs_is_io` on `dq_addr`'s bank with a registered SHADOW bit, `$C0` in
  the high byte, `gs_fr_sel` on the low - and nothing on `d_pred`'s cone; one
  more arm of the one-hot byte OR, two clocks like every IIgs read.  `$C000`'s
  `kb_hit` moved onto the same bank rule (it was bank-class zero only).  Both
  ride the swint lever (`gs_kbd_en`, ACCEL_CTRL[28]), which is the A/B.
- **The staleness guard.**  An internalized write (`$C029`, `$C035`, a
  `$C00x` switch) lands on the edge after the dispatcher's `swi_commit` and
  reaches `io_vec` a clock later, so a fast read serves only while `swi_commit`
  has been low this clock and the one before (`io_quiet`, on `kb_hit` too).
- **Books:** `cnt_io_serves`, DBG_SEL item `0x87`; the GS bench prints it.

**The two new checks, green:** `sim/gs_io_claim_tb.sv` (in `suite.sh gs`),
written from the KEGS rule and not from `gs_io`'s register list - 18,439
checks, 0 errors: the claim is zero in `$00/$01` under the inhibit and outside
`$C0xx` everywhere, the four banks claim exactly what `$E1` claims (70
addresses) at SHADOW `$00/$40/$3F/$7F`, and a pending VBL interrupt survives a
`$00/C047` read and a `$01/C047` write under the inhibit while `$E1/C047`
(inhibit on) and `$00/C047` (inhibit off) clear it.  `mmu_xlate_gs_tb` full
sweep: 3584 maps, 67,135,501 checks (+43,008, the I/O page), 0 mismatches.

**In simulation** (Verilator, mode 2, unlimited, against rung 2's runs):

| run | result | chipset fast reads | dispatcher fast ops | data-front ops | clocks |
|---|---|---:|---|---|---|
| suite point (250 k) | PASS at the KEGS floor 67,398, 10 checks 0 errors, the trace parting at the same event | 222 | 16,479 -> 16,258 | 25,561 -> 25,783 | - |
| XMAS demo (20 M instr) | PASS, 11 checks 0 errors, no assertion (the fast-read vector agreed with the read mux on every internalized read), clashes 0 | **5,522,148** | **6.24 M -> 1.58 M (-75%)** | 5.72 M -> 9.39 M | 229.2 M -> 191.5 M (-16.4%) |
| GS/OS (20 M instr) | PASS, 12 checks 0 errors, disk 1858 / 3 / 451 / 2312 as before, clashes 0, no assertion | 13,251 | 2,326,445 -> 2,313,897 | 24.64 M -> 24.64 M | 394.0 M -> 393.8 M |

The IIe battery 35/35, accel_vl 98 checks on 280,000,000 clocks as before
(every rung-3 term is `GS`-gated).

**The build, `gs_lr3`: TIMING MET** wns +0.003 whs +0.047, 0 of 96,774
failing; synthesis 0 undriven nets, 0 multi-driven registers.  The worst path
is the instruction front's (`u_iline` `want_tag -> f_ppn`, 14 levels).  The
rung's own cones are shallow: `sv_hit_q` 11 levels (slack 1.908), `claim_q` 10
(1.739), `cmiss_q` 12 (1.094), `kbd_rd` 11 (2.117), `cnt_io_serves` 11 (1.040,
the front counters' usual shape); `sv_byte_q`, `io_flat_q`, `swi_busy_q` not in
the >= 10 list; nothing of `gs_io`'s claim as a deep chain into the dispatcher.
Max depth 22 (gs_lr2 18): all 41 paths at >= 18 are the DDR3 controller's
calibration compare, `index_wb_data -> correct_read_data / wrong_read_data`,
carry-dominated with ~2 ns of slack - the family that sat at 18 in gs_lr1, in
files this rung does not touch.  The >= 14 tail, 327, is gs_lr2's families
(the event filter, the dispatcher into the microcode ROM, DDR3, audio).

The demo's clock figure is not a pure speed measure: its VBL wait runs
against a beam counted in bus cycles, so a faster machine spends more of the
same 20 M instructions waiting (its OTHER-memory reads fell 402 k -> 249 k over
the run).  The dispatcher's ops moving onto the front is the direct evidence.

**On hardware: the A/B on one bit.**  `gs_lr3` loaded; swhost fresh on
`gs_os.conf` (Arkanoid on the slot-7 SmartPort, the unlimited target); the
mirror at 0 mismatches after the boot.  The lever is swint (ACCEL_CTRL[28],
`gs_kbd_en`), which gates the fast reads and the `$C000` serve together.  A
script on the Pi alternated four 20.0 s windows - write ACCEL_CTRL with the
lever and the counter clear in one word, wait, read, screenshot - so no tool
latency sits between them:

| window | swint | PLAIN | chipset fast reads (`0x87`) | OTHER-class I/O (census) | dispatcher fast ops (KBD) | posts into $02-$7F | the scene at its end |
|---|---|---:|---:|---:|---:|---:|---|
| 0 | on  | **76.60x** | 195,977,649 | 195,979,706 | 432 k (12 k) | 497 k | the attract-mode game |
| 1 | off | **55.65x** | 0 | 130,690,295 | 129.6 M (91.7 M) | 288 k | the attract-mode game |
| 2 | on  | **77.11x** | 195,953,303 | 195,980,612 | 2.0 M (16 k) | 284 k | the attract-mode game |
| 3 | off | **51.78x** | 0 | 131,272,650 | 124.2 M (111.7 M) | 408 k | the high-score table |

- **About 77x with the serve, 52-56x without, on the same bit, twice over,
  across the attract loop's scenes** (a first 40 s pair, 77.52x / 53.80x, had
  the scene change inside it and is superseded by this interleaved run).  With
  the lever on the front serves all but ~2,000 of ~196 M long-addressed I/O
  cycles per 20 s, and the dispatcher's KBD ops fall from ~100 M to ~15 k.
  Rung 2's bit measured the title screen at 52.10x.
- **Correct on the card:** `mmismatch=0` after every window; dropped, torn,
  lost, unknown, verr, refused, link resets, overflows, retries all zero.
- **The floating-bus compare, explained in passing:** `fbmismatch` stays near
  7,600 while the serve is on and climbs by tens of millions in each lever-off
  window (335 M after the four) - the IIe floating-bus simulator comparing
  against every `$E1C019` the dispatcher answers.  Not a memory mismatch; still
  not chased.

## Arkanoid on hardware (2026-09-13, the rung 2 bit)

`gs_lr2` on the card; swhost fresh on `gs_os.conf` (Arkanoid's 800K `.po` on
the slot-7 SmartPort as `hd1`, the unlimited target - the IWM route,
`gs_ark.conf`, does not boot at unlimited, docs/IWM35.md); the title screen
("PRESS 1 FOR ONE PLAYER OR 2 FOR TWO PLAYERS"), byte-identical screenshots
before and after, so a static screen waiting for a key.  Counters cleared on
it, a 53.3 s window:

| | Arkanoid title | GS/OS Finder, same bit |
|---|---:|---:|
| **PLAIN** | **52.10x** (a pre-rung bit: 51.4x, docs/IWM35.md) | 62.71x |
| the census ratio | 45.95x | 51.09x |
| turbo ops (instruction front) | 2.10 G | 1.45 G |
| dline ops (data front) | **11.3 M** | 1.04 G |
| dispatcher fast ops | 352 M | 106 M |
| ...of them KBD (the `$C00x`/`$C01x` status reads) | **318.5 M (90.5%)** | 0.19 M |
| data cycles (census) | 355.2 M | 1,092 M |
| ...OTHER-class I/O | **338.8 M (95.4%)** | 0.15 M |
| OTHER-memory reads served by the ways | 1.08 M of 1.38 M (78.5%) | 81.1% |
| writes posted into $02-$7F | 754 k | 17.6 M |
| mirror mismatches | 0 | 0 |

**What the machine is doing:** a VBL wait through a long address.  Forty
samples of the data front's registered candidate (DBG_SEL `0x33`, `top_w3_q`)
read `$E1C019` - RDVBLBAR, the Mega II bank's VBL status - fifteen times, with
class OTHER on every sample; the rest were the loop's own bytes at
`$02/6EF5-6F00`.  That read is OTHER-class I/O, which no line holds and which
the one-clock keyboard serve (`kb_hit`, bank class zero and `$C000` only)
refuses, so it rides the dispatcher as a KBD fast op at ~8 clocks - six of
them per bus cycle, on the order of half the machine's clocks.  Rungs 1 and 2
barely touch this scene, which is why it sits at the pre-rung bit's 51x.

**So rung 3 is not only the XMAS demo's.**  Serving `$E1C019` (and `$E1C02E`)
from the card in the data front's two clocks - the register is the chipset's
VBL bit, which the card already computes - is the lever for Arkanoid's title
loop too: an estimate, not a measurement, of up to half the scene's clocks.

**Not this plan's, noted:** `fbmismatch` climbed to 322,617,565 over the run
(GS/OS: ~7,900) - the IIe floating-bus simulator's compare firing on a IIgs
under `fb = serve`; not a memory mismatch (`mmismatch` 0), not chased.

## Risks and open questions

- **The tag leg.** The ways' hit is the design's known worst path (+0.002 on
  the last GS bit). Two register compares and one more select arm is small,
  but it lands on that leg; rung 1 reads the long-chain census before
  anything else, and the fallback is ready.
- **Table updates against in-flight claims.** A claim stamped under one table
  state installs under another; the install's `cvo` must be computed from the
  table as it stands at the install, and an entry replaced during a claim
  must not leave a stale `cvo` on the new line (the same shape as the map's
  claim abort).
- **`bank_wr` and the PBR sub-case.** PBR data with PBR non-zero is OTHER
  today; once PBR is in the table like any other bank it needs no special
  case, but a JSL that changes PBR must not leave a PBR-class line served
  from the old bank (`bank_wr` already settles the fronts).
- **Pair banks.** 44% of GS/OS's OTHER memory is in $00/$01/$E0/$E1, where
  the line's validity already follows the map; reads there are served by the
  same `cv` rule, but this is the part to watch in the audit.
- **Is 2 enough on real software?** DECIDED: two.  Rung 0's card counters
  at the unlimited target read 96% at two entries opening folders and 91%
  on the idle Finder, four adding 2-4 points (see "On hardware").
