# UberDDR3 on the card: placement, logic depth, and the calibration that sometimes never comes

Status: 2026-09-18, branch `ddr3_write_level` (fw 87001b1 / fork c2caf89 / host e3a8c38), not pushed. RUNGS 0, 1 AND 2 DONE, 2 ON HARDWARE: `ckphase1` (IIe, MET +0.017) calibrates first time with the card write-levelling its own CK, and D4 measures the board for the first time - byte lane 0's DQS crosses CK 74 ps early, lane 1's 30 ps late, 104 ps apart and straddling it, CK parked at their mean. The UART carries DDR3_DBG1..4 whole, the no-ODELAY write-level feedback exists, the 22-level BIST family is cut to 12, and the skew sweep reproduces the card's never-calibrating restart beyond +-625 ps and fixes it with the phase shift on. The census (4 draws of one RTL, all loaded) found no failing draw; a same-commit control build with the phase shift OFF MISSES timing at -0.043 in the fronts, which is the other lottery. Open: make CK_PHASE_SHIFT the default and draw again; accel_test.sh has two red checks that are NOT rung 2's (one is on the bitstream this session began with).
## Why

Three IIgs bitstreams that MET timing never calibrated the DDR3 (`gs_icache`, `gs_oprow2`,
`gs_iwmwr2`; docs/GS.md "The retained set and the DDR3", docs/IWM35.md "On hardware"), while
the same RTL rebuilt, or a smaller bit, calibrated on the same card.  `check_timing` is clean
in all of them.  The only observability was the UART's `D` (`o_calib_complete`) and `K`
(`state_calibrate`, sampled at ~1 Hz).  UberDDR3 had been left untouched on purpose (pinned
upstream, unpatched since fw 239cf02); this is the pass that opens it.

**Not a factor:** the Apple's power.  The slot rail is fenced from the Pt (it feeds only the
dual-rail transceivers), and the "Apple off" reading in docs/IWM35.md was a misread of the
UART line (`P=1` is PHI0 ticking; `C=` is captured events).  Power problems in general remain
possible on the USB-fed Pt; the longer-term answer is external 12 V into the Pt's regulator.

## What the code says (file:line under `third_party/UberDDR3/rtl/`)

**ODELAY_SUPPORTED=1 is not available here.**  Measured in Vivado 2026.1 on the part
(`link_design -part xc7a100tfgg484-2`): ODELAYE2 sites **0**, IDELAYE2 sites 300, bank 15
`BT_HIGH_RANGE`, HP banks 0.  Upstream's ODELAY topology (CK = OSERDES→ODELAY→OBUFDS,
DQ/DQS on one clock with the 90° from DQS's ODELAY taps, closed-loop write leveling in
`WAIT_FOR_FEEDBACK`, `ddr3_controller.v:2783-2851`) cannot place on an Artix-7.

**The PHY as built for us** (`ODELAY_SUPPORTED=0`, 2 lanes, 100/400 MHz): 44 OSERDESE2 -
24 command (SDR x4 on `i_ddr3_clk`), 16 DQ + 2 DM on `i_ddr3_clk_90` (`ddr3_phy.v:635`,
`:917`), 2 DQS on `!i_ddr3_clk` (`:1126`); 18 ISERDESE2 (DQ and DQS alike) clocked by the
free-running `i_ddr3_clk`, CLKDIV `i_controller_clk`, `NETWORKING` mode - DQS is never a
capture clock, the read window is found by walking IDELAY taps (31 x 78 ps, one tCK of
range).  One IDELAYCTRL.  The only attributes in the file are `IODELAY_GROUP`.  **CK was the
odd one out: `OBUFDS(.I(!i_ddr3_clk))` (`:473`)** - a fabric inversion of the BUFG net, no
OLOGIC element - and with no ODELAY there is **no write leveling at all**
(`ddr3_controller.v:2765-2771` short-circuits `START_WRITE_LEVEL`), so CK-vs-command and
CK-vs-DQS (tDQSS, +-0.25 tCK) are open loop.

**The calibration FSM** (`ddr3_controller.v:362-386`; `K` is two hex digits: 00 IDLE, 02
MPR_READ, 04 ANALYZE_DQS, 05 CALIBRATE_DQS, 09-0B ISSUE_WRITE/READ, 0D ANALYZE_DATA, 0E
CHECK_STARTING_DATA, 17 DONE_CALIBRATE).  With our `BIST_MODE(0)` (`rtl/card_link.sv:582`)
`D=1` means "training converged".  There is **no timeout and no retry bound anywhere**: the
ANALYZE_DQS<->MPR_READ loop and the CALIBRATE_DQS tap walk run until they succeed or for
ever, and a failure of both write/read alignment hypotheses is `reset_from_calibrate`
(`:3045`, `:3151`) - a full restart from ROM instruction 0 that spends >99 % of its ~1.4 ms
in IDLE.  **So a 1 Hz `K=00` cannot tell "stuck in IDLE" from "restarting for ever"**; the
`00 -> 04 -> 00` seen on 2026-09-12 fits either.  `idelayctrl_rdy` is sampled raw by the FSM
(`:2518`).  `DIC`/`RTT_NOM` are left at upstream's defaults (RZQ/6, RZQ/6) where MIG's project
for this board says RZQ/7 and RZQ/4 (`ref/mig_pt_v2.prj:111,114`).

