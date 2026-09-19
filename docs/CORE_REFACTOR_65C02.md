# The 65C02 card: the core / L1 / L2 refactor ladder

Status: **BUDGET CHECKPOINT DECIDED 2026-09-19: the 35T cannot fit the full card (25,128 LUTs of 20,800 at synthesis); on a 50T Au variant the user may have manufactured the full card ROUTES AND MEETS TIMING at 23,022 LUTs = 70.6% (WNS +0.066, build a2_au50, no such board yet); the user's direction: develop and test on the Pt for both cards, watch resources against the 50T for both, bitstream builds resume (see "The budget checkpoint")**. RUNG 5 DONE (sims) 2026-09-19, branch `core_refactor`: L1-D is rtl/a2/l1d.sv (the shadow, the last row and the last byte at one clock; every other read a TLB hit covers served from the page cache's row at THREE clocks through the shared direct way read; writes as dline's rung 3); dline is gone from the a2 tree; accel_vl 98/0 at both sweeps (63.7x), quick 34/34, boot 2/2 (Nox 58.0 ops per bus cycle, unchanged); synthesis only: **25,124 LUTs / 15,562 flops / 47 RAMB36** (L1-D 5,256 -> 880; L1 + L2 together 4.6k of the 25.1k). Next: the budget checkpoint (the Au is 20,800 LUTs: ~4.3k over, all of it outside L1/L2 now), then rung 6. Earlier: RUNG 4 DONE (sims): L1-I is rtl/a2/l1i.sv (two line buffers filled by direct way reads) over rtl/a2/tlb.sv (eight entries naming the L2 set and way); iline and iscan are gone from the a2 tree; accel_vl 98/0 at both sweeps (99.9% of mode-2 fetches at one clock, 65.5x in the bench against ~71x before), quick 34/34, boot 2/2; synthesis only: **29,444 LUTs / 20,601 flops / 47 RAMB36** (L1-I 4.4k -> 1,237 LUTs; the ledger below). Next: rung 5 (L1-D). Earlier: RUNG 3 DONE (sims): the 65C02 card's page cache is 64 sets x 6 ways with the referenced-way rule, the placement report and the direct way read (rtl/a2/page_cache.sv header); page_cache_tb 61 checks at 128x8, 64x10, 64x8 and 64x6, lint 67, mem_integ 21/0, accel_vl 98/0 at both sweeps, boot 2/2; synthesis only: **32,674 LUTs / 21,384 flops / 47 RAMB36** (the cache 3,113 -> 2,030 LUTs, 64 -> 24 tiles) - block RAM is inside the Au's 50 for the first time; LUTs are L1's 9.9k to answer for in rungs 4-5. Earlier: RUNG 1 DONE (sims), RUNG 2's three cuts: the DDR3-free boot path is built - rtl/common/tx_ring.sv's boot lane, RING_CTRL 0x8000_0188, LINK_STAT[25]/[31], the host's checklist engaging the ring before BUS_ENABLE; tx_ring_tb with three boot-lane phases, reg_map_tb, both DDR3-model benches and the quick suite green; out of context the lane costs the ring +83 LUTs / +40 flops / +1 RAMB18 (372 -> 455 LUTs). Earlier: RUNG 0 DONE (a2_au_base: the Au refuses placement at 73 RAMB36 of 50 and 35k logic LUTs of 20.8k; a2_pt_base: the IIe routed on the Pt at 33,349 LUTs / 26,757 flops / 83 RAMB36, WNS -0.007, a numbers build not a loadable one; both tables in REQ_65C02.md §0). Rung 1 next; the peripheral-free floor is 25.6k LUTs, 12.4k of it outside L1/L2 (REQ §0). Requirements:
docs/REQ_65C02.md. Design discussion: docs/L1_RETHINK.md (the TLB carries the L2 way; the
sizes picked there). Sibling project, decided separately: the 65816 card (docs/REQ_65816.md, no
ladder yet).

## The gate, every rung

- Sims green under Verilator: the IIe battery (sim/suite.sh battery, 35/35 today), cpu, boot
  (both images, both modes); the GS suite (sim/suite.sh gs) stays green until rung 1 gives it its
  own tree, and after that on its own tree.
