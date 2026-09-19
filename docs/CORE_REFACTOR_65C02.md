# The 65C02 card: the core / L1 / L2 refactor ladder

Status: **RUNG 0 DONE 2026-09-18, branch `core_refactor`** (a2_au_base: the Au refuses placement at 73 RAMB36 of 50 and 35k logic LUTs of 20.8k; a2_pt_base: the IIe routed on the Pt at 33,349 LUTs / 26,757 flops / 83 RAMB36, WNS -0.007, a numbers build not a loadable one; both tables in REQ_65C02.md §0). Rung 1 next; the peripheral-free floor is 25.6k LUTs, 12.4k of it outside L1/L2 (REQ §0). Requirements:
docs/REQ_65C02.md. Design discussion: docs/L1_RETHINK.md (the TLB carries the L2 way; the
sizes picked there). Sibling project, decided separately: the 65816 card (docs/REQ_65816.md, no
ladder yet).

## The gate, every rung

- Sims green under Verilator: the IIe battery (sim/suite.sh battery, 35/35 today), cpu, boot
  (both images, both modes); the GS suite (sim/suite.sh gs) stays green until rung 1 gives it its
  own tree, and after that on its own tree.
- **Two builds, both TIMING MET with zero failing endpoints**: the Pt (`build/build.sh --master`)
  and the Au (`build/build.sh --master --board au_v2`). The Au build is the hard gate from rung 1
  (REQ_65C02.md §0). Read build/wns.sh, never the exit status; judge over more than one build when
  a verdict is within a tenth of a nanosecond.
- The long-chain census by source register: no new deep tail; a chain the census names is cut.
- Hardware on the Pt in the Apple for every rung that changes what the machine sees (the Au
  build proves fit and timing; the Pt proves the machine). Explain the change before every run;
  verify from the mirror.
- Commit on request only, both repos in lock-step; never push.

## The ladder

