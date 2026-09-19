# The 65816 card: the core / L1 / L2 refactor ladder

Status: **THE 50T CANDIDATE MEETS TIMING 2026-09-19 (gs_50t2: +0.082, 28,514 LUTs = 87.5%, 48 RAMB36 = 64% of a 50T; the CAM-L2 at 32 slots with the write-around, the clean ROM, the fast DMA and slot path, the two-line L1-I; no Mockingboard, no mouse card, MINIMAL registers; GS/OS +11.7% on the boot against the Pt's set cache, XMAS +1%; uncommitted after fw 171eef4). Earlier the same day, rungs 0-3: the gs card is l1i + l1d over a 16-entry {bank, page} TLB and the shared page cache at 128 x 8; Pt bit gs_r3b TIMING MET +0.000 at 32,918 LUTs routed (from 42,860 synthesised at rung 0; L1 10.9k -> 3.4k), 112.5 RAMB36; gs suite 18/18, GS/OS 13/0 and XMAS 12/0; GS/OS runs 12% behind the old tree at equal clocks because sixteen TLB entries thrash on it (1.08 M fills in 17.5 M instructions) - the census rows at 32 and 64 entries are the next number; the bit is NOT on the machine. Rung 0's baseline: 42,860 LUTs / 33,025 flops / 110 RAMB36 against the 50T envelope's 32,600 / 65,200 / 75.** The sibling
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
