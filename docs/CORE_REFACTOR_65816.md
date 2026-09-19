# The 65816 card: the core / L1 / L2 refactor ladder

Status: **RUNGS 0-3 DONE IN SIMULATION AND BUILT 2026-09-19 (uncommitted), branch `core_refactor`: the gs card is l1i + l1d over a 16-entry {bank, page} TLB and the shared page cache at 128 x 8; Pt bit gs_r3b TIMING MET +0.000 at 32,918 LUTs routed (from 42,860 synthesised at rung 0; L1 10.9k -> 3.4k), 112.5 RAMB36; gs suite 18/18, GS/OS 13/0 and XMAS 12/0; GS/OS runs 12% behind the old tree at equal clocks because sixteen TLB entries thrash on it (1.08 M fills in 17.5 M instructions) - the census rows at 32 and 64 entries are the next number; the bit is NOT on the machine. Rung 0's baseline: 42,860 LUTs / 33,025 flops / 110 RAMB36 against the 50T envelope's 32,600 / 65,200 / 75.** The sibling
ladder, done, is docs/CORE_REFACTOR_65C02.md; the requirements are docs/REQ_65816.md (this card's
differences) over docs/REQ_65C02.md (the common items); the design idea is docs/L1_RETHINK.md.
The user's direction (2026-09-19): develop and test on the Pt, watch resources against a 50T
Au variant for both cards, bitstream builds on the Pt resume.

## The gate, every rung

- Sims green under Verilator on the gs tree: `sim/suite.sh gs` (18: the 816's microcode, cycles,
  trace and interrupt benches; the ADB, DOC, IWM and I/O-claim benches; mmu_xlate_gs; boot_gs at
  the KEGS floor of 67,398 events; the control panel rows), the GS/OS row
  (`sim/run_boot_gs_tb.sh --hdv=sim/boot_work/system6.hdv --instrs=20000000 --ref=none`) and the
  XMAS row (`--fd35=sim/boot_work/xmas/XMAS_DEMO.po --instrs=8000000 --clks=120000000`), and
  `sim/lint.sh` (the gs top is linted over rtl/common + rtl/gs).
- The footprint by synthesis every rung (`build/build.sh --gs --synth-only`,
  build/results/synth_util_hier.rpt), against the rung-0 table below and the 50T envelope.
- A Pt bitstream for every rung that changes behaviour (`build/run_build.sh gs_rN --gs`), TIMING
  MET read from build/wns.sh, never the exit status; this card has no depth baseline of its own
  yet (REQ_65816 §1.8) and the ladder should give it one.
- On hardware: the Finder (58.6x) and Arkanoid's attract (77x) at unlimited, the census. The
  machine is the user's; a bit is loaded only with swhost stopped, and only when the machine is
  not being driven.
- Commit on request only, both repos in lock-step; never push.
- **No edit or removal in the tree while a Vivado build runs** (relearned 2026-09-19): the
  synthesis run re-reads every source AFTER elaboration, so `git rm rtl/gs/dline.sv` under the
  rung-2 synth-only build failed it (`Runs 36-287: File does not exist`) and the rung-2 footprint
  was never measured. Wait for the build's EXIT line; there is no earlier safe point.

## Rung 0: the baseline (synthesis only, the Pt part, 2026-09-19)

`build/build.sh --gs --synth-only` on the tree at fw 75aa18c (the a2 ladder's rungs 0-7 in; the
gs tree untouched since the split, still iline + iscan + dline over a 128 x 8 page cache and the
full register file):