| rung | what | gate | status |
|---|---|---|---|
| 0 | **The baseline on the Au part.** Build today's IIe source with `--board au_v2`. It will not fit (83 RAMB36 against 50), so the number wanted is synthesis utilisation: LUTs, flops, RAMB36 by module, to replace REQ_65C02.md §0's ~32k estimate. Record it in §0. | a utilisation table, nothing else | **DONE 2026-09-18**: IIe routed 33,349 LUTs / 83 RAMB36; L1+L2 = 13.2k / 64; the Au synth pushed fb_sim, the ring and the capture FIFO into LUTRAM once its 50 tiles ran out; tables in REQ §0 |
| 1 | **The tree split and the rename.** rtl/common (link, DDR3, ring, protocol, register cut, telemetry, page_client, wb_arb, the peripherals both machines have), rtl/a2 (the 65C02 card: cpu65c02 + ucode, accel_seq, the L1 files, fast_census, floppy/vidhd/the IIe-only cards, a2_top from master_top's GS=0 arm with every GS conditional gone), rtl/gs (the 65816 card: cpu65816 + its ROMs, gs_*, bank_census, gs_top from the GS=1 arm). build.tcl gets a source list per target; the 62 sim scripts and 5 tools that name rtl/ paths follow (one sed each, checked by running them). In the a2 tree the L1 identifiers are renamed as the files are copied (accel_fronts_dis -> accel_l1_dis, front_settling -> l1_settling, g_fronts -> g_l1, front_byte -> l1_byte; the host telemetry key afrontsdis -> al1dis with a layout bump and tools/check_telem_map.py). | battery 35/35 and gs 13/13 on their own trees; both Pt builds MET; the a2 Pt build's LUT/BRAM within noise of rung 0's (a split moves nothing); depth baseline re-saved for the renamed paths; a2 bit on the Pt boots ProDOS and Nox | |
| 2 | **The DDR3 and the link, cleaned up - and a DDR3-free boot path first.** REQ §1.10 (user, 2026-09-18): register replies and every startup message leave the ring and go to the FT601 directly (a second lane into the FT601 TX beside the ring reader, the ring engaged by a host write after calibration reads good and before BUS_ENABLE; the ring keeps the capture, the telemetry and the disk answers). Built first in this rung because it makes every DDR3 option build after it diagnosable over USB3 without the cable. Then the options: Measured at depth 4 on the rung-0 checkpoint: the UberDDR3 controller module itself is 3,509 LUTs / 2,798 flops (the wrapper and PHY 33), so the DDR3 question is UberDDR3's build options, not our wrapper: EYE_SWEEP / EYE_CENTER (the fork's read-eye measurement at calibration), SELF_REFRESH, and BIST_MODE/ECC/SECOND_WISHBONE/WB_ERROR already off (card_link.sv:692 passes BIST_MODE 0) - yet the BIST compare family index_wb_data_reg -> correct/wrong_read_data_reg still heads build/depth_baseline.txt at BIST_MODE 0, so part of the 3,509 is BIST logic the parameter does not remove; that is the first thing to read in the controller. The rule for this rung: the calibration that calibrates (CK write levelling, the IDELAY centring the card was proven with) is not touched; each option is turned off as its own build, measured on the Pt for LUTs AND for calibrating, because the calibration lottery (docs/UBERDDR3.md) is exactly the kind of thing an option change can move. An option raised 2026-09-18: move the eye sweep and centring OFF the card into a host-driven rig (a tap-load register face over the existing IDELAY load mux, a re-read-the-pattern strobe that latches the controller's write_pattern_matches, the host sweeping the 32 taps per lane and loading the centre while the machine is held in the start checklist); the eye itself is already host-visible as DDR3_EYE0/1. The same rig shape would drive the CK phase shift and read the DRAM's write-level feedback, which is the calibration lottery made observable from the bench. The link's other 5.2k: the register cut 1,225 LUTs / 3,041 flops (the telemetry shadows), telem_tx 665, event_merge 649, tx_ring 364, ft601_msg_rx 238, reg_front 230, msg_arb 196, bus_event_capture 191, uart_tx 179, wb_arb 156, the two FT601 FIFOs 207, page_client 114, the filter 91, reg_bridge 88, ft601_fifo 68, the top 98. Build the debug faces out of the production bit behind parameters (the BIST compare, the forensics, the census UART), and read the census for what else the card carries that no production machine uses. Measured on the Pt: the floor's non-L1/L2 LUTs against rung 0's 12,433. | both builds; lint; the link's benches (reg_map, tx_ring, telem, msg); DDR3 calibrates on the Pt (mem_ddr3_tb + a bit on the card that reads MEM_STAT image_ready); the floor number recorded in REQ §0 | |
| 3 | **L2 for the Au.** page_cache at 64 sets x 6 ways (96 KB, 24 RAMB36), the tree-PLRU's non-power-of-two fold already proven. Three additions: (a) the **referenced-way rule** - a bit per way set while an L1 TLB entry points at it, excluded from the victim choice, and a TLB fill REFUSED when a set has every way referenced; (b) the **TLB fill answer** - the directory path returns {set, way} beside the byte so L1 can fill its TLB from the ordinary lookup; (c) the **direct way read** - a request {set, way, line} that reads one way_ram row on port B when the engine is idle, two clocks, no directory, gated by the one-term landing/pending rule (the P+2 law's successor). ROM stays as pages in bank $FF. | page_cache_tb extended: the referenced-way sweep (a full set refuses, never evicts a pointed-at way), the direct read's row equals the model's before and after a landing, the P+2 sweep on the new port; mem_integ 21/0; boot_tb 2/2; **the Au build fits its block RAM**; Pt MET; Pt on HW: ProDOS, Nox, a 128K DHGR program (the three-quarters-resident case) | |
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

## Open before rung 2 (decide in the rung, record here)

1. Port B sharing between the direct read and the miss engine: engine-idle only, or a fixed slot
   in the fill/flush beat stream.
2. The referenced-way refusal: how L1 learns a fill was refused (a decline with a reason) and
   whether a refused page is retried after the set drains.
3. Whether the TLB is one structure with two lookup ports or one per side (L1_RETHINK.md q5).
