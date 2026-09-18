# Telemetry: the card's registers, once a second, from the Apple's reset

Status: 2026-09-17 evening, fw 6bb1bfd / host 523ce7c, merged to master. LAYOUT 2 ON HARDWARE (GS `gs_telem2` MET wns +0.011 whs +0.063, 0/105643, max depth 17, block RAM 112 tiles): `tools/telem_check.sh` PASS - 30 counters probed live all inside their two samples, the census sums to ACCEL_FAST, `h_clocks` gains 100000000.0 a second, the wide totals sensible (44.1 kHz of audio samples), the host's own DBG pair right beside the sweep. Layout 1 proven the same afternoon on `gs_telem1` and the IIe `telem1` (+0.058). IIe `telem2` MET wns +0.002 whs +0.057 0/89939 BUT ITS DDR3 NEVER CALIBRATES on the card (UART `K=00 M=0E`, the 2026-09-16 signature; this time the wrapper sits 6541/6555 INSIDE X0Y2 where the calibrating `telem1` had 232 cells in X0Y1 and 16 in X0Y3 - the island pin is not the whole story): not a telemetry fault (the same tree calibrates as `gs_telem2`), a placement lottery the user decides about. The IIe runs `telem1` (layout 1) meanwhile. `telem_tb` 24 checks, `suite quick` 34/34; host `telemetry_test` 44, host tests 46/46, swmcp 42/42, `check_telem_map.py` 171 entries agree. Scripts converted ("The scripts" below). The user's design (2026-09-17): the card delivers its memory-mapped registers to the host as one message a second, the first sample of a run taken at the Apple's reset, so every debugging session has a baseline and a regular, aligned series - and no rollover is ever ambiguous.

## Why

- **The host already polls everything, slowly and out of step.**  `status`, `accel status` and the
  HUD issue no register reads of their own: they read values the host's poll rotation cached
  (`Pipeline::drive_mem`, 49 registers at one per 100 ms; `drive_ring`, 6 at one per 250 ms),
  because the card answers one register request at a time.  A lap is 2.2 s idle and about 8.6 s
  while accelerating, and the values in one report are seconds apart in age.  That skew has been
  a finding in its own right ("PLAIN vs census was skew, not counting", docs/GS.md 2026-09-11),
  the scripts carry sleeps to cover it (`accel_test.sh`: `sleep 3  # the poll rotation`), and
  every rate is two `status` samples and a subtraction, with the wrap done by hand
  (`kbd_test.sh` mod 256; docs/CXXX.md "deltas mod 2^32").
- **A sample taken on the card is one instant.**  The census beside the total it sums to, the
  ratio's numerator beside its denominator, in one message with a sequence number and a stamp.
- **A baseline at the reset is what a run is measured from.**  Most counters are not cleared by
  RES'; the sample taken as RES' lets go is the zero every later sample is read against.

## What can wrap inside a second

The clock is 100 MHz, so a 32-bit counter that ticks every clock wraps in 42.9 s
(`ACCEL_CORE_CYC` can tick twice a clock: 21 s).  Every 32-bit counter is safe at one sample a
second, across twenty lost samples.  The narrow fields are not: `U2_SLOT`'s cmds and rx chunks
(8 bits), `PRINTER_SLOT`'s writes (8), `HD_SLOT`'s execs (8), `PANEL_STAT` (4 + 4), and
`AUDIO_STAT`'s samples (16 bits at 44.1 kHz: 1.49 s, ambiguous after one lost sample).  Rung 5
gives those a 32-bit total in the telemetry message (not in the register map).

## The design

### Rung 0 - the register cut (`rtl/wb_regfile.sv`)

Every read-only readback is read through a shadow flop; `snap_hold` stops all the shadows at one
edge.  Two purposes, the user's (2026-09-17): the sources - the fronts, the page cache, the
sequencer, the drives - end at a bare D pin instead of at the ninety-way read mux, which has set
the design's clock twice; and a master that holds the bus and sweeps the map under `snap_hold`
reads one instant of the whole card, however long the sweep takes.

- What the host WROTE is not shadowed: the RW fields are the file's own flops, there is nothing
  to cut, and a write's reply shows them exactly as before.  (A write's reply has always carried
  the word as it stood at the write's own edge - `KBD_INJECT` documents it as "the state BEFORE
  it" - and still does.)