| module | LUTs | flops | RAMB36 | note |
|---|---|---|---|---|
| **gs_top, whole** | **42,860** | **33,025** | **110** | the 50T is 32,600 / 65,200 / 75 |
| card_link | 9,646 | 9,051 | 11 | the full register file (the a2 card's is MINIMAL) |
| gs_io (ADB 694, DOC 3,943 + 16 tiles, IWM 1,365 + 3) | 6,407 | 4,647 | 19 | the chipset |
| dline (L1-D) | 6,108 | 6,728 | 0 | the 8x4 cache, the bank table, the per-line map copies |
| iline + iscan (L1-I) | 4,775 | 2,780 | 0 | the retained set and the scanner |
| page_cache (L2, 128 x 8) | 3,149 | 1,532 | 64 | 256 KB; ROM 3's 1024 pages dirty for ever (REQ §4.2.4) |
| uthernet2_card | 2,679 | 1,181 | 4 | |
| mockingboard | 1,857 | 1,476 | 0 | |
| cpu65816 | 1,534 | 244 | 8 | the three ROMs |
| rom_loader | 1,174 | 772 | 0 | 512 chunks |
| mouse_card | 1,147 | 465 | 0 | |
| accel_seq | 1,017 | 369 | 0 | S_NULL, gs_map_wr, the bank on the stream |
| hd_card | 682 | 211 | 0 | |
| apple_bus_write | 628 | 80 | 0 | |
| apple_mmu | 436 | 233 | 0 | |
| audio_sampler + audio_tx | 575 | 704 | 0 | |
| vbl_lock, vbeam, bank_census, printer, kbd, NSC, fb_sim, bus read, the top | ~870 | ~2,300 | 4 | |

L1 + L2 = 14,032 LUTs / 11,040 flops / 64 RAMB36. Everything else = 28,828 LUTs / 46 RAMB36; on
the 50T that leaves 3,772 LUTs and 29 tiles for L1 and L2 together. The a2 card's L1 + L2 came
out at 4.4k LUTs and 24 tiles; this card's L2 at 128 x 8 alone is 64 tiles. **So the 50T
envelope binds this card on block RAM before LUTs**: the DOC's 16 tiles and the link's 11 are
fixed, and an L2 inside the envelope is 128 x 4 or 64 x 8 (32 tiles, 128 KB), which on a machine
whose ROM alone is 256 KB is a decision about what the cache is for (the working set, not the
ROM). The Pt has 135 tiles and the ladder runs at 128 x 8 on it; the geometry is a parameter of
gs_top, and the 50T question is measured, not guessed, once L1 is rebuilt (rung 5).

Sims on this tree: the gs suite 18/18; the GS/OS row 13 checks / 0 errors, 19.85 M instructions
in 392 M clocks (4.0 M bus cycles; 2.29 M fast ops, 590 k bus ops; the cache 1.39 M hits, 10,106
fills, **7,156 flushes** - the ROM-dirty write-backs); the XMAS row 12 checks / 0 errors, 7.85 M
instructions in 76 M clocks (2,018 fills, 989 flushes).

## The ladder

The same shape as the 65C02 card's, sized by this card's picks (L1_RETHINK.md: TLB 16 entries,
L2 128 sets), and with the IIgs's own serves where the a2 card had none. Each rung is built on
the a2 rung it mirrors; nothing is inherited without being re-decided for this card.

| rung | what | gate | status |
|---|---|---|---|
| 0 | **The baseline.** The gs card synthesised on the Pt part, by module, and the three sim rows recorded. | the table above | **DONE 2026-09-19** |
| 1 | **L2: the a2 card's page cache shared back.** rtl/gs/page_cache.sv becomes the rung-3 module (the referenced ways, the placement report, the direct way read) at this card's geometry; the shadow duplicate's entrant and the any-bank write tap were already in both copies. gs_top ties the new ports off until L1 uses them, so the card's behaviour does not move. | gs suite, boot_gs at the floor, page_cache_tb at 128x8 (it already runs the a2 source at that geometry), lint; synth-only | **DONE 2026-09-19 (sims)**: rtl/gs/page_cache.sv is the a2 module (diff = the header alone); gs_top and boot_gs_tb tie the new ports off; gs suite 18/18, gs_top lint clean; synth 42,860 LUTs / 110 RAMB36, unchanged |
| 2 | **The TLB and L1-I.** rtl/gs/tlb.sv keyed by {bank, page} (a 16-bit virtual page): 16 entries {vpage[15:0], ppn, set, way, region, fold, pair}. An entry in a pair bank ($00/$01/$E0/$E1) revalidates on map_changed by the table exactly as the a2 entry does (its wanted bank is ROM ? $FF : {bank[7:1], bank[0] \| aux}); an entry in any other bank is fixed by the physical layout (RAM $02-$7F, the extended ROM $E2-$EE, the panel's RAM $EF, ROM 3 $FC-$FF) and survives every map change. **This is what dissolves the bank-class machinery**: cvz/cvd/cvo, the OTHER-class table, the pair-bank tests written five times - any page in any bank is an entry like any other, and no bank byte is ever in a serve cone (the lookups compare registered candidates). rtl/gs/l1i.sv is the a2 l1i with a 20-bit buffer tag {bank, addr[15:4]}, the pair-bank $Cxxx/INTC8ROM exclusions, tev_bank, and NO zero-stall target serve (REQ §3.1.2: i_din stays register-direct, `lhit_q ? i_byte_q : accel_din`). iline and iscan leave the gs tree. The bank-write hold (l1_settling = map_settling \|\| bank_wr) stays for now: PBR/DBR are still in map_now, so the settle kills the buffers anyway; rung 5 takes them out. | gs suite (boot_gs at the floor with the $E0 duplicate checks), GS/OS and XMAS rows, lint; synth-only against rung 0's 4,775; a Pt bit: the Finder against 58.6x, the census's IFILL | **SIMS GREEN 2026-09-19**: rtl/gs/tlb.sv (16 entries keyed by {bank, page}, pair-bank entries revalidated by the table, the rest fixed) and rtl/gs/l1i.sv (20-bit buffer tags, pair_q exclusions, no target serve); iline + iscan gone from the gs tree; build.tcl lists each card's l1i/l1d/tlb; gs suite 18/18 with boot_gs at the floor, XMAS 12/0 (7.95 M instructions in 78 M clocks against 7.85 M in 76 M), GS/OS 2% behind the baseline at equal clocks; synth pending |
| 3 | **L1-D.** rtl/gs/l1d.sv: the a2 l1d over a 24-bit candidate. The shadow is bank zero's physical main pages 0/1 (the registered bank byte equal to zero, not a class code); the last row and the last byte carry the bank; the L2 read launches from the registered candidate through lookup B in any bank (the pointer says where the page is, whatever bank class the core called it) and, this being the 816, the row's byte is REGISTERED (sv_byte_q) and retires the clock after it lands - four clocks from the candidate, against the dispatcher's seven to eight. The IIgs serves come over from dline unchanged in kind: the chipset's side-effect-free reads (io_vec) and the keyboard in any bank the I/O page is in, the internal cycle at one clock (n_cycle), the two-clock registered serve for every one-clock server (sv_hit_q; the 816's AGU needs its din register-direct). Writes are dline's GS rung 3: bank zero below $C000 or any address in $02-$7F retires in one clock, the shadow duplicate reloads the splice register (dup_go, spl_dup, the FIFO at 8 with the room sample three short), pair-bank long writes and LC writes ride the dispatcher (the a2's second-clock LC write is a candidate for later). dline leaves the gs tree; the bank census (bank_census.sv, dline's ob_* readback) goes with the table it counted for. | gs suite, GS/OS 12/0 and XMAS 11/0, the mirror replay (tools/gs_mirror_test.sh) when the Pi is up, lint; synth-only against rung 0's 6,108; a Pt bit: the Finder, Arkanoid 77x, the Nox map 38.7x, the census's DEC_D / SEQ_FAST | **SIMS GREEN 2026-09-19**: rtl/gs/l1d.sv (24-bit candidate, the L2 row's byte registered into the serve register the clock it lands: four clocks; the I/O page, the internal cycle and the shadow duplicate as dline's); dline gone; bank_census kept (it reads the top's snapshot registers); gs suite 18/18 at the floor, the short boot: 248 L2 reads launched / 247 served, 104 TLB fills, 144 k internal cycles at one clock; the long rows and the synth pending; **FOUND AND FIXED**: the GS/OS row deadlocked at its first interrupt (instruction 1,626,323, PC $00/FE09): the core predicts a vector pull in bank $00, the board presents it in ROM bank $FF (the redirect, REQ 2.1.3), the TLB knew bank 0's page $FF, the row was served, and the address match's bank compare refused the retire while the claim held the dispatcher for ever (dline never served that page's class through its ways, so it never met the case); the core now exports d_pred_vpb beside its prediction and l1d registers the candidate's bank as the board will present it (`pred_bank`); a sim-only watchdog in l1d names any claim that stands 4096 clocks; synth (before the fix) **35,533 LUTs / 26,378 flops / 110 RAMB36** (l1i 692, tlb 1,451, l1d 1,277, the cache 3,651 with the dr port); **Pt bit gs_r3: TIMING MISS -0.444** (247 of 88,482 endpoints; 32,819 LUTs routed = 100.7% of a 50T, 112.5 RAMB36): ONE family, l1d's registered candidate through the sixteen 16-bit TLB compares, the way mux and the cache's ack into the way RAM's address (12 levels, 74% route; the a2 launches the same way through eight 8-bit entries and met). CUT: lookup B's answer is registered in l1d (lb_hit_q/set/way), the launch is from the candidate's second clock (pq_fresh) and the read retires on its fifth; the first clock claims from the maybe (l2_pre, the a2's w_pre shape), else the dispatcher took the cycle first (7 of 247 served in the short boot until it did); the watchdog no longer counts while turbo_ok is low (the 3.5" seek stall tripped it on XMAS); gs suite 18/18, 247/247 served; **Pt bit gs_r3b TIMING MET +0.000** (0 of 88,502 failing; the worst path the card's known sequencer-state -> microcode-ROM-address chain at 15 levels, 76% route; 32,918 LUTs routed = 101% of a 50T; 112.5 RAMB36), build/results/master_top_gs_r3b.bit, NOT loaded (the Apple runs the a2 bit; the switch to the IIgs is the user's call) |
| 4 | **Branch lookahead on the two active I-lines** (the user, 2026-09-19: the top lever). The old iscan's walk - step through the held line ahead of the PC by opcode length (the 65816's lengths depend on M/X), find branches, JMP/JSR/JSL and their targets, and raise the target line's want clocks before the PC arrives - on l1i's two buffers, through the TLB and the direct way read. Measured first: the I-side books on GS/OS (cnt_slow_i = the sequencer-served fetches = the bubbles). | gs suite, GS/OS and XMAS against 3b's 17.52 M / 78.9 M clocks, a Pt bit | **MEASURED 2026-09-19**: rtl/gs/iscan.sv (the 65816's lengths by M and X, BRL/JSL/JML/PER/RTL known) wired into l1i as a prefetcher: gs suite 18/18, Pt bit gs_r4 MET +0.142, and NO gain on either row (GS/OS 17.51 M against 17.52 M, XMAS level) with the fills up a quarter - with two buffers a speculative target prefetch evicts the line the stream still needs as often as it saves a fill. Then the I-side books said where the bubbles were: 1.56 M sequencer-served fetches and 155 M standing-want clocks on GS/OS = ~100 clocks each = REAL BUS CYCLES; the bench's histogram of slow fetches by page: **$00/C7xx 277 k of 472 k in the first 6 M instructions** - GS/OS running the card's own slot-7 SmartPort firmware on the bus at 1 MHz, a sixth of all clocks. The user (2026-09-19): "all $Cxxx is slow" was only ever a temporary rule; what the card knows is safe to accelerate, it accelerates. BUILT: the hd slot's ROM page (while SLOTROMSEL gives it to the card and INTCXROM is clear) and its DEVICE SELECT answered through the sequencer's fast path on the IIgs (apple_mmu slot_on / q_hd_fast, gs_top slot_on, the bench's hd card shown the unified op under sl_win); gs suite 18/18; **Pt bit gs_r5 TIMING MET +0.118** (the RTL of this state; the fixes after it were the bench's). THE BENCH HAD TO LEARN THE FAST PATH: it told the MMU the hd slot was 0 (the claim could never match - the first row with the path 'on' was byte-identical to the one before), its hd card saw only the driver's ops (the top shows the peripherals the unified op under sl_win), it lacked the top's sl_claim_fast handshake, and its host model tapped the driver's port ops alone where the real host taps the capture's fast words too - now one peripherals'-view mux (hp_*) feeds both. With all four: the GS/OS row at 6 M instructions **133.2 M clocks from 164.2 M (-19%)**, 13/0; the $C7xx fetches served at a few clocks each (586 k of them). NEXT (the user's design, 2026-09-19): the two-line L1-I - only the current and the next line; the scanner as a TARGET TABLE (the transfers ahead on the trail with their targets), the branch decided at its OPCODE fetch from the live flags, the target line fetched ONLY when taken and handed over as the current line; no pin, no speculative prefetch; regular branches first, returns (read the stack, never predict it) and indirects later |
| 4b | **The sequencer after L1.** accel_seq on this card keeps S_NULL (the internal cycle when serving is off) and gs_map_wr; what goes is what the histogram no longer charges. Measured, not guessed. | gs suite; the histogram on HW | |
| 5 | **The bank registers leave the map.** With the TLB keyed by bank, a PBR or DBR write changes no translation: take core_pbr/core_dbr out of map_now (REQ §3.3.3) and bank_wr out of l1_settling, so PHB/PLB and every JSL stop costing a five-clock settle and two buffer kills. Then the 50T question: L2 at 128 x 4 measured on the Finder and Arkanoid against 128 x 8. | boot_gs at the floor; GS/OS; a Pt bit and the census's SETTLE share | |
| 6 | **ROM 3's pages land clean** (REQ §4.2.4, the largest known defect): the loader's chunks reach the DDR3 as well as the cache, so a ROM page is a clean victim and never pays a sixteen-beat write-back of bytes that cannot change. The shape is decided here (write-through for the loader's posted writes, or a flush per chunk while the CPU is held). | boot_gs's stale-line audit; mem_flushes on a GS/OS boot against 665 | |
| 7 | **The core**, only what the census names after 1-6 (REQ §2.5: the five address-mux copies, the early-carry adder, the three ROMs), and nothing in the cycle contract. | cpu816_* 3/3, the trace harness >= 400/file, boot_gs at the floor | |

## The first census finding: the TLB thrashes on GS/OS (2026-09-19)

The rung-3 GS/OS row fills the sixteen entries 1.13 M times in 18 M instructions - one fill per
sixteen instructions, each a dispatcher trip (seven to eight clocks) plus the two-clock install,
and the 585 k data-side waits are candidates that rode the dispatcher while their page's
placement was on its way. XMAS, a single program in a few banks, fills 3.7 k times in 8 M. GS/OS
walks the toolbox (bank $FF and the ROM's other banks), its own banks, the application's and the
Mega II screen's, and sixteen pages is fewer than it has live. The lever is the entry count
(32 doubles the TLB's 1,451 LUTs; the lookups are 16-bit compares, two per entry) or a smarter
replacement than round-robin (the a2's pick, kept); the user picks. The a2 ladder saw the same
shape on ProDOS (24.5 k fills in 2 M cycles) and left eight entries.

**MEASURED 2026-09-19 (`sim/run_boot_gs_tb.sh --tlb=N`, the GS/OS row at the 400 M ceiling):**

| entries | TLB fills | data-side waits | L2 reads served | instructions at the ceiling |
|---|---|---|---|---|
| 16 | 1,075,348 | 555,927 | 4.60 M | 17.52 M |
| 32 | 649,935 | 333,780 | 4.81 M | 17.67 M |
| 64 | 375,032 | 200,073 | 4.94 M | 17.78 M |

The fills fall by two thirds and the machine gains 1.5%: **the entry count is not the lever, and it
is not grown (the user, 2026-09-19).** The user's direction: the top lever is BRANCH PREFETCH - the
gs l1i keeps only the a2's early want (raised when the branch's operand byte is served, so a taken
branch out of the two buffers pays its fill as a bubble); the old iscan walked the line ahead of
the PC and asked for the target's line clocks earlier. That lookahead scan on the two active
I-lines is rung 4, sized first by the I-side books on the GS/OS row (fetches the sequencer served,
fills, prefetches, kills).

## Sizes, picked (the user's rule: reasoned, not modelled)

| structure | pick | why |
|---|---|---|
| TLB | 16 entries, round-robin, {vpage 16, ppn 16, set 7, way 3, region 4, fold, pair} | GS/OS's working set is spread over more pages than a 6502 program's (the toolbox, the desktop, the application, bank $E1's SHR screen, ROM under a JSL); twice the a2's pick; ~50 flops and a 16-bit compare per lookup side per entry |
| L1-I | 2 line buffers + the pin, as the a2 | 99.9% of fetches at one clock there; a third buffer is a lever if the census wants it |
| L1-D | the shadow (bank 0 pages 0/1), the last row, the last byte, the I/O page serve, the internal cycle | dline's servers minus the cache and the bank table |
| L2 | 128 x 8 on the Pt (64 tiles); 128 x 4 is the 50T's shape (32 tiles), measured at rung 5 | the block RAM is the envelope's binding constraint on this card (rung 0) |

## Ledger (synthesis only, the Pt part)

| after rung | LUTs | flops | RAMB36 | L1-I | L1-D | L2 | notes |
|---|---|---|---|---|---|---|---|
| 0 | 42,860 | 33,025 | 110 | 4,775 | 6,108 | 3,149 + 64 | iline+iscan / dline / 128x8 |
| 1 | 42,860 | 33,025 | 110 | 4,775 | 6,108 | 3,149 + 64 | the shared cache with its new ports tied off prunes to the same netlist |
| 2 | not measured | | | | | | the synth run was failed by rung 3's file removal under it |
| 3 | **35,533** | **26,378** | 110 | 692 + tlb 1,451 | 1,277 | 3,651 + 64 | l1i / l1d over the TLB; 109% of the 50T's LUTs, 147% of its block RAM |

## Sim ledger (the three rows, per rung)

| after rung | gs suite | GS/OS (20 M instr) | XMAS (8 M instr) | notes |
|---|---|---|---|---|
| 0 | 18/18 | 13/0, 392 M clocks, 10,106 fills / 7,156 flushes | 12/0, 76 M clocks, 2,018 / 989 | the baseline |
| 2 | 18/18 | 13/0, 19.49 M instructions at the 400 M ceiling (2% behind) | 12/0, 78 M clocks, 2,019 / 989 | L1-I on the TLB |
| 3 | 18/18 | 13/0, **18.03 M instructions at the 400 M ceiling (9% behind)**: 4.75 M L2 reads served, 14.8 M last-row serves, 14.4 M internal cycles at one clock, 7.4 M posts (1.36 M into $02-$7F, 29.7 k duplicates), **1.13 M TLB fills** (490 k from the data side, 585 k waits) | 12/0 before the vector-pull fix; the rerun after it pending (the watchdog's false positive under the 3.5" stall) | L1-D on the TLB |
| 3b (lookup B registered, the first-clock claim) | 18/18 | 13/0, 17.52 M instructions at the ceiling (12% behind): 4.60 M L2 reads served at five clocks, 1.08 M TLB fills (467 k from the data side, 556 k waits) | 12/0, 8.0 M instructions in 78.9 M clocks (2.5% behind); 153 k L2 reads served, 3.9 k TLB fills | the timing cut's price on GS/OS is the fifth clock and the thrash |
| 5 (the hd slot fast) | 18/18 | 13/0, **20 M instructions in 375.2 M clocks (the first row to finish under the ceiling; the old tree needed ~395 M, rung 3b reached 17.5 M at 400 M): bus ops 14 k from 590 k**; the $C7xx firmware 1.14 M fetches at a few clocks; 5.24 M L2 reads, 2.40 M sequencer-served fetches | 12/0, 78.86 M clocks (unchanged: no hd traffic) | at 268 M clocks 12.50 M instructions against 3b's 9.66 M and the old tree's ~10.2 M: +29% / +22% |
