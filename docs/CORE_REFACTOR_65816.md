# The 65816 card: the core / L1 / L2 refactor ladder

Status: **2026-09-20 LATEST: THE BINDING LOOP RETIMED, THE Pt MET, THE 50T STILL MISSES - ON A DIFFERENT FAMILY** (branch l2_sets, the retimes uncommitted).  pc_reg -> the microcode ROM's address is GONE from the worst paths: the slot-0 sequencing is read from L1-I's two serve registers through a decode ROM each, and the serve select runs on a one-sided flag of the stream's position computed a cycle early over the core's simple PC arms and selected late by the retire and the core's cycle enable.  Pt bit `bloop2`: TIMING MET +0.045 / whs +0.058, 0 of 72,719; 27,739 LUTs (+141), 54 RAMB36; gs suite 18/18, the 20 M row 14/0 with the assertions silent (the flag conservatively low on 27 k of 257 M clocks: MVN/MVP's rewind arm).  The 50T (`50t_bloop2`, the same source): TIMING MISS -0.391 on 122 of 68,931, 27,377 LUTs = 84.0%, 50 RAMB36 - the worst path the sequencer's bank register into the page RAM's port-B address (the TLB direct-read cone), 13 levels, 74% route.  Stopped at the user's rule.  Section "The binding loop retimed" below.  **EARLIER: THE L2 IN SETS
measured on hardware, bit `l2s32`, TIMING MET +0.014, 0 of 70,313).  An A/B on
one commit (fw 588c81a), one generic apart, both Pt GS builds: the Finder
**47.9x** at 32 slots against **51.6x** at 64 (bit `enc1`, the last round's
number, same census - `gs_nox.conf` on `system6.hdv`, idle at the desktop),
so **-7.2%**, for **1,844 LUTs
design-wide** - page_cam's own 4,365 -> 2,905 (-1,460) plus the slot index
narrowing six bits to five everywhere it travels, through the TLB and both L1
sides - and **five levels of logic depth** (max 23 -> 18, paths >= 10 3,888 ->
2,826, the tail >= 14 587 -> 321).  **90.3% -> 84.6% of a 50T's 32.6k**, and
the depth is headroom against the congestion that closes or fails that board
rather than against its capacity.  The user's call: 64 is faster and 32 is
what fits, and development continues from 32.  `gs_top`'s `MEM_SETS` and the
boot bench's `--l2` default are both 32 now - a bench default that does not
match the machine models a build nobody makes - and `build.tcl -gsslots N`
builds any other count for an A/B (`-gs50t` sets 32 AND MINIMAL_REGS, which is
the 50T variant, not a slot count).

**THE COST IS A WORKING-SET CLIFF, NOT A TAX** (the user, on hardware
2026-09-20).  **THE NOX MAP IS UNAFFECTED - 59.5x at 32 slots**, against the
58.8x the census records at 64.  The same bitstream that costs the Finder 7.2%
costs the map nothing, because 32 slots is 8 KB and the map's animated loop
fits in it while the Finder's idle desktop does not.  It bites where the
working set outgrows the store and the evictions start returning: the row A/B
below shows the mechanism in the fills, 737 k / 212 k at 64 slots against
829 k / 253 k at 32.  So DO NOT GENERALISE THE 7.2% - a workload is either
inside 8 KB or it is not, and the Finder is the one of the two measured
workloads that is not.

**AND 58.6x IS THE NOX MAP, NOT THE FINDER.**  The census below draws the
distinction where it is made ("43.5x, not the map's 58.8x"), but the rung 2
line above says "the Finder against 58.6x", which reads as a Finder figure and
is not one.  Pairing 47.9x against it would have called this an 18% loss
instead of 7.2%.

**CORRECTION TO THE 2026-09-19 TABLE BELOW: the block RAM does not halve.**
It lists 32 slots as 2 RAMB36; this tree builds **4**, the same as 64, and the
design total is 50 either way.  The row is 128 bits wide and 128 bits needs
four blocks whatever the depth - width sets the floor, not depth.  Do not lean
on the 2 in a 50T fitting argument.