- A host read is one clock older.  `DBG_VAL` is now two flops from the top's mux
  (`dbg_val_q`, then the shadow); a host `DBG_SEL` write and the `DBG_VAL` read behind it are
  messages apart, so nothing sees it.
- 145 shadows, about 2 400 flops, no reset (data, not control).  `snap_hold` was tied low in
  `card_link.sv` for the rung-0 build; the sender drives it from rung 1.
- The census (`fast_census`) is shadowed with the rest, so a held sample has the seven buckets
  and `ACCEL_FAST` from one edge; the census's own pipeline still lets the sum trail the total by
  up to three ops in flight.

### Rung 1 - the sender (all inside `rtl/card_link.sv`)

- `rtl/reg_front.sv`: a registered 2:1 Wishbone front between {`reg_bridge`, the telemetry
  sender} and the register file.  Grant per CYC, the bridge wins a tie, the telemetry port has
  no write enable.  A bridge read goes from 2 clocks to 3; the bridge has no ack timeout.
- `rtl/telem_map.vh`: the sweep's list of register offsets, one per line: 85 registers in
  layout 1.  The host mirrors it (`src/telemetry_map.hpp`) and `tools/check_telem_map.py` there
  compares the two.  Left out: FB_PEEK, NSC_TIME/NSC_DATE (the host's own data), DBG_SEL/DBG_VAL
  (layout 2), TELEM_CTRL.  The DDR3's three static words ARE in it - three words a second buy
  the host the whole of its ring rotation back.
- `rtl/telem_tx.sv`: a 1 Hz divider restarted by RES' release (debounced and masked with
  `start_hold`'s parameters - the line bounces); `epoch` (8 bits) bumps and `seq` returns to 0
  at each release, and that sample is the run's baseline.  A sample: take the front, raise
  `snap_hold`, walk the map (about 85 reads, 2.5 us) into a `sync_fifo`, drop the hold, then
  offer the message through `audio_tx`'s reader FSM - WITHOUT its reset on `!enable` (a reader
  reset mid-message leaves `msg_master` holding CYC with no words, and that wedges `msg_arb`).
  A tick that finds the previous message still draining is skipped and counted (`drops`); `seq`
  still advances, so the host sees the gap.
- **THE SWEEP IS BOUNDED (2026-09-18).**  `snap_hold` stops every read-only shadow on the
  card, so a sweep that never gets an ack does not merely lose a sample - it would leave the
  whole read-only half of the register map frozen at whatever it held, and a swhost restart
  would not clear it because only the card's own reset does.  **This has NOT been seen on
  hardware.**  It was reported here on 2026-09-18 and the report was wrong: the "every
  read-only register reads zero" came from reading truncated addresses (`0x140` for
  `0x8000_0140`), and the card was answering correctly the whole time - `0x8000_0140` read
  `b895b637`, matching its own UART line.  What was really wrong that day was host-side and is
  fixed there (a stale readback deciding the bitstream had no telemetry).  The bound below
  stands anyway, because an unbounded hold on the card's own state is a wedge waiting to
  happen and the user's standing rule is that the card never wedges:
  `telem_tx` watches itself: `WDOG_CLKS` (10 ms at 100 MHz, against a sweep of ~2.5 us) after
  a sweep leaves idle it gives up - **the hold drops first**, because that is what unfreezes
  the card, then the door once the outstanding read has acked or `WDOG_GRACE` (100 us) has
  passed.  The words already in the FIFO are drained, the sample is counted in `drops` and the
  host sees it in the next header, and an abandoned baseline is re-owed and marked late.  A
  front that never acks is already broken; keeping the door shut behind it is worse than
  letting it go.  `sim/telem_tb.sv` runs a second sender against a door that is granted at once
  and an ack that never comes: five checks, and with the watchdog's trigger tied off three of
  them fail.
- NOTHING IS CUT SHORT, a release included.  The plan had a release abort a sweep in progress;
  built, it does not: the front may only be let go with no read outstanding (an ack that came
  home after the door changed hands would go to the bridge), the sweep is 260 clocks, and the
  sample it finishes says truthfully which epoch it was taken in.  The baseline follows it at
  once with `flags[1]` (late) set.  `enable` likewise only decides whether the NEXT sweep starts.