**Logic depth:** the design's deepest family is the controller's BIST compare
(`index_wb_data_reg -> correct_read_data`, 22 levels) at **+2.17 ns** - deep, not critical.  No
DDR3 path is in the timing tail; the controller is not a slack problem.

## What the routed checkpoints say (`build/ddr3_forensics.sh`)

Two checkpoints, `gs_norefgate` (calibrates) and the 2026-09-12 14:19 MISS build (never loaded):

| | norefgate | miss0912 |
|---|---|---|
| CK driver | `LUT1` in `SLICE_X0Y107`, 1.376 ns route to the OBUFDS | `LUT1` in `SLICE_X0Y108` |
| CK pad arrival, slow / fast corner (ns after the clk edge) | 2.986 / 0.640 | 2.983 / 0.643 |
| command pad arrival, slow / fast | 1.339 / 0.213 | 1.339 / 0.213 |
| DQS pad arrival (data path), slow / fast | 2.657 / 1.474 | 2.657 / 1.474 |
| **CK leg - CMD leg** | **+1.647 ns** | +1.644 ns |
| command setup / hold at the CK edge (ideal 1.25 / 1.25) | **0.397 / 2.103** (slow), 1.677 / 0.823 (fast) | same |
| tDQSS (window +-0.625) | **+0.921** (slow), -0.416 (fast) | same |
| BUFG sites (ctrl / ddr3 / ddr3_90) | X0Y0 / X0Y1 / X0Y2 | same |
| controller cells X0Y2 / X0Y3 | 2309 / 3721 | 3795 / 2195 |
| u_ddr3 LUTs combined with LUTs outside u_ddr3 | 0 | 0 |

Read it this way:

- **The CK leg is a large, STATIC error, not the build-to-build variable.**  The placer
  parks the inverter beside the IOB every time (adjacent slices, 3 ps apart).  But the
  commands leave through the OLOGIC in 1.34 ns and CK through a LUT and a route in 2.99 ns,
  so the DRAM sees ~0.40 ns of command setup instead of 1.25, and DQS trails the CK edge by
  0.92 ns at the slow corner - outside JEDEC's +-0.625 - while at the fast corner it leads by
  0.42.  A fabric path and an OLOGIC path do not scale together across corners, and a
  fabric path is the one that sags under IR drop.  That is a marginal write timing that a
  bigger, busier bit can push over the edge without any placement of its own changing.
- BUFG sites, IDELAYCTRL, IDELAY sites: identical.  Clock-network variance is acquitted.
- LUT combining never crosses the `u_ddr3` boundary.  Physical synthesis is acquitted.
- The controller's split across X0Y2/X0Y3 differs - it affects only timed paths.

## Change 1: `CK_OSERDES` (fork `ddr3_phy.v`, no-ODELAY branch)

The clock pin from the same OSERDESE2 the ODELAY branch uses (`:317-361`), D = `0,1,0,1,...`
so the pad still carries `!i_ddr3_clk`, minus the ODELAY; parameter `CK_OSERDES` (default 1,
plumbed through `ddr3_top.v` and `rtl/ddr3_wrapper.sv`).  Measured on the routed design
(`build/results/ddr3_forensics_ckserdes.txt`): CK from `OLOGIC_X0Y108`, pad arrival 1.391 ns
against the commands' 1.339 - **CK - CMD +0.052 ns, command setup/hold 1.302/1.198 ns, tDQSS
+0.016 ns** at the slow corner, +0.008 / +0.003 at the fast corner: both legs are OLOGIC paths
now and scale together.  Build MET +0.011 / +0.054, 45 OSERDES, gates clean.  Hardware:
calibrates, Arkanoid at 62x.

Bench (`sim/run_mem_ddr3_tb.sh`, Micron model, no board skew): calibrates either way and the
ring data is word-exact; the model's OSERDES puts CK 100 ps later than the pure inverter did,
and that was enough for the DQS pattern search to read its start index as 8 then 7, aim at
"next odd" = 9, walk all 32 taps and come round through the wrap fix-up (141 MPR reads,
37.35 us) where the inverter took 14 reads (7.59 us).  Same final answer - a robustness note
for the tap walk (see "Next").  The bench's latency check fails on the unpatched tree with
either clock leg (`first line max 57, 25 transactions past clock 92`): its expectation was
written for the refresh gate that fw 239cf02 removed and it was never re-run - not this
change's doing, to be re-baselined separately.

## Change 2: the instrumentation (fork `ddr3_controller.v`, `ddr3_top.v`; fw wrapper, card_link, regfile; host)

- `idelayctrl_rdy` two-flop synchronised and qualified by sixteen stable cycles before
  the FSM leaves IDLE (it was a raw sample fanning into the next-state mux and the four
  delay-line loads).
- Sticky diagnostics cleared only by the external reset: the highest `state_calibrate`
  reached, the `reset_from_calibrate` / `reset_from_test` counts, IDELAYCTRL RDY drops,
  the state at the last self-reset.
- `o_debug1..3` with a documented layout (docs/PROTOCOL.md `DDR3_DBG1..3`,
  `0x8000_0140/144/148`): state, lane, ROM step, the lane's taps, RDY, the alignment
  hypotheses, the highest state; the sticky counters; the DQS pattern indices.