**2026-09-20 EARLIER: A BLOCK MOVE IS A TRANSFER TO ITSELF - the recover bubble every byte moved is gone** (bit `mvtgt1`, TIMING MET, 0 of 82,063; fw built 2026-09-20 12:36:26, SRAM).  MVN/MVP move ONE byte per execution and the microcode rewinds PC to their own opcode for the next, so three of the seven cycles a byte are fetches of this very instruction - and that rewind is not a branch opcode, so the target table never knew it and L1-I's `exp_q` said ptr+3 every time: **199,881 recover bubbles in a 200,000-byte microbenchmark, all at a sync, exactly one a byte.**  `iscan` already knew MVN/MVP are three bytes; it classed them "continue at ptr+len".  Classed as C_MV - target the instruction's OWN address, the trail ENDING there (following a transfer to itself walks one instruction for ever) - l1i's ordinary target path serves the rewind, and because that path MATCHES ON THE ADDRESS rather than predicting taken/not-taken, the last iteration costs the one recover it always did.  **Recovers 199,881 -> 0, the block move 12.7 -> 11.9 clocks a byte, the GS/OS row 268.30 M -> 266.60 M (+0.6%), 14/0.  ON THE FINDER, IDLE: NOTHING MEASURABLE** - which is evidence against the estimate that put the Finder at ~38% block-move ops (inferred from its I-fetch share landing on 3/7, and leaned on too hard).  An idle desktop moves no blocks; what it does is in the census below.
**AND THE DRAIN IS NOT A COST - the bucket was a mis-attribution.** The block move's ~2 clocks a byte of "drain" was the census chain testing `d_pending` BEFORE `claim`: a write is always in flight in a block move, so every clock blocked by the leash got the drain label.  Removing the barrier entirely recovered 502 clocks in 2.5 M (0.02%) and moved 399,862 clocks from one bucket to another.  The real stall there is `claim`, 94% of it "leash low" (`turbo_ok` false), and WHICH of its eleven terms is low is unmeasured - `busy` (the cache engine filling) and `can_pay` (the governor) point at different fixes.  On hardware `dl_post_waits` is ZERO: a write is never back-pressured by the posted FIFO.
**2026-09-20 EARLIER: THE FINDER AT 51.6x, FROM 43.5x (+18.8%), ON HARDWARE** (bit `enc1`, TIMING MET +0.086 / whs +0.054, 0 of 82,067; fw built 2026-09-20 12:06:26, SRAM).  RUNG 5 IS DONE: the bank registers leave the map, and the settle goes with them - **14,381,368 clocks a second to 3,087** on the Finder, +4.2% (the raw share is 2.9%: a settle also holds the leash, so the work behind it stalls too).  AND THE CAM's ENCODER IS A TREE: `enc()`'s `if (oh[i]) enc = i` was a SIXTY-FOUR DEEP PRIORITY CHAIN sitting in slot0, vic_q and plru_pick - every path into the cache - and one operator (`enc = enc | i`, an OR being associative where an override is not) makes it two LUT6 levels.  Max depth 22 -> 19, paths >= 10 levels 4,320 -> 3,700, the tail >= 14 510 -> 402: 620 fewer deep paths from one character.  It is only equal for a ONE-HOT input, so the assumption is asserted in sim, permanently, and stayed silent over a 20 M-instruction GS/OS row (289 k fills).  **2026-09-20 EARLIER: THE FINDER AT 49.5x, FROM 43.5x (+13.9%), ON HARDWARE** (bit `epage1`, TIMING MET +0.098 / whs +0.049, 0 of 82,062; fw built 2026-09-20 10:57:56, SRAM).  THE NEIGHBOUR SLOT in `l1d`: a read whose address is the previous read's +/-1 is picked out of the row ALREADY HELD, into a register, on the clock the previous read retires, and retires on its FIRST clock when the next cycle asks for it - so DEC_D falls 102.17 M -> 76.28 M clocks (-25.4%) and retire rises 44.4% -> 50.6%.  It performs NO memory access, so no prefetch, no `mv_done` and no region gate: the row-crossing case is simply not predicted.  It covers BOTH the 16-bit pair (gap 0) and the block move's source stream (gap 3) with one slot.  The general early serve is NOT reachable and this is why: docs/GS.md already cut `din -> AGU -> prediction` once, and these are the only addresses the unit can know without the AGU.  AND THE CORE'S BINDING LOOP CUT: `early_co`'s two carry chains in series (pc+1, then din+that) become one - the increment folds into the adder's carry-in, the three candidates sum in parallel, one LUT6 picks the bit, and `&pc[7:0]` masks the truncated wrap back in (`pc_inc[7:0]` is 8-bit: at PCL=$FF the fold would carry where the truncation does not, and that is exactly the page boundary the condition looks for).  cpu816_trace 981,610 / 0.  **MEASURE ON HARDWARE, NOT ON THE ROW** (the user, 2026-09-20): the GS/OS row reaches ~2% of a boot - a billion instructions get to the Finder - so it predicted +6.2% where the machine gave +13.9%.  `sim/gen_micro_rom.py` is the answer to that: a synthetic ROM whose reset vector lands in a loop, forty seconds a run, the whole accel path.  It priced the block move at **13.8 clocks a byte against a seven-cycle floor** - drain ~2.0, claim ~1.3, settle ~1.0 (DBR every iteration: rung 5), recover ~1.0 (the microcode's PC rewind, a bubble at the sync, invisible to the target table) - against the hand-written copy's 66.7.  **2026-09-20: THE DOC's REGISTER DECODE FIXED AND THE VICTIM CHAIN CUT, BOTH ON HARDWARE (bit `viccut1`, TIMING MET +0.005 / whs +0.027, 0 of 81,874; fw built 2026-09-20 09:44:48, SRAM).** The LUT work's `default:` arm had swallowed every register type once types 0/1/2/4/6 moved to RAM, so any write to OSCILLATOR 1 - its control register above all, which starts and stops voice 1 - rewrote the enable count and every oscillator above it stopped being scanned: notes that cut off or hung, sound still playing (gs_doc_tb 27/27, the check mutation-tested; USER CONFIRMED FIXED ON HARDWARE).  And the build it was found in missed by -1.924 on ONE family, the CAM-L2's `plr -> plru_victim -> the five-way choice -> vic_q` in a single clock (18 levels, 77% route): the choice now reads the already-registered `plru_q`, with `plru_q2` carrying the decode the victim was chosen FROM so `skipped` still compares like with like (else a false skip clears a `d_ref`).  A/B on the GS/OS row: fills 289,098 against 292,780 (-1.3%), 292.42 M clocks against 292.70 M, 14/0 both arms - the staler preference costs nothing.  **2026-09-20: THE I SIDE'S FIRST CUT ON HARDWARE (gs_pt52, MET +0.000: the early landing and the target serve back, the Nox map 55.0x -> 58.8x; fw 26cf946 / host ff59838). THE INSTRUCTION STORE (rung 8) WORKS IN SIM (suite 18/18, Nox 37.93 M against 39.86 M) and MISSES TIMING ON THE CARD (gs_pt54 -1.894 ns, 32,140 LUTs): its fix is decided (register the read for the din-dependent loads, keep two ways) and WAITS ON THE LUT WORK, which is under way: the DOC's registers in LUTRAM (-1.75 k), the books folded into one RAM, the ROM loader's drain one word a clock - measured by synthesis-only builds against the 50T's 32,600.** The 50T candidate met timing 2026-09-19 (gs_50t2: +0.082, 28,514 LUTs = 87.5%, 48 RAMB36).  The 65C02 card's
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
| 4c | **The two-line L1-I** (the user's design, 2026-09-19). The buffers are the current line and the next one, nothing else; rtl/gs/iscan.sv stops raising wants and REPORTS every transfer it finds (opcode address, opcode byte, target) into a four-entry TARGET TABLE in l1i; every opcode fetch looks the table up by its full address, a hit is decided at that fetch from the live flags (a sim assertion checks it against the operand-time truth), and a taken transfer's line, if not held, is fetched into the other buffer at once - about the three cycles the branch's operand and internal cycles take. Fetch only on taken; no pin, no scanner prefetch; the early want at the operand stays as the fallback for a branch the table does not know (a held or in-flight target drops it). | gs suite; GS/OS and XMAS against row 5 (375.2 M / 78.86 M); a Pt bit | **SIMS GREEN 2026-09-19**: gs suite 18/18 at the floor, the assertion silent; the short boot: 2,963 target fetches at the opcode, 86,654 taken transfers already held, 5,200 branch opcodes the table did not know, fills 23.5 k (30 k before); **MEASURED**: GS/OS 20 M instructions in 373.1 M clocks (row 5: 375.2 M; -0.6%), XMAS 78.29 M (78.86 M; -0.7%): 594 k targets fetched at the opcode, 835 k already held, 904 k branch opcodes the table did not know (four entries, cleared by every map change - PBR/DBR writes clear it), fills 5.86 M -> 4.49 M; Pt bit gs_r6 TIMING MET +0.269 at 33,469 LUTs. Branch bubbles were already small once the slot ROM went fast; THE CLOCK CENSUS (the bench's new per-clock classifier, the 6 M row): **HELD 37.6%** - the sequencer waiting on the hard disk's block DMA, which lands one byte per BUS CYCLE (hd_card's S_DMA_W advances on the driver's op_present) even on the IIgs build where the byte never reaches the backplane: 512 bytes = ~51 k clocks per block, 1,858 blocks per GS/OS boot = ~95 M of 373 M clocks, ON HARDWARE TOO; retire 19.1%; the data side ~15% (L2 reads 6.6%, the registered serve's second clock 5.1%, the data claim 3.6%); the dispatcher's fast ops 3.2%; decide 2.7%; I fills 2.3%; drains 1.7%; and 16.3% "no event room" = the bench's bursty merge back-pressure model (a modelling tax the card does not pay; kept, it catches hangs). NEXT DECISION (the user's): land the block at card speed - through the page cache's posted seam as the ROM loader's chunks go (~1-2 k clocks per block), the host's mirror applying the block it sent - which would take ~25% off a GS/OS boot |
| 4d | **The hard disk's block lands fast** (the user's design, 2026-09-19: keep every byte an override write on the unified stream, in the same order the bus path put it there so the mirror is untouched, and take it off the driver's 1 MHz cadence). rtl/gs/accel_seq.sv S_OVR: a write override the top marks fast (the hard disk's, mode 2 serving) is presented by the sequencer byte by byte as an override op, the page cache lands it at P1 and `decided` paces the next; the peripherals see the op through the window (ov_win in gs_top's p_* mux, hp_* in the bench), so hd_card steps on `ours` as before; the driver is kept off it; a fast override waits in DECIDE for the cache, never HELD (the first cut fell to HELD twice: fast_ok's own "no override pending" clause, then a cache miss on the second byte - the driver being gated off, HELD would never have ended; a bench watchdog names a sequencer state standing 200 k clocks). Reads (HD_FETCH) and every other override keep the bus. | boot_gs's block checks (blocks land intact where the machine looks), GS/OS and XMAS against row 6, a Pt bit | **SIMS GREEN 2026-09-19**: the short GS/OS row (700 k instructions): 41 blocks read, 40 landed intact, 13/0, HELD 0, **~2 k clocks per block against ~51 k**; gs suite 18/18; **GS/OS 20 M instructions in 282.9 M clocks (row 6: 373.1 M; -24%)**, 1,858 blocks read, 1,844 intact (the 14 others written into by the machine first, as before), 13/0; the DMA 3.85 M clocks = 2.1 k per block, HELD 0; XMAS 78.29 M unchanged. The census after it: retire 29.4%, the bench's room model 23.7%, data reads 12.5% + the registered serve 8.9% + the data claim 6.4%, I fills 4.8%, fast ops 4.2%, decide 3.2%, drains 2.9% - the data side is now the largest real share; **Pt bit gs_r7 TIMING MET +0.154** at 33,607 LUTs / 112.5 RAMB36 (build/results/master_top_gs_r7.bit, not loaded) |
| 6 (done early) | **ROM 3's pages land clean** (the user, 2026-09-19: "make the clean-rom change too in this pass"). rtl/gs/rom_loader.sv drains a chunk as thirty-two 16-byte LINE WRITES through a new line port of the page cache (ld_*), served by the engine when idle as one write to the DDR3 (E_LDWR), never into the cache; the posted seam is L1-D's alone again. A ROM page fills clean on demand and a clean victim is dropped. Found on the way, at 64 sets, TWO CACHE BUGS present at any geometry: (a) the SNAPSHOT of a dirty victim read its row 0 on the very clock an op's landing wrote it (an op at P1 when the engine starts lands the clock after), so the flush and every fill after lacked the byte - the first beat now waits out a landing into the victim way (snap_hold); (b) the set hash folded bits 11:0 only, so at 64 sets bank $E0's pages sat in bank $00's sets and every shadowed write ping-ponged with its Mega II duplicate, a dirty eviction per byte - the page's top bits fold in now (the bench's peek follows). Also: the cache names a BLOCKED op (a miss into a busy engine, formerly dropped and counted as a late fill) beside `decided`, and the sequencer re-dispatches it, the fast override included; the bench's late-fill guard is drops-only now. | boot_gs: the ROM behind the cache = the image, the audit's write-backs 0; the geometry rows; a Pt bit | **SIMS GREEN 2026-09-19**: "the ROM behind the cache: 0 of 262,144 bytes differ", flushes 0 in the short boot (3,458 at 64x6 before); 64x6 at 700 k instructions 13/0, 40 blocks intact, **7.73 M clocks against 128x8's 10.79 M before the change**; the 20 M rows at 128x8 / 128x4 / 64x6 and XMAS running, gs_r8 building |
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

## The CAM-L2 (the user's design, 2026-09-19; built the same day)

The user, with a 50T order to decide: the tile problem is the set cache, and the idea that ends
the TLB-carries-the-way line of thought is to let L2 hold exactly the pages a directory in flops
names - a FULLY ASSOCIATIVE page store of N slots, one block RAM, the directory a CAM - with a
replacement policy that keeps a WORKING SET against a STREAM ("that might require something more
than just a CAM"). rtl/gs/page_cam.sv: N slots x 16 rows in one way_ram (64 slots = 16 KB = four
RAMB36 against 64), the directory {valid, dirty, tag, referenced, last offset} per slot in flops,
the entrant's page compared against every slot in P0 and the matching slot's row read at once;
everything behind P0 (the landing, the decision, the engine, the seams, the taps, the monitor, the
loader's line port) is page_cache's by name. The victim: a free slot; else, among slots the TLB does
not point at, the tree PLRU's pick if it was never RE-REFERENCED since its fill, else the lowest
such, else the PLRU's pick if unpointed, else the lowest unpointed, else the PLRU's pick. A slot's
referenced bit is set only by a NON-SEQUENTIAL touch after its fill (an offset that is neither the
last one nor its successor: a loop's branch back, a table looked up, the stack; never a copy, a
clear, a DMA landing or a screen sweep) and cleared when the PLRU's pick was skipped for being
protected (one reference given up per skip, so a set that stops being a working set drains). Write
misses still allocate (writing around them needs a byte enable on the common page client: next).
The L1 sides and their TLB are untouched: a slot where they had a set, a one-bit way always zero.
The bench's `--l2=N` is the slot count; the gs suite is 18/18 at the floor with 64 slots.

**MEASURED (the 20 M GS/OS row and XMAS, all checks green):**

| L2 | tiles | GS/OS clocks | fills / flushes | XMAS |
|---|---|---|---|---|
| the set cache 128x8 (row 8) | 64 | 279.8 M | 9.0 k / 6.1 k | 74.8 M (1.1 k / 81) |
| CAM 64 slots | 4 | 322.5 M (+15%) | 737 k / 212 k | 77.6 M (+3.7%; 36.1 k / 35.5 k) |
| CAM 32 slots (the user's pick: the smallest reasonable) | 2 | 328.6 M (+17%) | 829 k / 253 k | |

The estimate (4-6% at 64) counted L1's TLB fills alone; every dispatcher miss and every WRITE MISS
allocates too, and a third of the fills evict a dirty victim (on XMAS nearly all: the screen's
write sweeps allocate and dirty a slot each and flush sixteen beats on eviction). THE WRITE-AROUND
is what takes those out (a write miss goes to the DDR3 with a byte enable and allocates nothing),
and the small CAM's real number is after it. At 10 M clocks the 128-slot row failed to compile
(Verilator would not unroll the directory's clear loop at 128; packed vectors fix it).

**The user (2026-09-19): 32 slots** - the smallest that performs reasonably, for headroom against
the congestion that closes or fails this card. **gs_r9** (64 slots, the Pt, before the write-around)
built at 35,897 LUTs / 52.5 RAMB36 and MISSED by 5.1 ns on the victim choice as a cone at P1 (21
levels, four fifths route); not studied further at the user's word, only designed around. BUILT
NEXT, the same day: (a) the victim is a REGISTER recomputed every clock from the directory's flops
(the engine's own slot masked so a page filled last clock is never the stale pick), P1 only
captures it; (b) THE WRITE-AROUND: a write miss is one line write with one lane to the backing
store (E_WARD; page_client gained `pq_sel`, card_link passes it, the a2 ties all lanes) and
allocates nothing - a copy's destination, a clear, a DMA block and the screen's sweeps leave the
slots alone; (c) the directory's bits as packed vectors. Both tops lint; the gs suite and the a2
boot suite green (the common change checked on both cards). THE 50T CANDIDATE: gs_top parameters
HAS_MB / HAS_MOUSE / MINIMAL_REGS (the two cards generated out under tie-offs, the register file
at its minimum as the a2's), set with MEM_SETS=32 by build.tcl's `-gs50t`; built as
`build/run_build.sh gs_50t --gs --board au_v2 -part xc7a50tftg256-2 -gs50t`.

**WITH THE WRITE-AROUND, 32 slots (all checks green):** GS/OS 20 M instructions in **312.5 M
clocks** (the 128x8 set cache 279.8 M: +11.7%; before the write-around 328.6 M), fills 498 k
(829 k before), flushes 85 k (253 k); XMAS **75.55 M** (the set cache 74.8 M: +1%), fills 1.2 k
(36 k before), flushes 394. The a2's benches instantiate page_client directly and needed the new
select tied to all lanes (the a2's Nox boot went wrong until they did: the DDR3 stub wrote no
lanes on a flush); the a2 boot suite 2/2 after.

**THE 50T CANDIDATE, FIRST BUILD (gs_50t, the 50T part, the au_v2 pins): routed at 28,703 LUTs =
88%, 48 RAMB36 = 64%, flops 32%, DSPs 7%; TIMING MISS -0.535 on 72 endpoints, ONE family: the
ROM loader's 16-byte line sum plus the running sum in one clock (the clean ROM's adder tree; it
had missed gs_r8 too).** The sum is registered a clock ahead of its add now (the offer waits one
clock after a take so the sum is the line's own); the gs suite 18/18 after.

**THE 50T CANDIDATE MEETS TIMING (gs_50t2, 2026-09-19): TIMING MET +0.082 (0 of 66,927 failing),
28,514 LUTs = 87.5%, 48 RAMB36 = 64%, flops 32%, DSPs 7%; the worst path the cache engine's state
into the block RAM's port-B address (12 levels, 75% route), the card's usual margin.** What is in
it: the whole 65816 card with the Uthernet, the DOC in block RAM, the fast slot path, the fast DMA,
the clean ROM, the two-line L1-I, the CAM-L2 at 32 slots with the write-around and the working-set
policy; without the Mockingboard, the slot mouse card (the IIgs's mouse is ADB) and the register
file's instrumentation (MINIMAL, the ACCEL words kept). Its cost against the Pt's 128x8 set cache
in the bench: GS/OS +11.7% on the boot, XMAS +1%. The bit: build/results/master_top_gs_50t2.bit
(no 50T board exists to load it on). Further LUT levers if headroom is ever wanted: fb_sim (unread
on this build, 4 tiles), the bank census, the Uthernet's 2.6 k as the last resort.

**ON HARDWARE (gs_pt50, the same feature set on the Pt, TIMING MET +0.093, 2026-09-19): PROVEN.**
system6 cold-boots to the Finder through the fast slot path and the fast DMA, the host's hd count
climbing (4614/4614 at the Finder), the mouse working. The first attempts ended at "Check startup
device!" and the fault was the HOST's: its apply loop skipped every fast word in the bus time base
before the hard-disk controller (`if (fast && !virt_base_) continue;`), and a IIgs reports the bus
base by design (`virt_base = !GS && virt`, the beam at the bus's cadence), so the EXECUTE the card
kept on the stream never reached the controller; the card timed the command out. The IIe never
showed it (its base is virtual under accel) and neither did the IIgs while its $Cxxx was all bus
class. Telemetry found it: `hdexecs` rose by one per `PR#7` while the log's `hd N/N` stood still.
The fix moves the skip below the peripherals (src/pipeline.cpp, host). Two lessons from the same
hour: a programmatic RES' is a WARM reset on a IIgs (BASIC, no slot scan) - a cold boot holds
Open-Apple through it (`button open down` / `reset` / `button open hardware`); and `mouse = off`
on a IIgs disarms the ADB feed, so the 50T bit (no slot mouse card) still runs `mouse = on`.
Also: build.tcl's -gs50t generics had replaced the build stamp (fixed, uncommitted).
Then the 3.5" drive: listed in the chooser, no icon on the desktop, and `PR#5` booted the 5.25" instead
(the host's d35seeks stayed 0). MINIMAL_REGS - the 65C02 card's cut - gated the FD35_DRIVE write off,
so the host's insert never reached the IWM, and it zeroes the FD35 readbacks, so telemetry could not
say so either. rtl/common/wb_regfile.sv keeps the IIgs's registers (fd35, ADB, clock, panel, U2, the
DBG pair) under MINIMAL now; their sources are constants on the 65C02 card, so nothing is lost there.
The rule: a cut named for one card is checked against what the other still needs. Pt bit gs_pt51.

**THE NOX CENSUS ON THE 50T SET (bit gs_pt51 on the Pt, the overworld map, unlimited, 5 s window
= 500.0 M clocks, 2026-09-19).** 280.9 M ops retired = 55.0x over 5.10 M bus cycles (the Pt set
cache measured 38.7x here at rung 3). The clock budget, every bucket of the census (h_sel, one per
clock, the sum exact):

| bucket | clocks | share | what it is |
|---|---|---|---|
| retire | 280.9 M | 56.2% | an op retired |
| DEC_D | 65.5 M | 13.1% | a data op up, deciding: the second clock of every registered serve (31.5 M non-internal one-clock serves), the L2-served reads' four (12.15 M), the fast ops' first clock |
| I fill wait | 63.4 M | 12.7% | an I-line on the way from L2: 27.4 M line fills, 2.3 clocks each |
| DEC_I | 44.2 M | 8.8% | an instruction fetch up, deciding, no fill busy: the line switch, the TLB waits (1.0 M), the target table's misses (0.98 M) |
| SEQ_FAST | 25.6 M | 5.1% | the dispatcher's 9.36 M fast ops in S_FAST (2.7 clocks each): 6.71 M WRITES (LC/aux/pair-bank), 1.84 M RAM reads the TLB missed, 0.82 M fetches |
| D fill wait | 16.5 M | 3.3% | a D-line fill |
| settle | 3.3 M | 0.7% | |
| bus + held | 0.66 M | 0.1% | 4,215 bus ops |

The ops: 180.3 M turbo fetches (1 clock), 91.2 M L1-D serves (47.5 M of them internal cycles at one
clock, 17.1 M long reads, 12.15 M from L2, 6.9 M keyboard polls, 9.9 M posted writes), 9.36 M
dispatcher fast ops, 4,215 bus. The I side: 27.4 M line fills for 180 M fetched bytes = 6.6 bytes a
fill (a 16-byte line): the two-line L1-I refills constantly on Nox's loops; 18.6 M next-line
prefetches, 2.12 M branch-target prefetches, 16.0 M taken branches whose target line was already
held, 0.98 M branches the table did not know. The D side: the registered serve costs a second clock
on every non-internal serve (6.3% of all clocks by itself).

**Where the clocks go, largest first:** (1) the I side, 21.5% = the line fills' wait + the decide
clocks - the two-line design's refill rate on loop-heavy code is the lever (a third line, or keeping
the loop's lines: the a2's rung 6/7 question); (2) DEC_D 13.1% - the second clock of the registered
serve (a one-clock serve for the common case is the 65C02 card's shape) and the L2 read's four;
(3) the dispatcher's writes, 6.7 M in 5 s = the largest fast class (LC and aux writes on a IIe
program): serving them in L1-D (the a2's second-clock LC write) takes SEQ_FAST and their DEC_D clock
with them; (4) the D fills, 3.3%.

**THE I SIDE, FIRST CUT (2026-09-19, the Nox boot on the bench, 4 M instructions, `--hdv=nox_los.HDV
--l2=32`, four runs):** the fill lands a clock earlier (page_cam exports the row straight off the RAM's
port B, `dr_erow`, and l1i takes it at F_W1) and THE BYPASS serves the waited-for byte off the landing
row into the serve register the same clock (two of a demand fill's five clocks) - 60.79 M -> 59.14 M
clocks (-2.7%), gs suite 18/18. The next-line prefetch at the HALF line and a LOOP GUARD from the
target table were both measured and both lose: the guard 59.98 M (a suppressed prefetch is a demand
miss on the loop's exit), the half line + guard 59.58 M with a third more fills (a target landing in a
line's upper half evicts the line it came from at once). Both stay as bench switches (-DL1I_NX_HALF,
-DL1I_LOOP_GUARD). The lesson: with two slots an earlier prefetch has nothing to evict but the line
behind; more lookahead needs more slots - the user's four consecutive lines (a window of the line
behind, the current and two ahead, the next-line want two lines out, the victim the slot furthest
behind) is the next rung; it does not touch the call/return demand fills (lever 1).

**THE BENCH'S ROOM MODEL WAS DISTORTING THE I SIDE (2026-09-19).** boot_gs_tb's merge back-pressure
model started a no-room burst with 12/256 probability per free clock, bursts averaging 32 clocks: the
modelled link had no room ~60% of the time, and the fetch stood 13.8 M of the Nox row's 59.1 M clocks
on it (a new l1i book, "resident-not-retiring", split by cause, found it). The model is `--room=P`
now (12 = as it was, kept as the default for the back-pressure paths that once hung on hardware; 0 =
room always, for a performance row). The Nox row at --room=0 on the early landing: **40.35 M clocks**;
the I side's real waits: not-resident (a fill on the way) 2.13 M clocks over ~0.74 M demand fills
(~3 each), the RECOVER bubble 0.80 M (every fetch to an address the predictor did not expect - a
taken transfer's target - costs one clock even with its line resident: the serve byte is registered
and the 816's din is register-direct; the a2's l1i keeps a TARGET SERVE, a pre-read byte at the
resolved target, and the two-line rewrite left it out), ifill 2.67 M. The bubble books are the l1i
debug words 10-13 now (il_res_bubble, il_res_recover, il_notres, il_noroom in the host's map), for
the card's DEC_I split on the next bit.

**THE PAGE BRAM, RE-READ AGAINST THOSE NUMBERS.** A page store whose read address comes from a tag
compare lands a line at the same clock as L2 does today (the dr port is nearly always free: 2.3
clocks per fill against a floor of 2), so as a FILL SOURCE it buys ~nothing. Its worth is as the
FETCH SOURCE, addressed by the PC directly with no compare on the address path (direct-mapped by
pc[11:0] for one tile / 16 pages; two-way with two tiles / 32 pages, the tags compared in parallel
and gating the retire, not the address): then ANY resident byte is one clock from its address -
the recover bubble's cost - and the resident set is 4-8 KB instead of two lines, so the ~3-clock
demand fills become 1-clock recovers, and with a target pre-read through the second port (the
target serve) the taken transfers to resident code retire with no bubble at all. The scanner
would read its bytes through that second port too. That is a rewrite of l1i's serve, not a bolt-on;
the target serve is the piece both designs need and the cheap first step.

**THE TARGET SERVE IS BACK (2026-09-20, rtl/gs/l1i.sv, from the a2's):** the target's byte is pre-read
into its own register the clock the target is known - the table's opcode-time decision, or the
operand-time resolution for a JMP/JSR (the high byte's clock, as the a2 does it) or a branch the table
did not know - kept fresh while its line is held, and the fetch that arrives there retires from it the
same clock. The Nox row at --room=0: **40.35 M -> 39.86 M clocks (-1.2%)**, the recover bubbles 0.80 M
-> 0.23 M (the rest are returns, indirect jumps and targets whose line was not held), gs suite 18/18,
14/14 checks. The row is 43.5% bus time (the boot's scan and disk), so on the map screen the share is
about double. The count is l1i debug word 15 (il_tgt_serves).
GS/OS 20 M instructions at --room=0 with it: 187.45 M clocks, 14/14 (the 306.9 M and 312.5 M rows
above ran under the old room model and are not comparable); its I side: 11.18 M not-resident clocks
against 1.21 M recovers - GS/OS misses lines, Nox mispredicts them.

**ON HARDWARE, gs_pt52 (early landing + target serve + the DEC_I split; TIMING MET +0.000, 0 of
74,623, a NEW DEEP TAIL of 403 endpoints b_ppn -> i_byte_q through the target select's retire terms,
cut in the tree after the build: the select is `tgt_serve` alone now). THE NOX MAP, 5 s = 500 M
clocks: 299.95 M ops = 58.8x (gs_pt51: 280.9 M = 55.0x, +6.8%). Buckets: retire 60.0%, DEC_D 14.1%
(70.7 M), I fill wait 10.3% (51.4 M), SEQ_FAST 5.9% (29.3 M; 10.06 M fast ops, 7.17 M writes), DEC_I
5.0% (25.1 M, was 44.2 M), D fill 3.9%, settle 0.7%. The I side 21.5% -> 15.3%. The new books, per
5 s: 10.03 M target serves; 4.85 M recover bubbles left (returns, indirect jumps, RTI - the
unpredictable transfers); 29.7 M not-resident clocks over ~8.9 M demand fills (31.0 M fills, 19.8 M
next-line prefetches, 2.27 M target prefetches, 17.0 M taken transfers whose line was held); 0 no-room.
Unexplained: ~42 M I-side clocks with the fetch up and neither resident-waiting nor line-waiting =
turbo_ok low (the books gate on it) - the next bit splits those by reason. The page-BRAM fetch source's
hardware target from these numbers: the 29.7 M demand-fill clocks -> ~8.9 M, the 4.85 M recovers stay
one clock each: ~5% of the map's clocks, more on GS/OS.

**RUNG 8 (planned 2026-09-20, the user's design): THE PAGE STORE - L1-I AS A BRAM FETCH SOURCE.**
Two RAMB36 as two ways of 16 pages x 256 B (8 KB), addressed by the NEXT PC with no compare on the
address path. The core exports `pc_d` = {pbr_d, pc_d}, the D input of its PC register (the load
arms UC_LD_PC_* replicated combinationally, pbr's UC_WB_PBR likewise; `pc` when cyc_en is low), so
the byte the next cycle fetches is read this clock: port A of each way reads 8 bits at pc_d[11:0],
the tags (per way 16 x {v, bank, addr[15:12], ppn, 16 row-valids}, flops) are read at pc_d[11:8]
and compared in the same clock, and the hit + the row-valid bit are REGISTERED beside the BRAM's
output register. The core's din is then the way mux of two BRAM output registers (one LUT level),
and a fetch to ANY resident byte retires on its own cycle: sequential, taken branch, JMP through a
vector, RTS, RTL, RTI, JSL - the transfer's target PC is the PC register's D input on the cycle
before the fetch, so nothing is predicted and nothing is a bubble. The two-line registers, the
expected-address predictor, the target table, the target serve and the scanner all go: the next-PC
read is what they approximated. Kept: the fill engine (TLB lookup, the dr port, the row landing at
F_W1) writing rows into a way through port B (64-bit writes, two per row, the write-wider-than-read
SDP template; the fallback is 32-bit TDP writes, four per row), the row-valid bits, a next-row
prefetch when the fetch enters a row's last quarter and the row after is not valid, and the
landing bypass (the wanted byte off the landing row into a side register, served next clock, so a
demand miss costs what it costs today, three clocks, not the write-then-read's five). Allocation:
a page miss takes the set's LRU way (16 LRU bits per way pair), clears its row-valids, then fills
the wanted row; a row miss on a resident page fills the row. Coherence as the lines': an image
write (cl_*, ws_*) clears the row's valid bit by ppn compare; map_changed, inval and !serve clear
every page; kill_v and evict_v are no longer deaths (the store copies memory, not L2, and every
write to memory is on the snoop). The scanner's other use, the branch-target prefetch of a line
outside the store, is dropped in this rung and measured: the bench's not-resident count says what
it was worth. Cost: 2 RAMB36 (48 -> 50 of 75), ~900 flops of tags and valids, fewer LUTs than the
lines and the scanner (~700). Measure: the Nox and GS/OS rows at --room=0 against 39.86 M and
187.45 M; the map census's il_notres and il_res_recover; a Pt bit.

**RUNG 8 BUILT (2026-09-20, rtl/gs/l1i_store.sv + store_ram.sv, the core's pc_d; the two-line l1i behind
-DL1I_LINES / build.tcl -l1i-lines).** Two bugs on the way, both found by the short boot: the store's din
had no fallback to the sequencer's byte (the reset vector's fetch fed the core garbage, PC at $00/C074
from instruction 0), and the row writes were registered a clock behind the row-valid bit, so a fetch
on that clock read the row's old bytes ($00/FE3D as $00 at instruction 24; the writes are combinational
from the engine's state now and share the bit's edge). Also: the claim must not stand in F_TLB (the
dispatcher's op is what places the page) - the lines' rule, and a deadlock without it. **Short boot
(250 k instructions, the KEGS floor): store 1.797 M clocks against the lines' 1.859 M (-3.4% at the
default room model), 12/12, the diff at the floor; 489 k one-clock fetches, 168 by the sequencer, 461
row fills (238 prefetches), 142 page allocations, not-resident 1,461 clocks against the lines' 38,302,
and no recover bubbles at all (the lines: 159,310).** Suite gs 18/18.
**The Nox row at --room=0: 38.92 M clocks** against 39.86 M with the lines + the target serve and 40.35 M
with the lines + the early landing (-2.4% and -3.5%), 14/14: 7.85 M one-clock fetches, 259 k row fills
(103 k prefetches, 108 k page allocations) against 1.14 M line fills, not-resident 0.69 M clocks
against 2.17 M, resident-not-retiring 16 clocks against 226 k, 98 k fetches by the sequencer (the I/O
page's and the excluded slot pages'). The row is 43.8% bus time (the boot's disk), so the I side was
already a small share here; the map screen is where it shows. Pt bit gs_pt53 building.
**GS/OS 20 M at --room=0: 185.45 M clocks** against 187.45 M (-1.1%), 14/14: 37.4 M one-clock fetches,
2.52 M row fills (1.17 M prefetches, 1.00 M page allocations, 0.90 M TLB waits), not-resident 10.26 M
clocks against 11.18 M - GS/OS's code working set is wider than 8 KB and the page allocations churn -
and 2.54 M fetches by the sequencer (unservable 12.8 M want-clocks: the pages the region table refuses
and the excluded slot pages, the same rule the lines applied).
**gs_pt53, the first store bit: TIMING MISS -2.330 ns (2,440 of 76,794), 31,889 LUTs (+3,358 over
gs_pt51), the two RAMs block RAMs as meant (512 x 64 write, 4 K x 8 read; 50 tiles).** The path: the
PC into the engine's own tag lookup on the want, through the TLB compare into the engine (17 levels);
the LUTs: three writers of per-bit logic under 512 row-valid flops, and the want's second set of tag
muxes. RESTRUCTURED: the fetch's want takes the lookup registered beside the RAM output (page_q,
pway_q, hit_q), the prefetch's address has its own lookup registered every clock (gated a clock, or a
row already held was fetched again), and a snoop clears a page's rows as a word (kills 8.9 k -> 9.7 k
in the Nox row: nothing). Short boot 12/12 unchanged, suite 18/18, **Nox row 37.93 M clocks** (was
38.92 M before the restructure, 39.86 M with the lines). Pt bit gs_pt54.

**gs_pt54 (the restructured store): TIMING MISS -1.894 ns, 32,140 LUTs (98.6% of a 50T).** The path is the
design's own loop: the store's RAM output -> the core's din -> the next PC (a JMP's high byte IS the
byte in flight) -> the tag lookup -> the registered hit, 15 levels. USER DECISION 2026-09-20: register
the store's read for the din-dependent loads (one bubble on JMP abs / JSR / returns / the vector pull,
~2% of the map's clocks), KEEP TWO WAYS (direct-mapped evicts caller and callee at one offset), and
DO THE LUT WORK FIRST - whatever the core does next needs the LUTs. No build without approval.

**THE LUT WORK (2026-09-20).** The synthesis-only hierarchy (the full IIgs set, 2026-09-19) by
module: u_card 9.5 k (the link), u_gsio 6.4 k, u_ddr3 4.0 k, u_doc 3.9 k, u_cache 3.7 k, u_u2 2.7 k, u_mb
1.9 k, u_cpu/u_tlb/u_iwm/u_l1d ~1.4 k each, u_mouse 1.2 k, u_regfile/u_rom/u_seq ~1.1 k each. The
trades, all cycle-for-LUT or flop-for-RAM: (1) the DOC's per-oscillator registers into distributed RAM
- DONE: rtl/gs/gs_doc.sv, 72 bits x 32 that were flops behind 32:1 muxes are seven single-writer
LUTRAMs with a reset sweep and a pending-clear mask for the accumulator; gs_doc_tb 25/25, the replay
sounds; **u_doc 3,942 -> 2,189 LUTs by synthesis (-1.75 k)**; (2) the books into a RAM - DONE:
rtl/common/book_ram.sv folds the two L1s' and the cache's counters (8 bits wide on the card, BOOK_W;
32 in the benches) round-robin into one LUTRAM of 32-bit totals with one adder; the debug read of a
counter word comes from the folder; the clock census stays in flops (its buckets sum to the clock);
(3) the chipset's static registers into a LUTRAM shadow, (4) the Uthernet's socket machine time-shared,
(5) the ROM loader's stage (u_rom 1.66 k) - pending. Measure: synthesis-only builds
(`build/run_build.sh TAG --gs --board pt_v2 -gs50t -l1i-lines -synth_only`), the lines set: 30,838
LUTs by synthesis with the DOC done (the implemented count runs lower than synthesis's).
**The books folder MEASURED AND REVERTED:** with the two L1s' and the cache's counters at eight bits
folding into one LUTRAM, synthesis gave 31,101 against 30,838 without it - up 263: a 32-bit counter is
an 8-LUT carry chain, narrowing it saves five, and the debug muxes it feeds stay; the folder and the
override mux cost more than that. The counters stay 32-bit flops. The lesson for the list: a flop
array behind a wide mux (the DOC's 72 x 32) pays; a counter does not.
**The ROM loader's drain, one word a clock: gs_top 30,838 -> 30,431 by synthesis (-407)**; the short boot
12/12 at +145 k clocks (the load's four clocks a line, once a boot). The lines set with the two trades:
30,431 by synthesis; the implemented count is the full Pt build lut1's.
**lut1, THE IMPLEMENTED COUNT (the lines set + the DOC and ROM loader trades, Pt): 28,017 LUTs against
gs_pt52's 28,531 - 514 fewer, 85.9% of a 50T; TIMING MET +0.000 (0 of 67,394); 52.5 tiles.** Synthesis
had promised 2.2 k: implementation was already trimming the DOC's flop arrays. A named deep tail (the
core's instruction register into l1d's serve counters' enables) is cut in the tree: the books count a
clock late from registered flags. The remaining LUTs by module (implemented, by inference from
synthesis's shares): the link ~8.5 k, the chipset ~4.2 k, the DDR3 controller ~3.6 k, L2 ~2.9 k, the
Uthernet ~2.5 k, the DOC ~2.0 k - the store's own cost on gs_pt54 was +3.6 k over the lines before its
LUTRAM-tag restructure, unmeasured since.
**lut1 ON HARDWARE (loaded 2026-09-20, swhost on gs_nox.conf, the map, 5 s): 299.94 M ops = 58.8x, the
same as gs_pt52 to four figures - the trades touch no fetch or data path.** And the RE-BUCKETED census
(the fill waits charged to the op that is up, the post-fast clock its own bucket) redraws the map of
the losses: retire 60.0%; **DEC_D 17.0% (84.9 M) + D fill 5.2% (26.0 M) = the D side 22.2%**; SEQ_FAST
6.2% (31.1 M) + post-fast 2.0% (10.1 M) = the dispatcher 8.2%; **I fill 5.0% (24.9 M) + DEC_I 3.8%
(18.9 M) = the I side 8.8%** (the old bucketing had charged I prefetches in flight under D ops to the I
side: "15.3%"); settle 0.7%, bus 0.1%. The D side is the larger lever by a factor of two and a half.

**THE SAME CENSUS ON THE GS/OS SCREEN (2026-09-20, lut1 on hardware, gs_nox.conf on system6.hdv,
the Finder idle at the desktop, three 5 s windows agreeing to four figures): 43.5x, not the map's
58.8x - 221.91 M ops over 5.10 M Apple cycles.** The losses are bucketed differently here, and the
difference is the finding: the DISPATCHER doubles its share and the settles grow fourfold.

| bucket | clocks (5 s) | the GS/OS screen | the Nox map |
|---|---|---|---|
| retire | 221.79 M | **44.4%** | 60.0% |
| DEC_D | 102.17 M | 20.4% | 17.0% |
| D fill | 29.59 M | 5.9% | 5.2% |
| **the D side** | **131.77 M** | **26.4%** | **22.2%** |
| SEQ_FAST | 68.96 M | 13.8% | 6.2% |
| post-fast | 11.27 M | 2.3% | 2.0% |
| **the dispatcher** | **80.23 M** | **16.0%** | **8.2%** |
| I fill | 22.28 M | 4.5% | 5.0% |
| DEC_I | 30.99 M | 6.2% | 3.8% |
| **the I side** | **53.28 M** | **10.7%** | **8.8%** |
| settle | 12.78 M | **2.6%** | 0.7% |
| bus | 0.15 M | 0.03% | 0.1% |
| held | 0 | 0 | 0 |

By kind, with what each op costs in clocks (its bucket share plus its retire clock):

| kind | ops (5 s) | clocks/op | its clocks |
|---|---|---|---|
| dline (data) | 115.01 M | 2.15 | 247 M (49%) |
| turbo (fetch) | 95.62 M | 1.56 | 149 M (30%) |
| **fast (the dispatcher)** | **11.28 M** | **8.11** | **91.5 M (18%)** |
| bus | 1,012 | - | ~0 |

**THE FAST OPS ARE 5.1% OF THE WORK AND 18% OF THE CLOCKS** - eight clocks each against a fetch's
one and a half - and 58% of them are kind I (6.50 M of 11.28 M; RAM 3.08 M, WR 1.57 M, CX 0.12 M,
ROM 20 k, KBD 3 k, LC 80), instruction fetches falling through L1-I to the dispatcher. The I-side
counters agree: il_notres 36.8 M in the window, il_restart 2.0 M. On the map the dispatcher is half
this share, which is why the map reads 58.8x and the desktop 43.5x. The other difference is SETTLE
at 2.6% against 0.7%: GS/OS moves PBR and DBR far more than a game loop does, and that is the
clock rung 5 ("the bank registers leave the map") is written to take back.

The levers as this screen prices them: the dispatcher's fast ops down to a 2-clock op returns ~69 M
clocks = 13.8% (~50x); rung 5's settles ~2.6% (~44.6x on their own); the D side is the biggest
absolute block at 49% of the clocks but already runs at 2.15 clocks an op - a grind, not a cliff.
The supporting counters over the same window: dl_serves 114.9 M (= the dline ops), dl_cam_serves
14.8 M, dl_decl 3.66 M, dl_claims 0, dl_reval_revive 42.95 M / dl_reval_drop 1.23 M, il_acks 6.82 M,
il_inst 876 k, pc_il_i / pc_il_d / pc_decline all 0.

## The L2 in sets (the user's direction, 2026-09-20; built and measured the same day)

The user, with the 32-slot CAM's working-set cliff on the Finder in hand: 32 ways fully
associative is expensive and it was the LUT expense that brought it down to 32 - can the
working-set policy (the TLB's pinning of the ways it points at, the referenced bit) let L2 go
back to a LARGER cache at a good associativity, eight ways, insulated from a stream by the same
hints?  Test the smaller geometry first, 16 x 8, on hardware; the benches are too short to bite;
the 50T question waits on the performance.

**THE SHAPE THAT WORKS IS THE CAM's, PARTITIONED.**  One RAM per way is out - way_ram is true
dual port at 128 bits, four RAMB36 an instance whatever its depth, so eight ways would be 32
tiles - so the store stays ONE block RAM and a slot is {set, way}; the directory is decided
before the row read as the CAM did, with the compare narrowed to a set.  rtl/gs/page_cam.sv
(SETS x WAYS): per way, SETS words of {tag, referenced, last offset} in LUTRAM (16 x 25, RAM32M
x 15 a way), read ASYNCHRONOUSLY by the entrant's set in P0 - the compare and the hit way's row
read stay in P0; three read addresses (the entrant's set, the op's set at P2, the direct read's
set) and one write a clock a way, by priority: the fill's retag (its slot is valid the same
clock, so its tag must land), the op's touch, a skipped pick's reference given up, the direct
read's touch (a lost touch is a lost hint).  The valid, dirty and TLB-pointed bits are flop
vectors, a bit a slot: each has more than one writer a clock.  The victim is chosen at P1
within the entrant's set from the bits registered at P0 (the engine's own slot masked; the
landings of the P0 and P1 clocks forwarded into the dirty bits - a stale dirty bit would drop
a page's writes, a stale pointed bit only costs a TLB kill); the victim's tag is read at P2 from
the LUTRAM at the op's set.  The set is a fold of the whole page number (bank byte included: the
64-set bug).  The PLRU is seven nodes a set in LUTRAM.  The L1 sides and the TLB are untouched:
their SIDX/LEV parameters were built for sets and ways and carry 4 + 3 bits where they carried
5 + 1.  Everything behind P0 is the CAM's, by name.

WHY LUTRAM AND NOT BLOCK RAM, AND NOT FLOPS.  L1's fills never consult the directory - the TLB
names {set, way} and a fill is a direct way read - so the lookup serves the op path (the
dispatcher's ops that bypass L1, the TLB's misses) and what matters there is LATENCY: a block
RAM directory reads synchronously and would cost every one of those a clock (about 3% on the
Nox census), plus a tile a way for the independent write ports, plus a walk to clear.  Flops
were the CAM's cost: 46 LUTs and 33 flops a slot, the index-decoded next-state selects and the
N:1 reads, linear in slots.  In LUTRAM the cost is per WAY.

**MEASURED (the Pt, gs_zelda.conf, the Finder idle at the desktop, accel 2 unlimited, three 5 s
windows = 500.0 M clocks each, both arms the same evening, all three agreeing to three figures):**

| | CAM 32 slots (fw 16:31) | 16 x 8 = 128 slots (fw 18:22) |
|---|---|---|
| ops retired / 5.10 M bus cycles | 242.8 M = **47.6x** | 281.3 M = **55.1x** (+15.8%) |
| L2 fills / flushes a window | 2.53 M / 366 k | 0.84 M / 80 k |
| DEC_D | 80.8 M | 71.0 M |
| SEQ_FAST | 73.4 M | 45.9 M |
| DEC_I | 35.6 M | 24.8 M |
| D fill wait / I fill wait | 30.0 M / 26.6 M | 34.3 M / 31.6 M |

The 64-slot CAM had measured 51.6x here: 128 slots at eight ways is past it, and the fill
rate says why - three quarters of the Finder's fills were re-fills of pages the 32 slots could
not hold.  The line-fill waits GREW while the L2 fills fell by three: the L1 sides are now fed
from L2 at a higher rate instead of waiting behind L2's own misses, and DEC_D and SEQ_FAST are
where the clocks came back from.  (The baseline's open window was GSHardDrive, the new bit's
ClassicsGS: the same idle loop, not the same pixels.)

**THE COST (the Pt, both TIMING MET; utilization_hier_gs_l2s16x8.rpt against l2s32):**

| module | LUTs | flops | RAMB36 |
|---|---|---|---|
| page_cam | 2,905 -> 2,810 (484 of them LUTRAM) | 2,470 -> 1,889 | 4 -> 8 |
| tlb | 1,045 -> 1,437 | 956 -> 992 | |
| l1i | 1,654 -> 1,579 | 1,363 -> 1,373 | |
| l1d | 1,531 -> 1,365 | 1,220 -> 1,224 | |
| design | 27,587 -> 27,598 | 23,132 -> 22,533 | 50 -> 54 |

LUT-NEUTRAL for four times the slots: the TLB's wider entries (7 bits of {set, way} against 5)
are paid for by page_cam and both L1 sides.  Depth: max 20, tail >= 14 482 (the l2s32 build:
18 / 321) - named, not a miss.  gs suite 18/18 (boot_gs 12/0), lint 73 OK; the bench's
`--l2=N --ways=N` are sets and ways; build.tcl's `-gsslots N` is the set count, `-gs50t` no
longer names a geometry.

**THE 50T CANDIDATE, THIS GEOMETRY (gs_50t_l2s16x8, 2026-09-20 19:05, the 50T part with the au_v2
pins, -gs50t): TIMING MISS -0.158 / whs +0.037, 40 of 68,917 endpoints; 27,316 LUTs = 83.8% (gs_50t2
with the CAM: 28,514 = 87.5%), flops 32.2%, 54 RAMB36 = 72% (48).**  The path hunt on the routed
checkpoint (build/results/paths_gs_50t_l2s16x8.txt): 38 of the 40 endpoints leave
`g_65816.u_cpu/pc_reg` - 29 into the microcode ROM's address (`urom`), 3 into l1i's `f_ppn`, the rest
l1d's `dq_pair` / `dq_kbd` / `dq_bz`, l1i's `i_byte_q` and the scan pointer, the core's `f_z`; the
other two from the hard disk's `pidx_reg` into `dq_addr`.  The worst: pc_reg[1] -> urom address, 12
levels, 77% route.  THAT IS THE CORE's BINDING LOOP (the PC into the next microcode word and the
L1 sides' next address), NOT THE CACHE - the same family the Pt build carries at its margin, now
under the 50T's congestion with four more tiles placed.  The bit is kept as
master_top_gs_50t_l2s16x8_MISS.bit, never to load.  Stopped here at the user's rule (a miss ends the
round; the options are the user's).

NEXT (the user's plan, in order): the Nox map (fits 8 KB already; a drop would be the hash or
the pipeline), XMAS at 2.8 (write sweeps, the write-around's case), a read stream through the
cache (a large Finder copy, then the Finder measured again - the set-conflict case the CAM did
not have); then, if wanted, 32 x 8 = 256 slots (16 RAMB36, the 50T's ceiling), with the LUT
count expected flat.

## The binding loop retimed (2026-09-20, the evening; built the same evening)

The 50T candidate with the L2 in sets missed on ONE family: 38 of 40 endpoints from the core's
`pc_reg`, 29 of them into the microcode ROM's address (12-13 levels, 77% route; the hunt in
build/results/paths_gs_50t_l2s16x8.txt).  The chain, link by link, on an opcode fetch: the PC
into L1-I's expected-address compare (`exp_q == pc_addr`, a 16-bit carry chain, 3 levels), the
serve select (1), the byte mux - target byte, held byte, or the bus - in l1i and again in the
core's din mux (2), the slot-0 lookahead - the decode ROM `useq0[fetch_op]` (a 256-entry LUT
ROM), the condition, the successor slot (5) - and the `uaddr` mux into the block RAM (1).  The
user: no placement constraints ("every attempt at placement constraints in this project has
failed and generally made things worse"); try both retimes.

WHAT IS LIVE ON THE PC IS ONLY THE CHOICE.  On a straight-line fetch the opcode byte is already
a flop (L1-I's `i_byte_q`, loaded at the previous edge with the byte at `exp_q`), and a taken
transfer's target byte is a flop too (`tgt_byte_q`).  So:

**Retime 1 - the slot-0 lookahead per candidate.**  L1-I exports its two serve REGISTERS
(`i_byte_r`, `tgt_byte_r`) and its selects (`i_sel_tgt`, `i_sel_held`, registers); the core
reads the eight-bit slot-0 ROM once per candidate, addressed by the register itself, and picks
between the two results by the selects; the bus arm reads the ROM from `i_din` live as before.
The ROM read no longer waits behind the byte select.  (The first cut read the ROMs from the
registers' D INPUTS into a register a cycle early - 7 levels on the fetch path - and hung the
candidate on the retire's deep cone: the hd's `ovr_en` through `turbo_ok` into `step` into the
byte select into the ROM, 17 levels on the Pt, six of the forty worst.  Reverted to the
registers: 9-10 levels on the fetch path, no new path.)

**Retime 2 - the stream's position as a flag.**  `at_exp_q` says `pc_addr == exp_q`, computed
a cycle early: the core exports `pc_ds1` / `pc_ds_v1`, the next PC over its SIMPLE arms only
(no load, INC, MD - RTS/RTI's pull - and JMPL) assuming cyc_en, and L1-I compares that against
its four possible next expected addresses (`tgt_inc`, `exp_inc`, `pc_addr`, `exp_q`) in
parallel, choosing by `tgt_serve` and the shallow step/recover terms, and LAST by the two deep
signals: the retire (turbo_ok, the room, the kills) and the core's cycle enable.  ONE-SIDED: on
an AGU / din / block-move arm the flag is low whatever the address, which costs a recover clock
only when a transfer lands exactly where the stream stood; a high flag where the compare would
say no would serve a wrong byte, and sim asserts it never happens.  The true compares stay on
the RETIRE (`tgt_here`'s 24-bit, the C3 kill's 8-bit), where they already were; the byte select
(`sel_tgt`, `lhit_q`) is registers alone.  The first cut compared the core's full `pc_d` (the
AGU's sum: five carry chains, 18 levels from L1-D's `dq_addr`) and reconstructed the core's
cycle enable as `retire || accel_cyc_en` - and the core's cycle enable is L1-D's, which carries
its own data-cycle commits: an RTS loads the PC on a data cycle, the flag stayed high, and the
20 M row's assertion caught the PC at $FE3C with the stream at $7629.  L1-I now takes the core's
cycle enable as an input (`core_cyc_en`).  The counted conservative lows (27,055 serve clocks
in 257 M on the row, 3 in the 250 k boot) are MVN/MVP's rewind arm at each loop's end and
branches that land on the fall-through; the user: not material.

**THE Pt (bit `bloop2`, 2026-09-20 20:12): TIMING MET +0.045 / whs +0.058, 0 of 72,719.**
27,739 LUTs (the geometry alone 27,598: the core 1,385 -> 1,435 for the two ROM copies, their
mux and `pc_ds1`; l1i 1,579 -> 1,602 for the flag's compares), flops 22,596 (+63), 54 RAMB36.
Depth max 18, the tail >= 14 364 (the geometry alone 482; the first retime cut 1,043).  The
worst path now `pc_reg` -> l1i's `dr_set` (a fill want) at 13 levels, MET.  gs suite 18/18, the
20 M GS/OS row 14/0 in 257.5 M clocks (the 32-slot CAM's row this morning: 312.5 M; the 128x8
set cache's: 279.8 M).  Not loaded (the hardware off for the night); the bit kept as
build/results/master_top_gs_bloop2.bit.  The first retime cut's Pt build (`bloop1`) MISSED
-0.132 on 12 endpoints, none of them `pc_reg` -> the ROM: the candidate register (6), the
flag's AGU compare (1), the TLB direct-read cone (the rest).

**THE 50T (`50t_bloop2`, 2026-09-20 20:26, the same source, -gs50t): TIMING MISS -0.391 /
whs +0.056, 122 of 68,931; 27,377 LUTs = 84.0%, flops 32.2%, 50 RAMB36 = 67%.**  The worst path
`u_seq/u_bank_reg` -> `u_cache/u_ram` port-B address, 13 levels (CARRY4 x2, RAMD32 x1), 74%
route.  The hunt (build/results/paths_gs_50t_bloop2.txt), the sixty worst by family:

| family | endpoints | worst | what it is |
|---|---|---|---|
| sequencer `u_addr` / `u_bank` -> the page RAM's port-B address | 17 (+3 from L1-D's `dq_addr`) | -0.601 | the L2-in-sets' direct-read cone: the op's page into the TLB's {bank, page} compare, the hit into `dr_req` / `dr_ack`, into the port-B address mux; the Pt closes it at its margin |
| sequencer `st_reg` -> the Uthernet's lane RAMs | 12 | -0.396 | the sequencer's state into the W5100's memory ports |
| L1-D `dq_addr` -> the microcode ROM's address | 9 | -0.338 | THE D SIDE's BINDING LOOP: the served byte into the early-carry adder (`esum_x`/`esum_y`/`esum_pc`) into `cond_next` -> `slot_n2` -> `uaddr` - the family the early-carry fold cut on the Pt this morning, exposed on the 50T now the I side's is gone |
| L1-D `dq_addr` -> the core's X, Y, f_z and L1-D's own decides | 6 | -0.352 | the same byte into the AGU and the register writes |
| TLB `ins_busy` -> `kill_ppn` / `ref_on` | 6 | -0.209 | the TLB's install |
| L1-I `vtag` -> `cnt_prefetch` | 4 | -0.169 | a counter |

`pc_reg` is the SOURCE OF NONE OF THEM: the I side's binding loop is closed on both parts.  What
the 50T misses on now is the D side's (the byte into the early carry into the ROM address) and
the L2's direct-read cone, both route-bound.  The bit kept as master_top_gs_50t_bloop2.bit,
never to load.  Stopped at the user's rule.

WHAT THE 50T NEEDS NEXT (the analysis, for the next round; the order is the slack's):
(1) the L2's direct-read cone - the op's page into the TLB's sixteen {bank, page} compares,
the hit into dr_req, the grant (`dr_ack`: eng_idle, !iv_run, !pw_pending, !dr_clash) into the
port-B address mux - is the L2-in-sets' own path and the worst on the 50T by a margin; it is
the shape the I side just had (a compare in front of a select) and takes the same cure: the
grant's terms are registers or can be, and the address the TLB names can be registered a
clock before the request; (2) the D side's binding loop - L1-D's served byte into the early-
carry adder into cond_next -> slot_n2 -> uaddr - is the morning's family, closed on the Pt by
the fold and exposed on the 50T; the byte's arrival is L1-D's registered serve, so the early
carry's three sums could be formed from the serve register's D input as the I side's ROM copies
are formed from the serve registers; (3) the Uthernet's lane RAMs from the sequencer's state
(12 endpoints, one module, the LUT diet's shape) - the last resort the 50T notes already name.
pc_reg sources nothing now; no placement constraint (the user's rule).

## The L2 geometry on GS/OS (2026-09-19, `--l2=SETSxWAYS` before the CAM, the 50T question)

The user has an immediate chance to build 50T boards (32,600 LUTs / 75 RAMB36) and keeps the
Uthernet; the DOC's 64 KB stays in block RAM (no DDR3 fetch engine, no LUTs for it), so the
tiles are: DOC 16 + link 11 + cpu 8 + IWM 3 + Uthernet 4 + the small ones 2.5 = 44.5 fixed (fb_sim's
4 dropped: the IIgs build never reads it), leaving 30.5 for L2 - 128x4 is 32 (over by 1.5),
64x7 is 28, 64x6 is 24. The GS/OS row (20 M instructions, the fast DMA in):

| L2 | tiles | clocks | fills / flushes | checks |
|---|---|---|---|---|
| 128x8 (today) | 64 | 282.9 M | 10.0 k / 7.1 k | 13/0 |
| 128x4 | 32 | **283.4 M (+0.2%)** | 19.9 k / 10.1 k | 13/0 |
| 64x7 | 28 | 213.8 M, but the boot failed | 8.7 k / 5.8 k | 12/3 |
| 64x6 | 24 | 213.9 M, but the boot failed | 9.5 k / 6.1 k | 12/3 |

**WITH THE CLEAN ROM AND THE TWO CACHE FIXES (later the same day), every geometry boots:**

| L2 | tiles | clocks | fills / flushes | checks |
|---|---|---|---|---|
| 128x8 | 64 | 279.8 M | 9.0 k / 6.1 k | 14/0 |
| 128x4 | 32 | 280.3 M (+0.2%) | 16.5 k / 9.3 k | 14/0 |
| **64x6** | **24** | **287.8 M (+2.9%)** | 151 k / 34 k | 14/0 |

64x6, the geometry that fits the 50T with the Uthernet kept and the DOC in block RAM (68.5 of 75
tiles), costs 3% on the GS/OS boot. XMAS with the clean ROM: 74.8 M (78.3 M before, -4.5%).

**Before the fixes, 128x4 cost nothing on GS/OS and the 64-set geometries FAILED:** DMA blocks land with zeroed bytes
and GS/OS stalls (the instruction count runs on in a loop). At 64 sets ROM 3's 1,024 pages hash
16 per set, so dirty ROM pages are evicted DURING THE LOAD and RAM pages thrash them after, a
path 128 sets never exercised (the ROM fits the cache exactly) and the a2 never exercised (a
20 KB ROM). The card's memory as a whole still holds the ROM afterwards (the audit's "written
back not the image's" counts partially written pages evicted mid-load and completed later); the
zeroed DMA bytes are the real defect - a write-miss path under thrash, the cache's or the fast
override's pacing when the block's page is not resident. Being split by a 64x6 row with the bus
DMA (`--slowdma`).

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
| 3b-6 (routed, the Pt) | 32,918 / 33,469 | | 112.5 | | | | gs_r3b MET +0.000, gs_r4 +0.142, gs_r5 +0.118, gs_r6 +0.269 (the two-line L1-I with the target table) |

## Sim ledger (the three rows, per rung)

| after rung | gs suite | GS/OS (20 M instr) | XMAS (8 M instr) | notes |
|---|---|---|---|---|
| 0 | 18/18 | 13/0, 392 M clocks, 10,106 fills / 7,156 flushes | 12/0, 76 M clocks, 2,018 / 989 | the baseline |
| 2 | 18/18 | 13/0, 19.49 M instructions at the 400 M ceiling (2% behind) | 12/0, 78 M clocks, 2,019 / 989 | L1-I on the TLB |
| 3 | 18/18 | 13/0, **18.03 M instructions at the 400 M ceiling (9% behind)**: 4.75 M L2 reads served, 14.8 M last-row serves, 14.4 M internal cycles at one clock, 7.4 M posts (1.36 M into $02-$7F, 29.7 k duplicates), **1.13 M TLB fills** (490 k from the data side, 585 k waits) | 12/0 before the vector-pull fix; the rerun after it pending (the watchdog's false positive under the 3.5" stall) | L1-D on the TLB |
| 3b (lookup B registered, the first-clock claim) | 18/18 | 13/0, 17.52 M instructions at the ceiling (12% behind): 4.60 M L2 reads served at five clocks, 1.08 M TLB fills (467 k from the data side, 556 k waits) | 12/0, 8.0 M instructions in 78.9 M clocks (2.5% behind); 153 k L2 reads served, 3.9 k TLB fills | the timing cut's price on GS/OS is the fifth clock and the thrash |
| 5 (the hd slot fast) | 18/18 | 13/0, **20 M instructions in 375.2 M clocks (the first row to finish under the ceiling; the old tree needed ~395 M, rung 3b reached 17.5 M at 400 M): bus ops 14 k from 590 k**; the $C7xx firmware 1.14 M fetches at a few clocks; 5.24 M L2 reads, 2.40 M sequencer-served fetches | 12/0, 78.86 M clocks (unchanged: no hd traffic) | at 268 M clocks 12.50 M instructions against 3b's 9.66 M and the old tree's ~10.2 M: +29% / +22% |
| 6 (the two-line L1-I) | 18/18 | 13/0, 20 M instructions in 373.1 M clocks; 594 k opcode-time target fetches, 4.49 M fills | 12/0, 78.29 M clocks | the census: DMA 37.6% of the clocks, the bench's room model 16% |
| 7 (the fast DMA) | 18/18 | 13/0, **20 M instructions in 282.9 M clocks** (-24%); 1,858 blocks, 1,844 intact; the DMA 1.4% of the clocks | 12/0, 78.29 M clocks | on hardware the same block cost applies: a GS/OS boot loses its quarter |
| 8 (the clean ROM, the snapshot and hash fixes, blocked ops retried) | 18/18 | 14/0, 20 M instructions in 279.8 M clocks (128x8); 280.3 M at 128x4; 287.8 M at 64x6 | 13/0, 74.8 M clocks (-4.5%) | ROM 3 in the DDR3 clean: flushes 7.1 k -> 6.1 k on the boot |
