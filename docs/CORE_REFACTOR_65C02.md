# The 65C02 card: the core / L1 / L2 refactor ladder

Status: **RUNG 3 DONE (sims) 2026-09-19, branch `core_refactor`**: the 65C02 card's page cache is 64 sets x 6 ways with the referenced-way rule, the placement report and the direct way read (rtl/a2/page_cache.sv header); page_cache_tb 61 checks at 128x8, 64x10, 64x8 and 64x6, lint 67, mem_integ 21/0, accel_vl 98/0 at both sweeps, boot 2/2; synthesis only: **32,674 LUTs / 21,384 flops / 47 RAMB36** (the cache 3,113 -> 2,030 LUTs, 64 -> 24 tiles) - block RAM is inside the Au's 50 for the first time; LUTs are L1's 9.9k to answer for in rungs 4-5. Earlier: RUNG 1 DONE (sims), RUNG 2's three cuts: the DDR3-free boot path is built - rtl/common/tx_ring.sv's boot lane, RING_CTRL 0x8000_0188, LINK_STAT[25]/[31], the host's checklist engaging the ring before BUS_ENABLE; tx_ring_tb with three boot-lane phases, reg_map_tb, both DDR3-model benches and the quick suite green; out of context the lane costs the ring +83 LUTs / +40 flops / +1 RAMB18 (372 -> 455 LUTs). Earlier: RUNG 0 DONE (a2_au_base: the Au refuses placement at 73 RAMB36 of 50 and 35k logic LUTs of 20.8k; a2_pt_base: the IIe routed on the Pt at 33,349 LUTs / 26,757 flops / 83 RAMB36, WNS -0.007, a numbers build not a loadable one; both tables in REQ_65C02.md §0). Rung 1 next; the peripheral-free floor is 25.6k LUTs, 12.4k of it outside L1/L2 (REQ §0). Requirements:
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

## The ladder