- The release is RES' high for DEBOUNCE clocks after a believed low stretch, and no new low
  stretch is believed for 2^MASK_LOG2 clocks after one - `start_hold`'s numbers.  RES' is tapped
  from the register file's own `res_prev` flop, not from the synchroniser's net (which the
  core's reset hangs from).
- The message, type `0x39`: header `{free = {drops[7:0], layout[7:0]}, type, len}`; payload
  word 0 `{epoch[7:0], flags[7:0], 16'd0}`, word 1 `seq` (seconds since the release), word 2 a
  microsecond stamp, then the values in map order.
- `TELEM_CTRL`, `0x8000_0168`: `[0]` enable, RW, cleared by the card's reset (silent until
  asked, docs/PROTOCOL.md); RO `[15:8]` epoch, `[23:16]` drops, `[31:24]` sent.
- `msg_arb`: thirteen ports; telemetry is port 11 (rate-bounded by the wall clock, like audio),
  the capture moves to 12.

### Rung 5 - layout 2 (built 2026-09-17)

- THE DEBUG SPACE IS IN THE SWEEP: 80 items - the top's five snapshot words and the twelve-bucket
  clock histogram (16), the instruction front (16), the data front (16), the page cache (14), the
  bank census (10), the data front's bank table (8) - between the register file's two halves.
  A map entry is `{sel, offset}`; an entry at DBG_VAL's offset is read with `sel` on the top's
  muxes: `rtl/card_link.sv` routes the register file's DBG_SEL (the host's) through
  `telem_tx`, whose registered output is the sender's own while it holds the door and is on a
  debug item, the host's otherwise - never the sender's before the door is its own, or a bridge
  read in flight would be torn.  Three clocks of settling an item (the selector's flop, the
  top's registered mux, DBG_VAL's shadow), so ~6 clocks an item and ~750 a sweep.  The host's
  own DBG_SEL/DBG_VAL pair sees none of it: the bridge is stalled for the sweep, and the
  accelerator's 22 registers follow the last item.
- DBG_VAL's SHADOW FOLLOWS THROUGH THE HOLD - the sweep reads the debug space through it - and
  what the hold freezes instead is behind the top's mux: its five snapshot words hold, and the
  histogram has copies of its own (`h_cnt_s`, `rtl/master_top.sv`) that hold, so a sample's
  twelve buckets are of one instant and OTHER is CLOCKS less the rest, exactly.  The other
  groups' muxes read live inside their modules: microseconds of skew, across counters that
  nobody sums.