- **NO BITSTREAM BUILDS until the footprint fits the Au (user, 2026-09-18).** The design is
  ridiculously over the Au's budget (rung 0: 33k LUTs and 83 RAMB36 against 20.8k and 50), and a
  bit that cannot be tested on an Au proves nothing about feasibility, so there is no point in
  building one, on either part, until ALL the footprint work is done. Until then the per-rung
  measure of size is synthesis without implementation: `build/synth_ooc.sh` on the modules a rung
  changes (LUTs, flops, block RAM out of context), summed against the rung-0 table in REQ §0.
  The first bitstream is at the budget checkpoint below, and it is an Au build.
- The long-chain census by source register: no new deep tail; a chain the census names is cut.
- Hardware in the Apple only once there is a bitstream, which is after the budget checkpoint;
  until then a rung is proven in simulation alone. Explain the change before every run; verify
  from the mirror.
- Commit on request only, both repos in lock-step; never push.

## Rung 2's footprint ledger (2026-09-18, out-of-context synthesis, the Pt part)

| block | as built | lever | measured | note |
|---|---|---|---|---|
| tx_ring | 372 LUTs / 325 FF / 4 RAMB36 | the boot lane (required, REQ 1.10) | **455 / 365 / 4 + 1 RAMB18** | +83 LUTs is the requirement's price |
| the register cut (wb_regfile) | 1,225 LUTs / 3,041 FF | none in its shape: 153 shadow flops behind a 102-way 32-bit read mux is what random-access readback of a hundred words costs (~46 LUT6 per bit); the lever is FEWER READABLE WORDS | **DONE 2026-09-19 (the user): wb_regfile's MINIMAL, set by a2_top through card_link's MINIMAL_REGS: 56 of 102 words (every counter, census, statistic and debug word) read zero, their shadows and the counters feeding them fall out of the netlist; measured next by OOC of a2's card_link** | what comes back in is decided later, word by word |
| the UART report (uart_tx 179, uart_rx, report_tx and card_link's rpt_* formatter) | ~300-400 LUTs | the DDR3-free boot path makes the UART status line redundant | **DONE 2026-09-19 (the user): gone from card_link, both cards; the pins stay (tx idles high); build/ddr3_census_run.sh is retired with it** | the 'R' reset over the FT2232H went with it; LINK_RESET over USB3 is the reset that remains |
| UberDDR3 (ddr3_wrapper, OOC with `--clock clk_ctrl`) - **the strip is DONE 2026-09-19 (the user): fork commit acd12a7 on strudelworks-research, the pin in third_party/fetch_uberddr3.sh bumped; a calibrating bit is still owed before it is trusted** | 3,224 LUTs / 2,657 FF (synthesis; 3,509 routed in the rung-0 build) | the eight `(* mark_debug *)` attributes stripped from the fork's ddr3_controller.v: on `state_calibrate`, the BIST address counters, `correct_read_data`/`wrong_read_data`, `write_level_fail`, `lane`, `instruction_address`, `o_calib_complete` - they pin the BIST compare and the calibration FSM's encoding, which is why that family heads the depth baseline at BIST_MODE 0 | **2,950 / 2,594: -274 LUTs, -63 FF** | a fork change (third_party/UberDDR3 is the pinned fork); function unchanged, but the FSM may be re-encoded and the calibration lottery was placement-sensitive, so its adoption wants a calibrating bit - which the 65816 card (the Pt) can build, the 65C02 card cannot until the checkpoint. The user's call |
| UberDDR3, EYE_SWEEP/EYE_CENTER off (the wrapper now passes them through) | | the fork's read-eye sweep and centring | with mark_debug on: **3,407** (183 MORE than as built - synthesis re-shuffles around the pinned registers); with it stripped: **2,929 / 2,579**, i.e. -21 LUTs / -15 FF against the strip alone | NOT a lever: the sweep is ~20 LUTs. Keep it; it is the instrument the calibration lottery was read with. The UART text engine is under `ifdef UART_DEBUG` and is not built |

### The whole card, synthesis only, before and after 2026-09-19's three cuts

`build/build.sh --master --synth-only` (new: synthesise, report, no bitstream), the Pt part, the
tree at 4ab5136 with the fork at c2caf89 against the working tree with the fork at acd12a7:

| | LUTs | flops | RAMB36 |
|---|---|---|---|
| before (the boot lane in, nothing else) | 35,867 | 27,018 | 87 |
| after (mark_debug strip, register file MINIMAL, UART report gone) | **33,758** | **21,434** | 87 |
| delta | **-2,109** | **-5,584** | 0 |

By module: card_link -1,150 LUTs / -2,437 FF (the register file 1,255 -> 582 LUTs and 3,044 ->
1,014 flops at its minimum; the UART's 196-LUT transmitter, its receiver and the formatter gone;
the controller -87 in context); L1-D -308 / -547 and L1-I -304 / -581
(their books, unread, pruned); page_cache -188 / -618 (its counters); accel_seq -31 / -200; the
top -24 / -974 (the clock histogram and the snapshot words). Synthesis numbers are not routed
numbers (rung 0's 33,349 was routed); the delta is like for like. The Au is 20,800: the floor
outside L1/L2 is now ~10.3k synthesised, and L1 + L2 (rungs 3-5) are 13.0k of the 33.8k.

## Rung 4's footprint ledger (2026-09-19, synthesis only, the Pt part)

| | LUTs | flops | RAMB36 |
|---|---|---|---|
| after rung 3 | 32,674 | 21,384 | 47 |
| after rung 4 | **29,444** | **20,601** | 47 |
| delta | **-3,230** | -783 | 0 |

By module: iline + iscan (4.4k LUTs / 2.1k flops after rung 2's pruning) -> l1i 719 / 547 +
tlb 518 / 442; page_cache 2,030 -> 2,335 (+305: the direct-read port's muxes were tied off and
pruned until now); dline unchanged at 5,256 / 5,451 - rung 5's whole target; the card's floor
outside L1/L2 ~10.3k as before. L1 + L2 now 9.1k of the 29.4k.

What the benches say about the shape: 99.9% of mode-2 fetches at one clock in accel_vl (99.3%
before), 65.5x against ~71x - the two buffers refetch across a loop wider than 32 bytes where the
retained set held it; the ProDOS boot filled the TLB 24,510 times in 2 M bus cycles (eight
entries thrash on a boot that touches every page) and Nox 1,957 - the size the user picked, kept
until the budget checkpoint says otherwise. ACCEL_IDROP / ACCEL_IREVIVE carry the TLB's deaths
and fills now. The benches run the card's 64x6 geometry (they were 128x8, never evicting); their
rt_rd_flat was 70 bits wide against the MMU's 104, so regions 9-12 never revalidated in either
bench until now.

## Rung 5's footprint ledger (2026-09-19, synthesis only, the Pt part)

| | LUTs | flops | RAMB36 |
|---|---|---|---|
| after rung 4 | 29,444 | 20,601 | 47 |
| after rung 5 | **25,124** | **15,562** | 47 |
| delta | **-4,320** | -5,039 | 0 |

By module: dline 5,256 / 5,451 -> l1d 880 / 581 (200 of the LUTs the shadow's LUTRAM); tlb 518
-> 727 (lookup B and the second fill port); l1i 719 -> 699; page_cache 2,335 unchanged (its
line port, now unused on this card, is pruned by nothing yet); apple_mmu 305 -> 131 (the
d-side query's consumers thinned); accel_seq 927 -> 974. L1 + L2 = 4,641 LUTs of 25,124; the
card is 4.3k LUTs over the Au's 20,800 with the whole of L1 + L2 inside 4.7k - the remainder is
the link, the DDR3 controller, the peripherals and the core, which is the budget checkpoint's
question.

What the benches say: accel_vl 63.7x (65.5x after rung 4, ~71x before), 233,961 data reads
served by L1-D in the mode-2 phase of which 50,907 by the three-clock path and 62,412 launched
(the rest were answered by a one-clock server on the launch clock or abandoned: 0 abandoned);
the Nox boot 58.0 ops per bus cycle, unchanged from rung 4, with 9,471 three-clock reads
against 23.3 M serves (the shadow and the last row take nearly everything on that map); ProDOS
9.5. ACCEL_DDROP / ACCEL_DREVIVE carry the three-clock serves and the data side's TLB fills.

## The ladder

| rung | what | gate | status |
|---|---|---|---|
| 0 | **The baseline on the Au part.** Build today's IIe source with `--board au_v2`. It will not fit (83 RAMB36 against 50), so the number wanted is synthesis utilisation: LUTs, flops, RAMB36 by module, to replace REQ_65C02.md §0's ~32k estimate. Record it in §0. | a utilisation table, nothing else | **DONE 2026-09-18**: IIe routed 33,349 LUTs / 83 RAMB36; L1+L2 = 13.2k / 64; the Au synth pushed fb_sim, the ring and the capture FIFO into LUTRAM once its 50 tiles ran out; tables in REQ §0 |
| 1 | **The tree split and the rename.** rtl/common (link, DDR3, ring, protocol, register cut, telemetry, page_client, wb_arb, the peripherals both machines have), rtl/a2 (the 65C02 card: cpu65c02 + ucode, accel_seq, the L1 files, fast_census, floppy/vidhd/the IIe-only cards, a2_top from master_top's GS=0 arm with every GS conditional gone), rtl/gs (the 65816 card: cpu65816 + its ROMs, gs_*, bank_census, gs_top from the GS=1 arm). build.tcl gets a source list per target; the 62 sim scripts and 5 tools that name rtl/ paths follow (one sed each, checked by running them). In the a2 tree the L1 identifiers are renamed as the files are copied (accel_fronts_dis -> accel_l1_dis, front_settling -> l1_settling, g_fronts -> g_l1, front_byte -> l1_byte; the host telemetry key afrontsdis -> al1dis with a layout bump and tools/check_telem_map.py). | battery, cpu, boot and gs suites on their own trees | **SIMS GREEN 2026-09-18** (quick 34/34, gs 18/18, cpu 4/4, boot 2/2, mem_integ 21/0, page_cache 52/0 x3, fb_sim, accel_vl both sweeps at the recorded 280,000,000 clocks); the two Pt builds started for this rung were cancelled by the user's rule above; uncommitted |
| 2 | **The DDR3 and the link, cleaned up - and a DDR3-free boot path first.** REQ §1.10 (user, 2026-09-18): register replies and every startup message leave the ring and go to the FT601 directly (a second lane into the FT601 TX beside the ring reader, the ring engaged by a host write after calibration reads good and before BUS_ENABLE; the ring keeps the capture, the telemetry and the disk answers). Built first in this rung because it makes every DDR3 option build after it diagnosable over USB3 without the cable. **Built 2026-09-18** (tx_ring.sv "THE BOOT LANE", docs/TX_RING.md "The boot lane"; +83 LUTs on the ring OOC, the one RAMB18 is the lane's FIFO). Then the options: Measured at depth 4 on the rung-0 checkpoint: the UberDDR3 controller module itself is 3,509 LUTs / 2,798 flops (the wrapper and PHY 33), so the DDR3 question is UberDDR3's build options, not our wrapper: EYE_SWEEP / EYE_CENTER (the fork's read-eye measurement at calibration), SELF_REFRESH, and BIST_MODE/ECC/SECOND_WISHBONE/WB_ERROR already off (card_link.sv:692 passes BIST_MODE 0) - yet the BIST compare family index_wb_data_reg -> correct/wrong_read_data_reg still heads build/depth_baseline.txt at BIST_MODE 0, so part of the 3,509 is BIST logic the parameter does not remove; that is the first thing to read in the controller. The rule for this rung: the calibration that calibrates (CK write levelling, the IDELAY centring the card was proven with) is not touched; each option is turned off as its own build, measured on the Pt for LUTs AND for calibrating, because the calibration lottery (docs/UBERDDR3.md) is exactly the kind of thing an option change can move. An option raised 2026-09-18: move the eye sweep and centring OFF the card into a host-driven rig (a tap-load register face over the existing IDELAY load mux, a re-read-the-pattern strobe that latches the controller's write_pattern_matches, the host sweeping the 32 taps per lane and loading the centre while the machine is held in the start checklist); the eye itself is already host-visible as DDR3_EYE0/1. The same rig shape would drive the CK phase shift and read the DRAM's write-level feedback, which is the calibration lottery made observable from the bench. The link's other 5.2k: the register cut 1,225 LUTs / 3,041 flops (the telemetry shadows), telem_tx 665, event_merge 649, tx_ring 364, ft601_msg_rx 238, reg_front 230, msg_arb 196, bus_event_capture 191, uart_tx 179, wb_arb 156, the two FT601 FIFOs 207, page_client 114, the filter 91, reg_bridge 88, ft601_fifo 68, the top 98. Build the debug faces out of the production bit behind parameters (the BIST compare, the forensics, the census UART), and read the census for what else the card carries that no production machine uses. Measured on the Pt: the floor's non-L1/L2 LUTs against rung 0's 12,433. | both builds; lint; the link's benches (reg_map, tx_ring, telem, msg); DDR3 calibrates on the Pt (mem_ddr3_tb + a bit on the card that reads MEM_STAT image_ready); the floor number recorded in REQ §0 | |
| 3 | **L2 for the Au.** page_cache at 64 sets x 6 ways (96 KB, 24 RAMB36), the tree-PLRU's non-power-of-two fold already proven. Three additions: (a) the **referenced-way rule** - a bit per way set while an L1 TLB entry points at it, excluded from the victim choice, and a TLB fill REFUSED when a set has every way referenced; (b) the **TLB fill answer** - the directory path returns {set, way} beside the byte so L1 can fill its TLB from the ordinary lookup; (c) the **direct way read** - a request {set, way, line} that reads one way_ram row on port B when the engine is idle, two clocks, no directory, gated by the one-term landing/pending rule (the P+2 law's successor). ROM stays as pages in bank $FF. | page_cache_tb extended: the referenced-way sweep (a full set refuses, never evicts a pointed-at way), the direct read's row equals the model's before and after a landing, the P+2 sweep on the new port; mem_integ 21/0; boot_tb 2/2; **the Au build fits its block RAM**; Pt MET; Pt on HW: ProDOS, Nox, a 128K DHGR program (the three-quarters-resident case) |**DONE 2026-09-19 (sims)**: 64x6 in a2_top; refb per set, the victim prefers an unreferenced way and evict_v names every victim the clock the engine starts; op_place_v on a hit's decision or a fill's retag; dr_req/dr_ack/dr_done(+2)/dr_row on port B while the engine is idle, refused on the landing clock of its row and while a posted write is pending; page_cache_tb +9 checks (placement x2, the direct read and its landing sweep, the referenced miss, the forced eviction); synth 32,674 LUTs / 47 RAMB36 |
| 4 | **The TLB and L1-I.** An 8-entry TLB {vpage, ppn, set, way, region, valid}, one lookup port per L1 side, revalidated on map_changed from the region table (the five-clock settle unchanged), snooped by physical page, filled from rung 2's answer, entries dropped when L2 declines them. L1-I becomes two 16-byte line buffers in flops with the +1 predictor, next-line prefetch through the pointer (a 3-4 clock fill), branch/JMP/JSR resolution from registered truth as today, and the $Cxxx / INTC8ROM exclusions unchanged (one register stage on the latch). iline and iscan retire; the retained set and the scanner go. | accel_vl at both sweep points with its checks re-cut for the new shape (the promote/pin/scan counters go; zero-stall branch serves, cxtest, bankfetch, smctest, the SMC-into-a-hot-line sweep stay); cpu_predict; boot_tb 2/2; both builds MET, the L1-I LUT count recorded against rung 0's 4.1k; Pt on HW at unlimited: the Nox map's PLAIN against 72.3x, the census's IFILL/DEC_I | **DONE 2026-09-19 (sims)**: rtl/a2/tlb.sv (8 entries {vpage, ppn, set, way, region, fold}, round-robin, revalidated one clock after map_changed by the lines' rv_ok rule, two-clock install that unreferences the replaced way and names its page so buffers die, killed by evict_v) and rtl/a2/l1i.sv (two buffers, `cur` and the pin, wants fetch > branch target > next line, engine F_IDLE/F_DR/F_W1/F_W2/F_TLB, nothing launches during the settle - the bankfetch scenario found that on the first run); accel_vl 98/0 x2, boot 2/2, quick 34/34; synth 29,444 LUTs / 47 RAMB36, L1-I 1,237 (l1i 719 + tlb 518) against rung 0's 4.1k; no bitstream (the rule) |
| 5 | **L1-D.** The zp/stack shadow (512 B LUTRAM, lazy claim through the pointer), the last row (one 128-bit register, the row of the last L2 serve), the last byte (the CMOS dummy re-reads); every other data read a TLB hit serves **from the L2 row at two clocks with nothing installed**, launched from d_pred a cycle early; a TLB miss rides the dispatcher and fills the TLB. Writes: the one-clock retire below $C000 in RamWorks bank 0 stays, spliced into the shadow/last row and posted through the FIFO; whether a TLB-hit write lands directly in the known way (and the FIFO shrinks) is L1_RETHINK.md open question 3, decided here. dline retires; the 8x4 cache, the bank table and the per-line map copies go. | accel_vl (every one-clock and two-clock byte the reference's, the write scenarios, the interrupt storm); boot_tb 2/2 with the mode 0/2 trace parity; the splice-clock assertion widened to the two-clock serve; both builds MET, the L1-D LUT count against rung 0's 5.4k; Pt on HW: Nox, wave.dsk, Total Replay, a Mockingboard title, a WOZ title - the numbers against DLINE.md's | **DONE 2026-09-19 (sims)**: rtl/a2/l1d.sv; the three-clock read launches from the REGISTERED candidate through TLB lookup B (a two-clock read would need the launch on d_pred's own cone, which the law forbids), the row lands in the last row and the read retires from it; the launch claims the dispatcher from its intent, abandons on a map change or a write into its line in flight, and is refused while a posted write is pending; the data side fills the TLB through a second, held fill port; the shadow claims from op_row only (the page cache's line port has no user on this card); LESSON: a launch whose cycle a one-clock server answered must not stand for the next candidate (l2_live) - the first cut deadlocked the ROM's reset code that way; accel_vl 98/0 x2, boot 2/2, quick 34/34; synth 25,124 LUTs / 47 RAMB36, L1-D 880 (dline was 5,256), tlb 727 with the second lookup; TLB-hit writes still post through the FIFO (open question 3 left as is) |
| 6 | **The dispatcher after L1.** With TLB-hit reads at two clocks, accel_seq's fast-op path serves only BUS-class ops, TLB misses and internalized $C0xx; its GS terms (S_NULL, gs_map_wr, sl_win, the bank on the stream) are already gone with rung 1. Cut what the histogram still charges: the settle-then-decide clock where the class is now the TLB's, the registered copies whose paragraphs describe chains that no longer exist. The governor is not touched (REQ §1.5). | accel_vl (mode 0 bit-exact, the reset sequence on the bus, the boot hold, the DMA); the clock histogram on HW: DEC_D and SEQ_FAST against rung 4's | |
| 7 | **The core.** Only after 1-5, and only what the census names: the dead WDC-variant logic and the ld_if bit go (REQ §2.5); the false path through the ucode ROM is re-checked against the new din cone; nothing in the cycle contract (REQ §2.1) moves. | cpu suite 4/4 at the exact Klaus cycle counts; trace_replay address-exact; both builds MET | |

## The budget checkpoint, after rung 5 - MEASURED 2026-09-19 (fw 4f3cb2b)

With the floor cleaned (rung 2) and L1 + L2 rebuilt (rungs 3-5), read the Au build's LUT count
against 20,800 and decide what comes back in: the floppy and the HD first (1.5k together), then
the Mockingboard (1.7k), the mouse (1.1k), the Uthernet (2.6k). **The user's stance
(2026-09-18): everything is on the table, and if the fit needs a sacrifice not worth the saving,
the 65C02 card gives up the Au here** and the ladder continues on the Pt alone.

**The measurement** (`build/build.sh --master --board au_v2 --synth-only`, xc7a35tftg256-2, the
whole a2 card with every peripheral, synthesis only - no bitstream, by the rule):

| | Au synthesis | the Au | |
|---|---|---|---|
| slice LUTs | **25,128** | 20,800 | **121%** |
| of which logic | 23,593 | 20,800 | 113% |
| LUT as memory | 1,535 | 9,600 | 16% |
| flops | 15,563 | 41,600 | 37% |
| RAMB36 tiles | 47 | 50 | 94% |
| bonded IOB | 140 | 170 | 82% |

Where it goes (top-level modules, LUTs):

| | LUTs | |
|---|---|---|
| **the floor without peripherals** | **16,961** | 82% of the Au by itself |
| of which L1 + L2 (l1i 699, l1d 880, tlb 727, page_cache 2,335) | 4,641 | rungs 3-5's result, from 13.2k |
| of which the rest: card_link 8,636 (the DDR3 wrapper 3,952, the register file 614 + reg_front 423 + bridge 68, the event merge 656, the ring 512, telemetry 365, msg_arb 260, msg_rx 240, capture 213, wb_arb 182, the two FIFOs 294, page_client 113, filter 92, the rest ~180), cpu65c02 1,318, accel_seq 974, vbl_lock 485, rom_loader 337, bus write 173, vbeam 154, apple_mmu 131, kbd 80, bus read 32 | 12,320 | |
| **the peripherals** | **8,150** | |
| Uthernet II | 2,667 | |
| Mockingboard/Phasor (two AY pairs 1,025, four VIAs 521, two SSI-263 310) | 1,866 | |
| mouse | 1,152 | |
| floppy | 976 | |
| HD | 527 | |
| audio sampler + tx | 524 | |
| game port, printer, VidHD, NSC | 438 | |

**The DDR3 controller has no parameter lever**: out of context the wrapper is 2,951 LUTs as built,
2,950 with BIST_MODE=0 and 2,929 with the eye sweep and centring off as well (rung 2's -274 for
the mark_debug strip was the whole of it).

**What this says.** The full IIe feature set - the rung-1 gate as written - does not fit: 4.3k
LUTs over at synthesis, before any routing margin, and a 100 MHz design with a DDR3 controller
and one-clock serve cones has never closed on this fabric above ~85-90% of the LUTs (the Pt's
IIe build was congestion-bound at 53%). The peripheral-free floor alone is 82% of the part.
The levers left are all small: rungs 6-7 (accel_seq + core, 2.3k, perhaps -0.5k), telemetry off
(-0.4k with its registers), trims in the merge/capture/reg_front (~-0.3k) - call it -1.2k, a
floor of ~15.7k. Against an ~18.5k ceiling that leaves ~2.8k for peripherals: the floppy, the HD,
the audio, the game port, the clock, the printer and the VidHD signature (2,465) - and NOT the
Mockingboard (even a plain one without the Phasor and the SSI-263s is ~1.0k), NOT the mouse, NOT
the Uthernet. The one structural lever of the right size is the DDR3 itself (the wrapper, the
ring, the client and the arbiter: 4.8k), which would mean a card with no RamWorks beyond the
block RAM and a different link buffer - a different design, not a rung.

**So the checkpoint's answer is the user's decision, with these two roads:**

1. **Give up the Au for the 65C02 card and continue on the Pt.** The refactor has already paid:
   the a2 card is 25.1k LUTs where the shared IIe build was 33.3k routed and the GS 40k, with
   L1 + L2 at 4.6k instead of 13.2k - which is exactly the timing relief the whole rethink set
   out for (docs/DLINE.md "the fronts' timing is a draw"). Rungs 6-7 continue on the Pt, and the
   first bitstream since 2026-09-18 is a Pt build of this tree.
2. **A reduced Au variant**: an Au build target that carries the floppy, the HD, the speaker,
   the game port, the clock, the printer and the VidHD signature, and no sound card, no mouse,
   no network - feasible on paper at ~18k after rungs 6-7 and the telemetry cut, unproven for
   timing, and a second build target to keep green. Its first real test is an Au build after
   rung 7, which the no-bitstream rule allows once the reduced set synthesises under budget.

The recommendation recorded here (2026-09-19): road 1, with road 2 kept open as a later variant
if a sound-card-less, mouse-less IIe card is worth $200 to enough people.

3. **A third road (the user, 2026-09-19): an Au variant manufactured with a 50T.** The
   xc7a50tftg256 is the 35T's footprint (the same 170 I/O, the same balls, so the Au V2's pin
   constraints and the MIG's DDR3 wiring apply unchanged) with 32,600 LUTs, 65,200 flops,
   75 RAMB36 and 120 DSPs. At synthesis the full card is 25,128 LUTs = **77%** of it, 47 of 75
   tiles = 63%, every peripheral in. No such board exists, so it cannot be hardware-tested; what
   can be seen is the build: `build/run_build.sh a2_au50 --board au_v2 -part xc7a50tftg256-2`,
   a full place-and-route on the part with the Au's constraints, for the routed utilisation and
   the timing verdict. (Its bitstream is not loadable anywhere and is never loaded.) Result:
   see "The 50T build" below.

### The 50T build (2026-09-19, build/master_build_a2_au50.log, fw 4f3cb2b + the checkpoint docs)

**TIMING MET, WNS +0.066 / WHS +0.012, 0 failing of 55,613 endpoints**, the DDR3 pad checks in
their windows (tDQSS +0.054 slow / +0.033 fast), route_design 79 seconds, post-placement
congestion at most 4x4 (nothing).

| routed on xc7a50tftg256-2 | used | of | |
|---|---|---|---|
| slice LUTs | **23,022** | 32,600 | **70.6%** |
| of which logic | 21,495 | 32,600 | 65.9% |
| LUT as memory | 1,527 | 9,600 | 15.9% |
| flops | 15,347 | 65,200 | 23.5% |
| RAMB36 tiles | 47 | 75 | 62.7% |
| bonded IOB | 137 | 170 | 80.6% |

Logic depth: max 15 (the baseline's 21), 183 paths at 14 or more (was 259); the census names a
NEW deep tail of 13 endpoints, all in the renamed tree: the core's PC into L1-D's candidate
valid bits and L1-I's early want (pcl -> dq_v / dq_wv / ew_v), L1-D's serve into the 65C02's
flags (dq_addr -> f_c, dq_byte -> f_n: the same family the old design carried as
dq_sx -> f_z/f_n), and the ROM loader's chunk checksum (dr_k -> rom_sum, eight endpoints). The
baseline predates the tree split and names paths under master_top, so it is re-saved from this
build once the Pt build of the same source has been read against it.

**The decision (the user, 2026-09-19):** this is plausible. Development and testing continue on
the Pt for BOTH cards, and resource consumption is watched against the 50T's envelope (32,600
LUTs, 65,200 flops, 75 RAMB36) for both projects: delivering one or both within a 50T "would
reduce production costs quite a lot". The no-bitstream rule of 2026-09-18 is lifted; the Pt
build of this tree (a2_pt_r5) is the first to go on hardware: **TIMING MET, WNS +0.278 / WHS
+0.029, 0 failing of 55,606** (the old tree's last IIe build missed at -0.007), 22,993 LUTs / 47
RAMB36 on the 100T; the depth baseline is re-saved from it (max 15, 190 paths at >= 14, the
families: the core's PC into L1's candidate registers, L1-D's serve into the flags, the boot
hold into the filter's counters, the ROM loader's checksum).

**ON HARDWARE (2026-09-19, bit a2_pt_r5 in the Pt's SRAM, host a1dd5da):** the DDR3 calibrated
on the first load (eye 4+7/12 both lanes, write-levelled early/late), the link came up over the
boot lane with the build's stamp, swhost engaged the ring, and Nox booted from the hard disk to
its overworld map at accel ALL, unlimited - the first run of the boot lane, the minimal register
file, the TLB, l1i, l1d and the 64x6 page cache on a card. What was missing: the PLAIN figure
and the census (the host showed 0.00x and its on-screen figure went blank), because rung 2's
MINIMAL register file zeroed the accelerator's words too. The twenty ACCEL_* words read their
counters again under MINIMAL from this day (rtl/common/wb_regfile.sv); the rebuild is a2_pt_r5b:
TIMING MET +0.166, 23,341 LUTs (+348 for the twenty words), loaded and measured on the Nox
overworld map at accel ALL, unlimited: **60.0x** (core cycles 61.2 M/s over 1.02 M bus
cycles/s; 45.1 M turbo + 13.3 M dline + 2.8 M fast ops/s; 32 k map changes/s) against the
old tree's 72.3x on the same screen (docs/DLINE.md) - a 17% step back for L1 + L2 at a third
of the LUTs, the deliberate trade (the user, 2026-09-19). The depth baseline is re-saved from
this build. The bench's forecast held: accel_vl 63.7x, the boot bench's Nox 58.0. The 65816 card's own L1/L2 rungs
are what would bring it under the same envelope (it was ~40k on the Pt before the refactor).

## Rules for the ladder

- **Rungs land in order and each is a bitstream on the machine**, not a branch of promises. A
  rung that fails its gate is reverted whole, as rung 4 of the old dline ladder was.
- **The Au build is a build, not a board.** There is no Au in the Apple today; fit and timing on
  the 35T are proven by the build, the machine by the Pt. If an Au card is ever wanted in a
  machine, that is a hardware step of its own (the v5.2 carrier's pin table is board-neutral).
- **Nothing in the common tree changes for this ladder** unless both cards need it; a change there
  is a commit both tops build against.
- **The requirements doc is the judge.** A proposal that breaks a numbered item in
  docs/REQ_65C02.md says so by number, and the user decides; a proposal that changes a
  requirement changes the doc first.
- **Sizes are picked, not modelled** (L1_RETHINK.md): TLB 8, L1-I 2 buffers, L1-D shadow + last
  row + last byte, L2 64x6. The first build measures them; the census says whether to move.

## The rung-3 questions, decided in the rung (2026-09-19)

1. **Port B**: the direct read takes port B only while the miss engine is idle (dr_ack needs
   eng_idle); a fixed slot in the beat stream was not needed, because the engine holds port B for
   whole fills and flushes only, tens of clocks at a time, and a read that waits them out is still
   far cheaper than a fill.
2. **A full set is never refused**: instead of refusing the TLB fill, L2 prefers an unreferenced
   way, and when every way is referenced (or a page nobody referenced is chosen) it takes the
   tree's pick and BROADCASTS it (evict_v, the set and way) the clock the engine starts. The
   pointer dies before the fill can land, and an op can never deadlock on a set full of
   references. The invariant is "a pointed-at way is never a victim while another will do".
3. **The TLB's shape** is rung 4's; L2 offers one reference writer and one direct-read port, which
   a shared TLB or two can drive through an arbiter as L1 sees fit.