| rung | what | gate | status |
|---|---|---|---|
| 0 | **The baseline on the Au part.** Build today's IIe source with `--board au_v2`. It will not fit (83 RAMB36 against 50), so the number wanted is synthesis utilisation: LUTs, flops, RAMB36 by module, to replace REQ_65C02.md §0's ~32k estimate. Record it in §0. | a utilisation table, nothing else | **DONE 2026-09-18**: IIe routed 33,349 LUTs / 83 RAMB36; L1+L2 = 13.2k / 64; the Au synth pushed fb_sim, the ring and the capture FIFO into LUTRAM once its 50 tiles ran out; tables in REQ §0 |
| 1 | **The tree split and the rename.** rtl/common (link, DDR3, ring, protocol, register cut, telemetry, page_client, wb_arb, the peripherals both machines have), rtl/a2 (the 65C02 card: cpu65c02 + ucode, accel_seq, the L1 files, fast_census, floppy/vidhd/the IIe-only cards, a2_top from master_top's GS=0 arm with every GS conditional gone), rtl/gs (the 65816 card: cpu65816 + its ROMs, gs_*, bank_census, gs_top from the GS=1 arm). build.tcl gets a source list per target; the 62 sim scripts and 5 tools that name rtl/ paths follow (one sed each, checked by running them). In the a2 tree the L1 identifiers are renamed as the files are copied (accel_fronts_dis -> accel_l1_dis, front_settling -> l1_settling, g_fronts -> g_l1, front_byte -> l1_byte; the host telemetry key afrontsdis -> al1dis with a layout bump and tools/check_telem_map.py). | battery, cpu, boot and gs suites on their own trees | **SIMS GREEN 2026-09-18** (quick 34/34, gs 18/18, cpu 4/4, boot 2/2, mem_integ 21/0, page_cache 52/0 x3, fb_sim, accel_vl both sweeps at the recorded 280,000,000 clocks); the two Pt builds started for this rung were cancelled by the user's rule above; uncommitted |
| 2 | **The DDR3 and the link, cleaned up - and a DDR3-free boot path first.** REQ §1.10 (user, 2026-09-18): register replies and every startup message leave the ring and go to the FT601 directly (a second lane into the FT601 TX beside the ring reader, the ring engaged by a host write after calibration reads good and before BUS_ENABLE; the ring keeps the capture, the telemetry and the disk answers). Built first in this rung because it makes every DDR3 option build after it diagnosable over USB3 without the cable. **Built 2026-09-18** (tx_ring.sv "THE BOOT LANE", docs/TX_RING.md "The boot lane"; +83 LUTs on the ring OOC, the one RAMB18 is the lane's FIFO). Then the options: Measured at depth 4 on the rung-0 checkpoint: the UberDDR3 controller module itself is 3,509 LUTs / 2,798 flops (the wrapper and PHY 33), so the DDR3 question is UberDDR3's build options, not our wrapper: EYE_SWEEP / EYE_CENTER (the fork's read-eye measurement at calibration), SELF_REFRESH, and BIST_MODE/ECC/SECOND_WISHBONE/WB_ERROR already off (card_link.sv:692 passes BIST_MODE 0) - yet the BIST compare family index_wb_data_reg -> correct/wrong_read_data_reg still heads build/depth_baseline.txt at BIST_MODE 0, so part of the 3,509 is BIST logic the parameter does not remove; that is the first thing to read in the controller. The rule for this rung: the calibration that calibrates (CK write levelling, the IDELAY centring the card was proven with) is not touched; each option is turned off as its own build, measured on the Pt for LUTs AND for calibrating, because the calibration lottery (docs/UBERDDR3.md) is exactly the kind of thing an option change can move. An option raised 2026-09-18: move the eye sweep and centring OFF the card into a host-driven rig (a tap-load register face over the existing IDELAY load mux, a re-read-the-pattern strobe that latches the controller's write_pattern_matches, the host sweeping the 32 taps per lane and loading the centre while the machine is held in the start checklist); the eye itself is already host-visible as DDR3_EYE0/1. The same rig shape would drive the CK phase shift and read the DRAM's write-level feedback, which is the calibration lottery made observable from the bench. The link's other 5.2k: the register cut 1,225 LUTs / 3,041 flops (the telemetry shadows), telem_tx 665, event_merge 649, tx_ring 364, ft601_msg_rx 238, reg_front 230, msg_arb 196, bus_event_capture 191, uart_tx 179, wb_arb 156, the two FT601 FIFOs 207, page_client 114, the filter 91, reg_bridge 88, ft601_fifo 68, the top 98. Build the debug faces out of the production bit behind parameters (the BIST compare, the forensics, the census UART), and read the census for what else the card carries that no production machine uses. Measured on the Pt: the floor's non-L1/L2 LUTs against rung 0's 12,433. | both builds; lint; the link's benches (reg_map, tx_ring, telem, msg); DDR3 calibrates on the Pt (mem_ddr3_tb + a bit on the card that reads MEM_STAT image_ready); the floor number recorded in REQ §0 | |
| 3 | **L2 for the Au.** page_cache at 64 sets x 6 ways (96 KB, 24 RAMB36), the tree-PLRU's non-power-of-two fold already proven. Three additions: (a) the **referenced-way rule** - a bit per way set while an L1 TLB entry points at it, excluded from the victim choice, and a TLB fill REFUSED when a set has every way referenced; (b) the **TLB fill answer** - the directory path returns {set, way} beside the byte so L1 can fill its TLB from the ordinary lookup; (c) the **direct way read** - a request {set, way, line} that reads one way_ram row on port B when the engine is idle, two clocks, no directory, gated by the one-term landing/pending rule (the P+2 law's successor). ROM stays as pages in bank $FF. | page_cache_tb extended: the referenced-way sweep (a full set refuses, never evicts a pointed-at way), the direct read's row equals the model's before and after a landing, the P+2 sweep on the new port; mem_integ 21/0; boot_tb 2/2; **the Au build fits its block RAM**; Pt MET; Pt on HW: ProDOS, Nox, a 128K DHGR program (the three-quarters-resident case) |**DONE 2026-09-19 (sims)**: 64x6 in a2_top; refb per set, the victim prefers an unreferenced way and evict_v names every victim the clock the engine starts; op_place_v on a hit's decision or a fill's retag; dr_req/dr_ack/dr_done(+2)/dr_row on port B while the engine is idle, refused on the landing clock of its row and while a posted write is pending; page_cache_tb +9 checks (placement x2, the direct read and its landing sweep, the referenced miss, the forced eviction); synth 32,674 LUTs / 47 RAMB36 |
| 4 | **The TLB and L1-I.** An 8-entry LRU TLB {vpage, ppn, set, way, region, valid}, one lookup port per L1 side, revalidated on map_changed from the region table (the five-clock settle unchanged), snooped by physical page, filled from rung 2's answer, entries dropped when L2 declines them. L1-I becomes two 16-byte line buffers in flops with the +1 predictor, next-line prefetch through the pointer (a 3-4 clock fill), branch/JMP/JSR resolution from registered truth as today, and the $Cxxx / INTC8ROM exclusions unchanged (one register stage on the latch). iline and iscan retire; the retained set and the scanner go. | accel_vl at both sweep points with its checks re-cut for the new shape (the promote/pin/scan counters go; zero-stall branch serves, cxtest, bankfetch, smctest, the SMC-into-a-hot-line sweep stay); cpu_predict; boot_tb 2/2; both builds MET, the L1-I LUT count recorded against rung 0's 4.1k; Pt on HW at unlimited: the Nox map's PLAIN against 72.3x, the census's IFILL/DEC_I | |
| 5 | **L1-D.** The zp/stack shadow (512 B LUTRAM, lazy claim through the pointer), the last row (one 128-bit register, the row of the last L2 serve), the last byte (the CMOS dummy re-reads); every other data read a TLB hit serves **from the L2 row at two clocks with nothing installed**, launched from d_pred a cycle early; a TLB miss rides the dispatcher and fills the TLB. Writes: the one-clock retire below $C000 in RamWorks bank 0 stays, spliced into the shadow/last row and posted through the FIFO; whether a TLB-hit write lands directly in the known way (and the FIFO shrinks) is L1_RETHINK.md open question 3, decided here. dline retires; the 8x4 cache, the bank table and the per-line map copies go. | accel_vl (every one-clock and two-clock byte the reference's, the write scenarios, the interrupt storm); boot_tb 2/2 with the mode 0/2 trace parity; the splice-clock assertion widened to the two-clock serve; both builds MET, the L1-D LUT count against rung 0's 5.4k; Pt on HW: Nox, wave.dsk, Total Replay, a Mockingboard title, a WOZ title - the numbers against DLINE.md's | |
| 6 | **The dispatcher after L1.** With TLB-hit reads at two clocks, accel_seq's fast-op path serves only BUS-class ops, TLB misses and internalized $C0xx; its GS terms (S_NULL, gs_map_wr, sl_win, the bank on the stream) are already gone with rung 1. Cut what the histogram still charges: the settle-then-decide clock where the class is now the TLB's, the registered copies whose paragraphs describe chains that no longer exist. The governor is not touched (REQ §1.5). | accel_vl (mode 0 bit-exact, the reset sequence on the bus, the boot hold, the DMA); the clock histogram on HW: DEC_D and SEQ_FAST against rung 4's | |
| 7 | **The core.** Only after 1-5, and only what the census names: the dead WDC-variant logic and the ld_if bit go (REQ §2.5); the false path through the ucode ROM is re-checked against the new din cone; nothing in the cycle contract (REQ §2.1) moves. | cpu suite 4/4 at the exact Klaus cycle counts; trace_replay address-exact; both builds MET | |

## The budget checkpoint, after rung 5

With the floor cleaned (rung 2) and L1 + L2 rebuilt (rungs 3-5), read the Au build's LUT count
against 20,800 and decide what comes back in: the floppy and the HD first (1.5k together), then
the Mockingboard (1.7k), the mouse (1.1k), the Uthernet (2.6k). **The user's stance
(2026-09-18): everything is on the table, and if the fit needs a sacrifice not worth the saving,
the 65C02 card gives up the Au here** and the ladder continues on the Pt alone.

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
