# UberDDR3 on the card: placement, logic depth, and the calibration that sometimes never comes

Status: 2026-09-16, branch `gs_control_panel`, fw c041e30 / host dce72d2 + the pblock below.
The census's "placement no longer matters" ran out on 2026-09-16: a MET build whose DDR3
forensics were identical to the calibrating ones never reached D=1, because slice pressure
had pushed 261 wrapper cells out of X0Y2/X0Y3 ("Where the census's conclusion ran out").
`constr/pt_v2/ddr3_place.xdc` pins the island to those two regions.
Forensics, the ODELAY answer, the CK_OSERDES fix, the instrumentation, the eye sweep and the
centred DQ tap are DONE and on hardware (bits `gs_ddr3_ckserdes`, `gs_ddr3_dbg`, `gs_ddr3_eye`,
`gs_ddr3_center`, all MET); the fork is at d728e6a (four commits, unpushed).  UberDDR3 now comes from the fork
`jtflanagan/UberDDR3`, branch `strudelworks-research` (upstream `4a51b96` is the merge base).
First change on it: `CK_OSERDES` (the DDR3 clock pin through an OSERDES): build
`gs_ddr3_ckserdes` MET +0.011 / WHS +0.054, 0/95362; on the routed design CK - CMD went from
+1.65 ns to +0.05 ns (command setup 0.40 -> 1.30 ns, tDQSS +0.92 -> +0.02 ns); ON HARDWARE the
DDR3 calibrates (`ddr=1`, image ready, fw 2026-09-14 09:58:30) and Arkanoid boots from slot 7
at 62x unlimited.  Not yet a proof of reliability - one bit, one card, one day; the variance
census across builds and the instrumentation are what make it one.  `build/ddr3_forensics.sh` + `build/results/ddr3_forensics_*.txt`
are the instruments; every build now keeps its routed checkpoint (`build/results/*_routed.dcp`).

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

## Instruments

- `build/ddr3_forensics.sh TAG [WORKDIR]` / `build/ddr3_forensics.tcl`: sections A (the CK
  driver cell), B (pad arrival of every DDR3 output at both corners, launched by its own
  OSERDES; the CK/CMD/DQS/DQ skews), C (clock resources), D (controller/PHY placement and
  the slack of every path touching `u_ddr3`), E (LUT pairs across the `u_ddr3` boundary).
  `build/build.tcl` runs it on every build (`build/results/ddr3_forensics.txt`), keeps the
  routed checkpoint as `build/results/<top>_routed.dcp`, and `build/run_build.sh` keeps both
  under the tag; `build/wns.sh` prints the two skew lines.
- `CAL_TRACE` (`ifdef` in the fork's `ddr3_controller.v`): every `state_calibrate`
  transition with lane, taps, start/target index, and every self-reset, for the iverilog
  benches.

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
6. Then, ranked by the numbers: MIG's DIC/RTT_NOM (does the eye widen?), a bounded tap walk
   (the wrap seen in the model), locality constraints, the depth cuts, and write leveling
   without ODELAY (CK on its own MMCM output with dynamic fine phase shift stepping under the
   existing write-level feedback machine).  And the variance census: several builds of one
   RTL, their masks and taps side by side.