- The UART line grows ` M=xx X=xx` after `K=xx`: the highest state reached and the
  self-restart count.  The host polls DBG1/DBG2 in its RING_STATUS/LINK_STAT rotation and
  prints `ddrk= ddrmax= ddrrst= ddrtest= ddrrdy=`; the MCP LINK line shows
  `[cal state K max M restarts N/T]` whenever the DDR3 is down or a restart has happened.
- `CAL_TRACE` (`ifdef`) prints every state transition and self-reset in the benches.

Fork branch `strudelworks-research`: `phy: drive the DDR3 clock pin from an OSERDES ...`,
`top: pass CK_OSERDES ...`, `controller: synchronise IDELAYCTRL RDY, sticky calibration
diagnostics, o_debug1..3` (not pushed yet - `gh auth login` first).

## Change 3: the read data eye (fork `EYE_SWEEP`, `o_calib_eye`; fw `DDR3_EYE0/1`)

After every lane's write/read alignment passes, the controller re-reads the alignment
pattern at address 0 with the lane's DQ IDELAY at every tap 0..31 - the same request and the
same `write_pattern_matches` pipeline `ANALYZE_DATA` uses - and records one bit per tap
(states 25-30, ~3 us per lane), then loads the calibrated tap back.  `DDR3_EYE0/1`
(`0x8000_014C/0150`, docs/PROTOCOL.md) hold the two masks; the host prints `ddreye0=
ddreye1= ddrtap=` (the delay line's calibrated DQ tap: the register in DBG1 is one ahead of
it) and the MCP LINK line summarises `eye 5+9/16 taps` = margin below / above the calibrated
tap / width of the run.  A run is bounded by one bit slot (16 taps = 1.25 ns), i.e. the
setup-plus-hold window around the sample point.  In the zero-skew Micron model each lane
reads `000000ff` around tap 0 (the model's ideal point is below tap 0); the number that
matters is the board's.

## Change 4: `EYE_CENTER` (fork, needs `EYE_SWEEP`)

While the sweep records a lane's mask it tracks the run of passing taps the calibrated tap
falls in, and at the end loads the delay line with that run's centre instead of the walk's
tap: seven taps below the upper edge when the run is clipped at tap 0 (the eye is close to
one bit slot, 16 taps, wide, so the lower edge is unseen), the midpoint otherwise.  The run
is what the sweep validated at the calibrated bit-slot alignment, so the move cannot leave
the alignment; `idelay_data_cntvaluein` follows (so `ddrtap` reports the new tap).  The MCP
summary marks a clipped edge with `<` / `>`: this board read `eye <7+3/11 <7+4/12 taps`
before centring.  `gs_ddr3_center` (MET +0.017 / +0.023) on hardware: calibrates, `ddrtap=4`
(lane 1 = 11 - 7; lane 0 at 3), the masks as before, Arkanoid boots, 0 restarts.  The sample
point now sits 7 taps (550 ps) from the setup edge instead of 3.

## The census: the same RTL, build after build

`build/ddr3_census.sh` prints the clock legs of every build from its forensics text; the
hardware columns are read over the link after each load (`ddreye0/1`, `ddrtap`, DDR3_DBG1/3).
All builds from `gs_ddr3_center` on are the same RTL (only the build stamp differs).  The
placer put the controller differently every time (cells in X0Y3 / X0Y2: 4929/1412,
3807/2532, 4454/1885, 3588/2745) and WNS ranged +0.000 to +0.143; every DDR3 number - the clock legs, the
two eyes, the tap, the DQS index, the DBG1 word bit for bit - came out identical.  The
numbers that decide calibration no longer depend on where the placer puts the fabric.
**Read that as "within X0Y2 + X0Y3" - see the next section, which is where it stopped
being true.**

| build | WNS | CK-CMD | tDQSS | eye lane 0 / 1 | DQ tap | DQS index | restarts | calibrates |
|---|---|---|---|---|---|---|---|---|
| gs_ddr3_center | +0.017 | +0.052 | +0.016 | 000007ff / 00000fff | 4 (3) | 9 | 0 | yes, Arkanoid |
| gs_ddr3_var1 | +0.000 | +0.052 | +0.016 | 000007ff / 00000fff | 4 | 9 | 0 | yes, Arkanoid |
| gs_ddr3_var2 | +0.143 | +0.052 | +0.016 | 000007ff / 00000fff | 4 | 9 | 0 | yes, Arkanoid |
| gs_ddr3_var3 | +0.001 | +0.052 | +0.016 | 000007ff / 00000fff | 4 | 9 | 0 | yes, Arkanoid |

## Where the census's conclusion ran out: the island leaves its regions (2026-09-16)

A GS build that MET timing at +0.003, whose section A and B forensics were identical to
the four above - CK - CMD +0.052 ns, tDQSS +0.016 ns, the same OLOGIC sites for CK, CMD,
DQS and DQ - **never reached D=1 on the card**.  `K=00 M=0E X=FF`: it got as far as
CHECK_STARTING_DATA, the read-back of the alignment pattern, and self-restarted past the
counter's ceiling within a second of configuration.  Three loads, and once across a
uhubctl power cycle of the board's USB3 port, all the same.  Two builds known to
calibrate - `gs_cs16` (written back out of its kept routed checkpoint) and
`gs_ddr3_var3` - were loaded in between and came up `D=1 K=17 M=17 X=00`, so the board,
the DRAM and the cable are acquitted; a 2026-09-15 IIe build, never loaded before, failed
the same way.

**The difference is section D and nothing else.**  Every calibrating build keeps the whole
wrapper in X0Y2 + X0Y3, beside IO bank 15 and its 48 pins.  The failing build - 60.6 %
LUTs, **82.4 % slice occupancy** - had been pushed a region further out:

| build | calibrates | wrapper cells by clock region | PHY cells |
|---|---|---|---|
| gs_ddr3_var3 | yes | X0Y3 3664, X0Y2 2901, X0Y1 9 | X0Y2 146, X0Y3 51 |
| gs_cs16 | yes | X0Y3 4797, X0Y2 1781 | X0Y2 146, X0Y3 51 |
| 2026-09-16 00:30 GS | **no** | X0Y2 3354, X0Y3 2963, **X0Y1 261** | X0Y2 196, **X0Y1 1** |

Static timing cannot see the cost, because the 48 DQ/DQS pins carry no input-delay
constraint by design (the PHY centres its own read window on IDELAY taps) - DERISK.md's
blind spot exactly.  So the lesson of "Vivado's verdict is final only for what it was
asked" applies to the census too: it proved the DDR3 numbers are placement-independent
*among placements that keep the island beside its bank*, and said nothing about one that
does not.  `constr/pt_v2/ddr3_place.xdc` now pins the wrapper to
`CLOCKREGION_X0Y2:CLOCKREGION_X0Y3` - the range the calibrating builds chose for
themselves, constraining where it may go without packing it - so slice pressure cannot
relieve itself through the one part of the design whose failure static timing cannot
report.

## Where the island's conclusion ran out: a wrapper inside it fails (2026-09-17)

Two IIe builds of one RTL, hours apart, layout 2 of the telemetry map the only difference
(TELEMETRY.md), both MET, both with `ddr3_place.xdc` in force and sections A and B identical
(CK - CMD +0.052 ns, tDQSS +0.016 ns, CK from `OLOGIC_X0Y108`):

| build | WNS | calibrates | wrapper cells by clock region | PHY |
|---|---|---|---|---|
| `telem1` | +0.058 | yes | X0Y2 6291, X0Y1 232, X1Y2 8, X0Y3 16 | X0Y2 197 |
| `telem2` | +0.002 | **no**: `K=00 M=0E X=FF` | **X0Y2 6541, X0Y1 6** | X0Y2 197 |

The GS build of the same tree (`gs_telem2`, +0.011) calibrates.  So a wrapper that stays
wholly inside the island fails as one that left it did on the 16th, and the 16th's table
reads the other way round today: 232 cells outside calibrate, 6 inside do not.  Section D is
not the variable either.  What IS constant across every failure: `M=0E` = state 14,
`CHECK_STARTING_DATA` - the controller gets through the DQS pattern search, the read-side
calibration and write leveling (states 1-8), issues its first write and read (9-13), finds
the read-back wrong and restarts from 0, forever.  The read side works, or 14 is never
reached.  What the card writes is not landing as written: a write-path margin the static
numbers put at +0.016 ns of a +-0.625 ns window and cannot actually see (no ODELAY, no
write leveling on this board, DERISK.md's blind spot).  Build-to-build variation of the
real alignment - IR drop under a busier bit, the placement of the DQ/DQS OSERDES clocking
that no constraint pins - decides, and the census of the 14th could not have seen it: four
builds that happened to land inside the margin proved nothing about the margin.

## The 22-level stacks: one family, cut (2026-09-17)

The user's rule is that a named chain is cut whether or not it is critical, and "deep, not
critical" above was written before the write path turned out to be the variable.  The
routed `telem2` checkpoint's logic-level table (`build/results/logic_depth.rpt`,
`design_analysis.rpt`) says the DDR3's whole deep tail is ONE family: every path at 15-22
levels in the design - 8 per level, 62 in all - runs `index_wb_data_reg ->
{correct,wrong}_read_data_reg[n]` in the controller's BIST compare (`ddr3_controller.v`
"test calibration"), and its 14-level `reset_from_test` is the same cone.  One cycle held the
2:1 read-data mux (`o_wb_data_q[index_wb_data]`), the 128-bit equality against
`correct_data`, and a 32-bit increment: bit 0 of the counter at 15 levels, bit 31 at 22, worst
slack +1.865 ns.  Nothing else in the controller or PHY is above 11.