- THE WIDE COUNTERS: six 32-bit registers, `0x8000_016C`-`0x8000_0180`, kept in the register
  file from the narrow counts that can wrap inside a second (U2_SLOT's cmds and rx, PRINTER_SLOT's
  writes, HD_SLOT's execs, PANEL_STAT's dmas, AUDIO_STAT's samples), each following its source
  a clock behind by `(now - before) mod 2^n`.  Registers rather than telemetry-private words:
  behind the cut a read-mux arm costs nothing on a live cone, and `reg` can read them too.
- `telem_tb`: 24 checks - every debug item equals its selector's word against a two-stage model
  of the top's mux, and a host with DBG_SEL = X reads f(X) on every DBG_VAL read across sweeps.

### The host and the tooling

`../strudelworks-host`: the message routed (`link_parser.cpp`'s case list), a `Telemetry` class
(baseline per epoch, 64-bit totals extended by each field's width, an hour's ring, a log file),
the cached values `status` reads fed from the sample instead of the poll rotation (which stays
as the fallback for a bitstream older than this), a `telemetry` control verb, an MCP tool, and
`tools/common.sh` with `telem_get / telem_delta / telem_wait / telem_mark / telem_since` in
place of two-samples-and-subtract.

## Rungs

| rung | what | state |
|---|---|---|
| 0 | the register cut | built (GS MET +0.001); hardware next |
| 1 | the sender, `telem_tb` | simulation green; GS bit `gs_telem1` MET +0.004; hardware next |
| 2 | the host receives (polls still run) | built, unit-tested; hardware next |
| 3 | hardware bring-up, both machines | GS proven (`telem_check.sh` PASS, the reset epoch, the log); IIe bit MET and running the scripts |
| 4 | the host switches over; the rotation becomes the fallback | built, unit-tested against the mock (`accel_test`: the rotation stands down, the cached counters are the sample's); hardware next |
| 5 | layout 2: the debug space, wide counters | built; on the GS on hardware; the IIe bit MET but does not calibrate its DDR3 (see Status) |
| 6 | tooling: common.sh, swctl, swmcp, the scripts | done; gs_cp_test / accel_test / mem_test converted and run ("The scripts") |
| 7 | the other docs, CLAUDE.md, the rules | done (PROTOCOL, TX_RING, CXXX, ACCELERATION, GS, IWM35, both CLAUDE.md, both READMEs) |

## The bench (`sim/telem_tb.sv`, `sim/run_telem_vl.sh`, in `suite quick`)

The real `ft601_msg_rx`, `reg_bridge`, `reg_front`, `wb_regfile`, `telem_tx`, three
`msg_master`s and `msg_arb`; a bouncing RES' line; a second shortened to 20 000 clocks.  It
holds the sender to: silent until asked; the framing, and every word of a sample equal to a
bridge read of the same offset (which is what catches a slip in the map); ONE INSTANT - three
registers driven from one free-running counter read the same number in every sample, and the
check fails when the hold is tied low; a release through a bounce is one epoch, its sample seq
0 within a few hundred clocks, the samples after it a second apart FROM it; the bridge right
across sweeps and a write that arrived during one landing once; nothing landing inside
anything and nothing torn (`tx_ring`'s own expression) with a capture running; a stalled link
skipping whole samples with `drops` equal to the gap in `seq`; a release that finds a message
waiting; `enable` dropped mid-message.

A bench lesson worth keeping: every stimulus changes on the FALLING edge, and the bench FIFO's
face is registered.  Changed on the rising edge the stimulus raced the flops sampling it, and
a continuous read of an array written from a task read stale under Verilator 5.020 - the
bench's first message arrived as zeros with the RTL blameless.

## The scripts (rung 6, 2026-09-17)

Converted and run on hardware: `gs_cp_test.sh` (`expect_target` waits on the card's own ACCEL_CTRL
a sample at a time - 0.1 s where the status poll lagged a second; `reset_probe` reads BUTTONS from a
sample instead of `reg 80000020`; rows `panel` and `columns` run), `accel_test.sh` (a mark before
the loop, the totals since it after; no rotation sleeps), `mem_test.sh` (the 5 s idle window from
history).  `kbd_test.sh` left alone: its card counters already arrive through `status`, and a
step's deltas never near a wrap.

What the conversions turned up, none of it theirs:
- `accel_test.sh`'s ratio, turbo + fast + bus over the accelerated cycles, left out the data
  front's ops (dline, since 2026-09-02): 2.69 at a target of 4 while the machine ran at exactly
  4.0x by the clock, and the old two-status subtraction gave the identical 2.69 from the same
  samples.  It uses the PLAIN pair now: 4.00 at target 4, 5.24 in `reads`, 71.9 unlimited.
- `accel_test.sh`'s "ways out" (`all -> reads -> off`, then RUN) puts the core on the machine's
  RAM after a boot made in mode `all` - RAM that never received BASIC.SYSTEM - and the screen
  reads "Unable to load BASIC".  The step is from 2026-09-01, older than the boot-under-
  acceleration section in front of it and than the all-or-nothing serve.  NOT bisected against a
  pre-telemetry IIe bit (none kept); the register cut touches only how the host reads registers.
  The user's call.
- `mem_test.sh`'s rungs `ram` and `ram,lc` are refused by the config (`mem` is off/on/keep since
  the all-or-nothing serve, 2026-08-31): swhost never starts.  Its `off` rung reads a cumulative
  `served` and calls it "served with nothing enabled".  Rung `all` passes whole.

## The IIe `telem2` bit's DDR3 (2026-09-17 evening)

`build/report.sh` on the loaded bit: `K=00 M=0E` - calibration never started, every register
unanswered, the link reset itself.  `build/results/ddr3_forensics_telem2.txt` against `telem1`'s
(the bit that calibrates): section D puts `telem2`'s wrapper 6541 of 6555 cells in X0Y2 (6 in
X0Y1) where `telem1` had 6291 / 232 / 8 (X1Y2) / 16 (X0Y3).  So a wrapper wholly inside the
pinned island can fail as one that leaves it did on 2026-09-16 (UBERDDR3.md).  Both IIe builds
are the same RTL but for layout 2; the GS build of the same tree calibrates.  Deep tail on the
IIe (named): `u_regfile/cpu_src_active -> u_filter/*`, 166 paths at 14 levels, +0.75 ns - the
capture's sparse filter reading the CPU_SOURCE latch live, not the cut; UberDDR3's read-compare
at 22.

## The deep tail in `gs_telem1` (named, per the rule)

`build/wns.sh`: max depth 22 (was 20 in `gs_regcut`), paths at >= 14 levels 411 (was 172).  None
of it is telemetry's: the sender's one path at >= 10 levels is the message bus's stall chain
into its FIFO (`u_ring/u_stage/count -> u_telem/u_fifo/mem_count`, 10 levels, +3.29 ns), and
nothing ends at the register file's read mux at >= 10.  What crossed the line
(`build/results/logic_depth_gs_telem1.rpt`):

- `u_card/u_merge/out_data -> u_card/u_filter/{out_data, hold_data, cnt, hold_free,
  out_mark_free}`: about 180 paths at exactly 14 levels, worst slack +1.46 ns - the capture's
  merge into the sparse filter.  A chain with a name now; a cut candidate.
- UberDDR3's `index_wb_data -> correct_read_data / wrong_read_data`: 64 paths, 22 levels where
  the baseline lists 14, +2.47 ns.  Third-party, and its slack is its own business.

The binding paths are where they were: `u_seq/st -> g_65816.u_cpu/urom` (+0.101) and the
instruction front.

## Owed at the next build

- The sweep's 85-entry ROM (`telem_off`) was inferred as a block RAM (`idx_reg_rep`, 256 x 9) in
  `gs_telem1`.  It behaves, but block RAM is this design's scarce resource (83 %) and LUTs are
  not (61 %): `t_off` now carries `(* rom_style = "distributed" *)` (after `gs_telem1`; the IIe
  build `telem1` is the first with it).

## Findings on the way (not this work's to fix)

- THE PI'S SSHD LOCKED THIS MACHINE OUT MID-SCRIPT (found running the first hardware checks,
  2026-09-17, fixed in the host's `tools/pi5.env`): the morning's "the Pi by name" pick probed
  port 22 with a bare TCP connect on EVERY `tools/pi.sh` call, and OpenSSH 10 on the Pi
  (PerSourcePenalties) counts each unauthenticated connection against the source - a script's
  `ctl` loop built the penalty up in a minute (`journalctl -u ssh`: "drop connection ...
  penalty: connections without attempting authentication").  `export PI_HOST` after the pick:
  one probe a script.  `tools/common.sh` also keeps one ssh control master for a script's run.
- A REFUSED START CRASHED THE HOST (found on hardware 2026-09-17, fixed in the host's
  `src/apple_app.cpp`): `AppleApp` destroyed the USB transport under the pipeline's reader
  threads, which since "every start is a reset" exist before the hold is checked.  The user's
  own pre-telemetry binary did the same.  `pipe_.stop()` first; verified: exit 1, the refusal
  printed, the link stopped cleanly.
- THE HOST'S REGISTER-REPLY HANDLER IS NOT A PURE CACHE (`pipeline.cpp` `on_reg_value`): it
  acknowledges key presses, runs FB_PEEK's echo, and bumps the generation counters `read_fresh`
  and the start checklist wait on.  Rung 4 must feed it telemetry words with a flag that
  stores values and does nothing else, or a sample taken before a write passes for a fresh
  reply to the read after it.
- The host's `tools/swmcp/parse.py` pattern for `accel status` had not matched since PLAIN and
  `maps` joined the report: every field fell through to `raw`.  Fixed here, with a test.
- `rtl/audio_tx.sv:145` resets its reader on `!enable`.  Mid-message that leaves `msg_master`
  holding CYC with no more words coming, which would wedge `msg_arb` for every port.  swhost's
  stop clears `AUDIO_CTRL`.  Worth a bench case of its own.