The cut (fork `ddr3_controller.v`, "The BIST compare in three stages"): stage 0 registers the
acked word, its expected value and the qualifier (`o_aux == 3 && o_wb_ack_uncalibrated &&
!final_calibration_done`); stage 1 compares and keeps the wrong word; stage 2 counts and
raises `reset_from_test`.  The restart lands two controller cycles later than before, which
is the same restart; `repeat_test` flushes the two valid bits; the address counter still
advances at the ack.  Behaviour-neutral, so it rides the rung-0 build rather than waiting
for a build of its own: the point of rung 0's build is a bit that fails and says why, and
whether it fails is a lottery draw either way.  Expected: the design's maximum depth falls
from 22 to the 14-level families outside the DDR3, and the controller's worst BIST path to
~9 levels.

## The plan for a fresh session (2026-09-17)

Branch `ddr3_write_level`, both repos.  Rungs, each with its own bench before its build and
its own bit TAGGED and PROVEN (or not) on the card; write the Status line as each lands.

0. **An instrument that works when nothing else does.**  A bit that does not calibrate
   answers no register - the ring is in the DDR3 - so DDR3_DBG1..3 (change 2) are unreadable
   exactly when they matter, and the UART line (`build/report.sh`, `rtl/card_link.sv`
   `rpt_*`) carried only K, M and X.  BUILT (uncommitted, 2026-09-17 late): the line grows
   ` D1=xxxxxxxx D2=xxxxxxxx D3=xxxxxxxx`, the three DBG words whole (PROTOCOL.md has the
   bits: the lane and its taps, restarts by cause, the state at the last restart, the DQS
   indices).  And the write-level feedback exists now: the no-ODELAY path of
   `START_WRITE_LEVEL`/`WAIT_FOR_FEEDBACK` no longer skips states 7-8 but pulses DQS with
   MR1's WL mode on (ROM steps 14-17, as the ODELAY path does) and records the DRAM's answer
   per lane - 1 = DQS rose while CK was high (late of the edge), 0 = low (early) - in
   `DDR3_DBG2[31:29]` = {done, lane 1, lane 0} (`DBG3[31]` = both samples settled, else a
   bounded 256-cycle sample timed out).  Steps nothing yet; that is rung 2.  With the BIST
   cut above, one build on the `telem2` tree (master minus nothing; rebuilding it may pass -
   `master_top_telem2.bit` from 2026-09-17 19:53, which fails, is kept).  Load it, read the
   UART; the plan below assumes it says the restart is CHECK_STARTING_DATA's data compare
   and the feedback bit differs from a calibrating build's - confirm or redirect.
   **READ 2026-09-17 21:10, `ddr3_instr1` (IIe, MET +0.000 / +0.035, 0/90604, max depth
   15 was 22, DDR3 deepest 12):** it calibrates - the lottery's draw - `D=1 K=17 M=17
   X=00 D1=B895D637 D2=C0000000 D3=80249249`: DONE, lane 1, DQS tap 14, DQ tap 5, RDY,
   highest state 23, no restart of any cause, and **the write-level feedback is lane 0 = 0
   (DQS early of the CK edge), lane 1 = 1 (late), both settled**.  The two lanes straddle
   the DRAM's own CK edge: tDQSS is about zero on the board as the DRAM sees it, as the
   report said on paper (and the Micron model with no skew, which answers 0/0 and warns
   tWLH "indeterminate CK capture").  Centred on the edge is the ideal for tDQSS, so on
   THIS build CK-versus-DQS is not what would fail; the reading that matters is the next
   build that does not calibrate, which the same line will now describe.  Redirect to hold
   in mind: the write side has a second window, DQ-versus-DQS at the DRAM (tDS/tDH, the
   forensics' "DQS - DQ at the pad +0.701 ns, ideal +0.625"), which no feedback measures;
   if a failing build reads 0/1 like this one, that is the suspect, and rung 2's stepping
   machinery on the DQ clock instead of CK is the way to walk it.  swhost started on the
   bit (fw stamp 20:47:25, eye `<4+7/12` both lanes), the Apple on.
1. **The failure in the bench.**  DONE 2026-09-17: `sim/ddr3_skew_sweep.sh` (the Micron
   bench with `SW_WRITE_SKEW_PS` = DQS and DQ late at the pins, in the fork's sim IO buffer
   models, or `SW_CK_SKEW_PS` = CK late = DQS early; `-DCAL_TRACE`; `ENFORCE=1` adds
   `SW_ENFORCE_TDQSS` to `testbench/ddr3.sv`: a tDQSS violation inverts the burst, because
   the model otherwise only prints the violation and stores the data anyway - it could not
   fail a write).  The sweep, skew in ps, the model's TDQSS window +-625:

   | skew | calibrates | WL feedback L0/L1 | tDQSS violations | restarts (from state) |
   |---|---|---|---|---|
   | 0 | yes | 0/0 (tWLH "indeterminate" x68) | 0 | 0 |
   | DQS late 200..600 | yes | 1/1 | 0 | 0 |
   | DQS late 800, enforced | **no** | 1/1 | 6656 | 52 from 13 |
   | CK late 200..400 (DQS early) | yes | 0/0 | 0 | 0 |
   | CK late 600 | yes, but the fills mismatch (deterministic, no model error) | 0/0 | 0 | 0 |
   | CK late 800, enforced | **no** | 0/0 | 7040 | 55 from 13 |

   The CK knob moves CK against everything the FPGA drives AND against the read data
   the DRAM returns off CK, so past ~400 ps it is measuring the read capture as much as
   tDQSS (the 600 point calibrates - the tap search absorbs it - and then reads wrong in
   normal operation); use it for the sign of the feedback, and the DQS knob for the
   window.  So the feedback bit is the side of the edge, monotone, flipping at zero; the window is
   +-625 ps as JEDEC says; and outside it the bench restarts for ever from the write/read
   alignment search (13/14) exactly as the card does.  That is the reproduction every later
   rung is measured in.  (The pre-enforcement sweep's late-side rows said "calibrates" at
   800 with 142k violations - the model storing what it complained about; superseded.)
2. **Write leveling on CK, without ODELAY.**  BUILT AND PROVEN IN THE BENCH
   2026-09-18, not yet on the card (`CK_PHASE_SHIFT`, default 0).  How it works
   and what it cost is below, under "Rung 2 as built".  The original sketch:  The Artix-7 HR banks have no ODELAY, so the
   fork's no-ODELAY branch leaves DQS-versus-CK at whatever the routing gives.  Move CK
   instead of DQS: in `rtl/clk_gen.v` give CK its own MMCM output whose phase the fabric
   can shift at run time (MMCME2's PSCLK/PSEN/PSINCDEC/PSDONE, VCO 1200 MHz = 14.9 ps a
   step, 168 steps a CK period); clock `CK_OSERDES` (change 1) from it; keep CMD, DQ and
   DQS on the unshifted clocks.  Drive the stepping from the controller's own write-level
   machine (`START_WRITE_LEVEL` / `WAIT_FOR_FEEDBACK`, fork `ddr3_controller.v`: the DRAM
   samples CK on DQS's rising edge and answers 0/1 on DQ): step until the answer flips,
   note the edge, step on until it flips back or the range ends, park CK midway.  A
   parameter (`CK_PHASE_SHIFT`, default 0 until proven) so the tree still builds the old
   way.  Bench it in rung 1's sweep: every skew the model can produce inside a period
   calibrates.  Then the mode register's tDQSS is the DRAM's own window and the board's
   alignment is closed on the board, not on a report.
3. **Two smaller pieces that ride the same builds.**  A bounded DQS tap walk (the wrap seen
   in the model: start index 8 then 7, "next odd", 32 taps round - bound it).  MIG's
   DIC/RTT_NOM mode-register values: does the eye of change 3 widen?  Read the eye
   (`DDR3_EYE0/1`, `ddreye0=` in `status`, `telemetry get ddreye0 ddreye1`) before and after.
4. **The census that loads every build, brought forward (2026-09-17 late).**  With the
   instrument in, a failing draw is worth more than any design work, so the census runs
   ahead of rung 2: `build/ddr3_census_run.sh DIRECTIVE...` builds the master tree with
   `build/build.tcl -place-directive` (a different placement of the same RTL on purpose),
   keeps each bit under its tag, loads it (swhost stopped), reads the UART and appends
   one line to `build/results/ddr3_census_hw.txt`.  Draws so far, all IIe, same RTL
   (fw df93df6): `ddr3_instr1` (the strategy's own placer, +0.000), `cen_extranetdelay_high`
   (+0.006), `cen_altspreadlogic_high` (+0.011), `cen_extratimingopt` (+0.012) - all four
   calibrate and all four read the same line, `D1=B895D637 D2=C0000000 D3=80249249`: lane 0 early, lane 1 late, DQS
   tap 14, DQ tap 5.  No failure yet; the sample grows a build at a time until one fails
   and says which side, or reads the same and points at DQ-versus-DQS.
5. **Prove it on the failing tree.**  Rung 2's fix built on the `telem2` tree (IIe) and on
   the GS: the IIe bit must calibrate (`D=1 K=17 M=17` on the UART, `tools/telem_check.sh`
   PASS, `accel_test.sh` and `gs_cp_test.sh` where they were).  Then the census done right:
   several builds of the fixed RTL - vary `place_design -directive` in `build/build.tcl`
   for the placements - all loaded, all calibrating, their eyes and CK phases side by side
   (`build/ddr3_census.sh` + a column for the parked phase).  A single failure is the
   finding; there is no "known".

What NOT to do again: conclude from N clean builds that a margin is closed.  The forensics
(`build/ddr3_forensics.sh`) say where things are; only the card says whether the write lands.
## Rung 2 as built: the card write-levels its own CK (2026-09-18)

**The mechanism.**  `rtl/clk_gen.v` becomes an `MMCME2_ADV` (the `_BASE` does not
bring the phase-shift pins out) with a fifth output, `clk_ddr3_ck`, carrying
`CLKOUT4_USE_FINE_PS`: the fabric walks that one clock's phase at run time
through PSEN/PSINCDEC/PSDONE, 1/56 of the VCO period a step - 14.88 ps at
1200 MHz, 168 steps in a 2500 ps CK period - and nothing else moves with it.
`ddr3_wrapper` hands it to the fork's PHY as `i_ddr3_clk_ck`, which clocks the CK
OSERDES (change 1) and nothing else; the commands, DQ and DQS stay on the clocks
they were always on.  The fork's controller drives the steps from its own
write-level machine and reports where it parked in `o_debug4` (DDR3_DBG4,
`0x8000_0184`, and ` D4=` on the UART line).

**Why it is safe to move a serdes clock at run time.**  An OSERDES needs its CLK
and CLKDIV in a fixed relationship because data crosses between them - but THIS
OSERDES's parallel inputs are the constants 0,1,0,1.  Nothing crosses; the CK
pin's pattern is the same whatever the phase.  Static timing does not see the
shift either (Vivado times `clk_ddr3_ck` at its CLKOUT4_PHASE), which is exactly
why nothing else may hang off that clock, and nothing does.

**The algorithm, and the trap in it.**  At ROM step 17 the DRAM is in MR1's
write-level mode: on each DQS rising edge it samples CK and drives the level on
DQ.  The machine sweeps CK half a period - a quarter period below the phase it
came in on, then up - sampling every lane at every step, and parks at the mean of
the lanes' crossings.  A pair of lanes on one CK cannot both be centred (the DRAM
centres per lane with ODELAY, which this board has none of); the mean is the best
one CK can do, and it is what the hardware already shows the board wanting - lane
0 early, lane 1 late, straddling.  **The trap:** one sweep passes CK's rising edge
AND its falling edge, and the falling edge is the worst place there is.  The
first version recorded "any change" and parked 1250 ps out on the bench's 800 ps
case.  The feedback is 1 while a lane's DQS sits in CK's high half, and the sweep
walks CK later, which walks DQS earlier through CK: so the rising edge is the
1 -> 0 transition and the falling edge the 0 -> 1.  Recording only 1 -> 0 fixes
it.  A lane that never crosses inside the bound is further out than half a sweep
can reach; the machine then parks at the bound on the side the feedback AT THE
ENTRY PHASE points to (the far end's answer points the wrong way exactly when
this fallback is needed), and the next calibration attempt sweeps again from
there and finds the crossing - convergence over restarts rather than a hunt.

**Bounded on purpose.**  A quarter period either way: the tDQSS window, the
widest excursion in which the feedback has one transition per lane, and a bound
on what the move costs the command bus, which is launched from the unshifted
clock (CK later by X is X less command setup; the forensics have 1.302 ns of it
at the slow corner).

**The bench (rung 1's sweep, `PHASE=1`).**  Every point calibrates, and the
model's tDQSS violations go to zero:

| skew | CK off | CK on: parked (entry 42 of 84) | tDQSS violations on |
|---|---|---|---|
| none | calibrates | 43 | 0 |
| DQS late 400 ps | calibrates | 69 (+27 steps = +402 ps) | 0 |
| DQS late 800 ps | **never calibrates** | 54, after one restart: the first attempt parks at the bound, the second finds the crossing | 0 |
| CK late 400 ps | calibrates | 16 (-26 steps = -387 ps) | 0 |
| CK late 800 ps | **never calibrates** | 0 (the bound, -625 ps: 800 is further out than the bound reaches, and -175 ps is inside the window) | 0 |

**ON THE CARD (2026-09-18, `ckphase1`, IIe, MET +0.017 / +0.044, 0/90936, max
depth 15).**  It calibrates first time - `D=1 K=17 M=17 X=00`, no restart of any
cause - and the machine boots, runs and reboots on it.  And D4 is the first
measurement this project has of where its CK actually sits:

```
D4=572C2528   parked at step 40, lane 0 crosses at 37, lane 1 at 44, both found
```

The sweep came in at step 42 (the phase every build to date has had) and a step
is 14.88 ps, so, against the phase the routing gave:

| | step | from the entry phase |
|---|---|---|
| byte lane 0's DQS crosses CK | 37 | **-74 ps** (its DQS is early of CK) |
| byte lane 1's DQS crosses CK | 44 | **+30 ps** (late) |
| CK parked at their mean | 40 | -30 ps |

The two lanes' DQS edges are **104 ps apart** and they straddle CK, which is
what DDR3_DBG2's feedback said in words on every build tonight (lane 0 early,
lane 1 late) and what the routed report's tDQSS of +16 ps said on paper.  Two
instruments and a static report agree.  Parking at the mean moves the worse lane
from 74 ps off CK to 60.

**So this board never needed much of a correction, and that is the point.**  The
lottery is not about this board's typical 20 ps; it is about the build whose
routing lands 300 or 700 ps out, which is the build that never calibrates - and
the bench says those are exactly the ones this fixes.  What the hardware adds is
that the mechanism runs, converges and costs nothing when there is nothing to
correct.

**The acceleration test, and what it does NOT say.**  `tools/accel_test.sh` on
the `ckphase1` bit fails two checks - and so does the control.  Runs tonight:

| bit | tree | beam slip in mode all 4 | "the program did not run after leaving acceleration" |
|---|---|---|---|
| `telem1` | master before this session (fw 6bb1bfd) | no | **FAIL** |
| `ddr3_instr1` run 1 | fw df93df6, CK phase off | no | **FAIL** |
| `ddr3_instr1` run 2 | same | **FAIL** 20 -> 201 | **FAIL** |
| `ckphase1` run 1 | fw 7389139, CK phase ON | **FAIL** 19 -> 163 | **FAIL** |
| `ckphase1` run 2 | same | **FAIL** 24 -> 169 | **FAIL** |

The ways-out failure is on the bitstream this session began with, so it predates
every commit of it: an existing red check on master, not rung 2's (the screen
says `Unable to load BASIC` / `ram too large` after `all -> reads -> off`).  The
beam slip is intermittent and happens with the phase shift and without it.
Neither is attributable to CK stepping; both are findings of their own, and the
ways-out one wants chasing before the next acceleration claim.

## A red bench, found on the way, and what it was (2026-09-17)

`sim/run_mem_ddr3_tb.sh` was failing two of its checks, and the two had different causes.

**The deadline check was wrong.**  It required every fill-plus-flush transaction inside
its 92-clock bus cycle, an assumption from the days of the refresh gate; with refresh on
the controller's own timer (fw 239cf02, and REFRESH_GATE had been 0 since 09-12) a refresh
lands inside about 6 % of transactions and the controller holds the bus for its tRFC.  The
user's rule (2026-09-17): a test that is not tolerant of refresh happening on its own is
WRONG and gets fixed, and if the system is not designed around unscheduled refresh that
gets fixed too.  The bench now keeps the two populations apart and judges each: a
transaction no refresh touched must fit the cycle (critical line 60, whole 92); one a
refresh landed inside gets the controller's refresh hold on top (`REF_COST` 42 clocks at
the model's 8 Gb tRFC; ~23 on the real part).  Measured, 835 transactions:

| | critical line worst | whole transaction worst |
|---|---|---|
| no refresh inside (783) | 45 clocks | 83 |
| a refresh inside (52) | 56 | 99 (allowed 134) |

So the system IS designed around unscheduled refresh: the served byte is never later than
56 clocks against a ~91-clock latch, and a refresh-hit transaction runs ~16 clocks past
the cycle on this model (~0 on the real part's shorter tRFC), which the accelerated
regime already absorbs as a stall.  No design change.

**The fill compare was right, and the failures were not the DDR3's.**  Chased to the
controller's own Wishbone port with a shadow memory and then to the Micron model's own
write/read trace: a location written with one word read back another that had been
written to a DIFFERENT address - by another simulation.  With `MAX_MEM` the model keeps
its DRAM in FILES named after the instance (`/tmp/mem_ddr3_tb.ddr3_dev.open_bank_file.N`
unless `+model_data` says otherwise), so two runs of the bench at once share one memory.
Every red run of the night had a sibling running (the sweep's parallel points, A/B
pairs, the "baseline" beside two other runs); the one run that happened to run alone had
zero mismatches, and so did the logs of August.  Not refresh, not the controller, not the
bench's compare: the harness.  Fixed in `run_mem_ddr3_tb.sh`, `run_tx_ring_ddr3_tb.sh`,
`run_latency_tb.sh` and `ddr3_skew_sweep.sh`: every run gets its own model directory.
Proof: two copies of the bench at once, both PASS on every check.  The rung-1 sweep table
above was re-run on the fixed script and stands (the enforced 800 ps points restart for
ever from state 13; the calibration results never depended on memory contents beyond
address 0, and they did not change).

## Instruments

- `build/ddr3_forensics.sh TAG [WORKDIR]` / `build/ddr3_forensics.tcl`: sections A (the CK
  driver cell), B (pad arrival of every DDR3 output at both corners, launched by its own
  OSERDES; the CK/CMD/DQS/DQ skews), C (clock resources), D (controller/PHY placement and
  the slack of every path touching `u_ddr3`), E (LUT pairs across the `u_ddr3` boundary).
  `build/build.tcl` runs it on every build (`build/results/ddr3_forensics.txt`), keeps the
  routed checkpoint as `build/results/<top>_routed.dcp`, and `build/run_build.sh` keeps both
  under the tag; `build/wns.sh` prints the two skew lines.
- `CAL_TRACE` (`ifdef` in the fork's `ddr3_controller.v`): every `state_calibrate`
  transition with lane, taps, start/target index, every self-reset, and the write-level
  feedback per lane, for the iverilog benches.
- The UART line (`build/report.sh`): ` K=xx M=xx X=xx D1=xxxxxxxx D2=xxxxxxxx D3=xxxxxxxx`,
  the three DBG words whole - the only instrument on a bit whose DDR3 never calibrates.
- `sim/ddr3_skew_sweep.sh [ps...]`, `CK=1`, `ENFORCE=1`, `SECS=`: rung 1's sweep, one line a
  point.

## Next (the plan, in order)

1. DONE: `gs_ddr3_ckserdes` calibrates on hardware and runs Arkanoid; forensics in the text.
2. DONE: `gs_ddr3_dbg` (MET +0.002 / +0.046) on hardware: `ddrk=17 ddrmax=17 ddrrst=0
   ddrtest=0 ddrrdy=1`; DDR3_DBG1 = `b89df637` (DONE, lane 1, ROM step 22, DQS tap 15, DQ
   tap 7, RDY, no alignment hypothesis, max 23), DBG2 = 0, DBG3 = `00249249` (DQS index 9
   throughout, data start 0).  Arkanoid runs.  The next bit that never calibrates will say
   which state it stuck in or how often it restarted.
3. DONE: `gs_ddr3_eye` (MET +0.006 / +0.057) on hardware, the first eye of this board:
   **lane 0 passes DQ taps 0..10, lane 1 0..11, calibrated DQ tap 7** (`ddreye0=000007ff
   ddreye1=00000fff ddrtap=7`).  The sample point sits 3 taps = 234 ps from the late (setup)
   edge and the early side runs off the bottom of the range, i.e. the fixed "DQS + 8 taps"
   rule lands ~4-5 taps late of the eye's centre on this board (DQ-vs-DQS input path skew:
   IOBUFDS vs IOBUF, the DQS IDELAY's CLOCK pattern vs the DQ's DATA, tDQSQ).  A third of the
   setup margin a centred sample would have - the margin a busier bit's noise eats.  Hence
   change 4.
4. DONE: `gs_ddr3_center` - the DQ sample point centred (7 taps from the setup edge, was 3).
5. DONE: the census - four builds of one RTL, four placements, one set of DDR3 numbers.
6. SUPERSEDED by "The plan for a fresh session" above: the census's conclusion did not hold
   (the island section, then the wrapper-inside-it section).  The depth cut is done (the
   BIST compare, the only deep family); MIG's DIC/RTT_NOM and the bounded tap walk are rung
   3; write leveling on CK is rung 2; the census that loads every build is rung 4.
