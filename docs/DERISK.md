# strudelworks — what this is, and what has to be proven

## The bet

appletini-mega is a from-scratch carrier for a Sipeed Tang Mega 60K SOM: new FPGA
family, new toolchain, new power design, new DDR3 routing, new USB3 bridge
(CH569), new CPU-socket interface. Every one of those is unproven at once.

strudelworks keeps one thing from that list and throws the rest away. It reuses
the **Alchitry Au + Alchitry Ft+ stack**, which is already known to work as an
Apple II peripheral (AppleTini v5), and changes exactly two things:

1. the carrier board gets a **6502/65816 CPU-socket connector** instead of only
   the slot edge — the one genuinely new idea from appletini-mega;
2. the DDR3 controller becomes **UberDDR3** instead of the Xilinx MIG, to get
   control of refresh scheduling and to cut read latency.

Everything else — the FPGA, the DDR3 device and its routing, power, and the
USB3 bridge — is hardware that already exists and has already been brought up.
The FT601 on the Ft+ occupies the role the CH569 was going to fill in
appletini-mega, without the firmware project attached to it.

**The two changes are independent, and change 2 needs no new hardware at all.**
UberDDR3 can be brought up and measured today on the existing v5 board. That is
why it is milestone 1: if the latency does not come out where this project needs
it, the CPU-socket carrier is not worth fabricating yet.

## What is already banked from AppleTini v5

Source: `~/repos/AppleTini/v5`, with the Vivado build outputs on the Windows
side at `/mnt/c/repos/AppleTini/v5`.

| Thing | Where it came from | Status here |
|---|---|---|
| Au board pins (clk/rst/LED/UART) | `v5_1_3.srcs/constrs_1/new/alchitry.xdc` | `constr/alchitry_au.xdc`, verbatim + bitstream config re-enabled |
| DDR3 pinout, 48 pins | `mig_a.prj` → `ref/mig_a.prj` | `constr/ddr3.xdc`, generated and cross-checked |
| FT601 pins | `.../ft.xdc` | `constr/ft601.xdc`, verbatim, not yet in the build |
| Apple slot pins | `.../tini.xdc` | `constr/apple_bus.xdc`, **provisional** — see below |
| Apple bus logic, mockingboard, mouse, NSC, VIA | `v5_1_3.srcs/sources_1/new/` | not carried over yet, deliberately |

`constr/apple_bus.xdc` is the **slot-edge** pinout. The CPU-socket carrier will
replace it wholesale — different signals (SYNC/VPA, VDA, MLB, VPB, BE, ABORTB,
E, MX) and a different FPGA pin assignment. It is carried over so milestone 3
starts from a working reference, not because those assignments will survive.
See `~/repos/appletini-mega/docs/cpu_socket_pinout.md` for the socket-side pin
functions and the direction-flip traps (DIP pins 1, 3, 5, 35, 36, 38).

### The DDR3 device and its configuration

`ref/mig_a.prj` is the authoritative record of what the Au actually has:

- **MT41K128M16JT-125** — Micron, 2 Gb, x16, DDR3L, 1.35 V, DDR3-1600 speed bin.
- 14 row bits, 10 column bits, 3 bank bits ⇒ 256 MB.
- All 48 pins in **FPGA bank 15**, `SSTL135`, `UNTUNED_SPLIT_50` input
  termination on DQ/DQS, `INTERNAL_VREF 0.675`.
- v5's MIG ran it at **DDR3-800** — 2500 ps DDR3 clock, 4:1 PHY, CL 6, CWL 5.

`tools/gen_ddr3_xdc.py` regenerates `constr/ddr3.xdc` from that file and
**cross-checks all 48 pins against the XDC MIG itself generated**
(`ref/mig_7series_0.generated.xdc`). It currently reports all 48 agreeing. Run
`--check` in CI or before a build; `build/build.sh` already does.

## UberDDR3: what it actually gives us

Pinned at commit `4a51b96` (2026-06-12), fetched by
`third_party/fetch_uberddr3.sh`.

### It fits the board

- Fixed **4:1** controller, so at 100 MHz controller / 400 MHz DDR3 it lands on
  exactly the DDR3-800 that MIG already proved on this board.
- x16 device = `BYTE_LANES` 2. Wishbone comes out 128 bits wide with a 24-bit
  address (`{row, bank, col[9:3]}`), one address per 8-beat burst — the same
  granularity MIG's 128-bit 4:1 app interface had. **This is not a finer access
  granularity than MIG.** Reading one Apple II byte still costs a 16-byte burst.
- `CL_generator(2500)` returns **CL 6**, matching `mrCasLatency` in the MIG
  project. `SPEED_BIN 3` reproduces MIG's tRCD/tRP/tRAS (13.75/13.75/35 ns), and
  `SDRAM_CAPACITY 3` reproduces its tRFC (160 ns). The configuration in
  `rtl/ddr3_wrapper.sv` is therefore a faithful re-creation of the v5 timing.
- Bank 15 is an **HR bank** — the ftg256 A35T has no HP banks at all — so there
  is no `ODELAYE2` and no DCI. `ODELAY_SUPPORTED = 0`, and the PHY needs a
  90°-shifted DDR3 clock, which `rtl/clk_gen.v` provides. Same situation as the
  Arty-S7, which is UberDDR3's closest reference design (also an x16
  MT41K128M16 on an HR bank).

### The latency case looks good

`sim/params_dump.sv` instantiates `ddr3_controller` with the strudelworks
configuration purely so the controller's own `$display` block reports its derived
timing. Run `sim/run_params_dump.sh`. At 100 MHz controller / 400 MHz DDR3, 2 Gb
x16, `SPEED_BIN 3`, `ODELAY_SUPPORTED 0` it reports:

```
CL = 6                              CWL = 5
READ_SLOT = 2   WRITE_SLOT = 3      ACTIVATE_SLOT = 0   PRECHARGE_SLOT = 1
PRECHARGE_TO_ACTIVATE_DELAY = 1     ACTIVATE_TO_READ_DELAY = 0
READ_TO_READ_DELAY = 0              READ_TO_PRECHARGE_DELAY = 1
STAGE2_DATA_DEPTH = 2               READ_ACK_PIPE_WIDTH = 6
```

CL 6 / CWL 5 is exactly what MIG programmed (`mrCasLatency`, `mr2CasWriteLatency`
in `ref/mig_a.prj`), so this is the same device configuration MIG ran, reached
independently.

Two things stand out:

- **`READ_ACK_PIPE_WIDTH = 6`** controller clocks from command issue to ack. Add
  the stage1/stage2 request pipeline and a page-hit read should land around
  **8 cycles ≈ 80 ns**.
- **A row miss costs about 2 extra cycles, not 10.** `PRECHARGE_TO_ACTIVATE = 1`
  and `ACTIVATE_TO_READ = 0` controller clocks — the command-slot layout absorbs
  tRP and tRCD almost entirely inside cycles the pipeline is spending anyway. So
  **random access is barely worse than sequential**, which is precisely the
  property this project needs and precisely what a throughput-optimised
  controller does not prioritise. Call it **~100 ns for a random read.**

MIG's 7-series 4:1 app-interface latency is commonly quoted in the 20–30 `ui_clk`
range (200–300 ns at 100 MHz). If that holds, this is the win.

### Measured in simulation — and it holds up

`sim/run_latency_tb.sh` runs `sim/latency_tb.sv` against the Micron DDR3 model
with UberDDR3's behavioural Xilinx primitives, at our clocks (100/400 MHz),
`ODELAY_SUPPORTED = 0`, x16, `SPEED_BIN 3`. iverilog only — no Vivado, no
hardware, about two minutes. 500 timed reads per pattern, one outstanding at a
time, counted from stb presented to ack inclusive so stall is included.

**Zero data errors.** Latency in controller clocks (10 ns each):

| Pattern | typical | distribution | worst |
|---|--:|---|--:|
| PAGE_HIT — one row, walking columns | **10 cy / 100 ns** | 493 of 500 at 10 | 56 cy |
| ROW_MISS — same bank, new row each read | **12 cy / 120 ns** | 493 of 500 at 12 | 55 cy |
| BANK_ROT — new row each read, rotating banks | **12 cy / 120 ns** | 436 at 12, 56 at 10 | 49 cy |
| RANDOM — LFSR over the whole space | **12 cy / 120 ns** | 413 at 12, 58 at 10 | 56 cy |

Three conclusions, in order of how much they matter:

**1. Random access costs 120 ns, and that fits both machines.** A row miss costs
exactly the 2 extra cycles the derived constants predicted. 120 ns fits inside
the IIgs' ~180 ns window with ~60 ns left for level shifters and synchronisers,
and fits the legacy ~490 ns window with room to spare. This is the result the
project was betting on.

**2. Sequential access is barely better than random** — 100 ns vs 120 ns. That is
the shape of a latency-optimised controller and the opposite of what a
throughput-optimised one gives you. Nothing about the access *order* needs
designing around.

**3. Bank interleaving buys nothing.** `BANK_ROT` and `ROW_MISS` do the same
number of row misses and differ only in whether consecutive accesses land in
different banks. They measured identically at 12 cycles. The hypothesis being
tested was that choosing the Apple-address → Wishbone-address map to maximise
bank changes would let PRECHARGE/ACTIVATE overlap and shave cycles. **It does
not** — UberDDR3's command slotting already hides tRP and tRCD. So the address
map is free to be whatever is simplest, and no effort should go into it for
latency reasons. Both patterns stay in the testbench as a regression.

### …except the outliers, which are all refresh

Every pattern has a tail: ~7 or 8 reads in 500 (about 1.4 %) land far above the
typical figure. That is a refresh collision.

The numbers above are with the controller set to the modelled 8 Gb density. The
Au's part is 2 Gb, and **`SDRAM_CAPACITY` is used at exactly one place in
`ddr3_controller.v` — the `tRFC` localparam — and nowhere else.** That makes the
density mismatch tractable rather than fatal: the stall being measured is
generated by the *controller* holding the bus for its own computed tRFC, not by
the model. Setting the controller to the real 2 Gb value while the model stays at
8 Gb therefore reproduces the real stall exactly. That is the default; build with
`+define+MODEL_DENSITY` to get the self-consistent 8 Gb run instead.

Refresh-collision cost, both ways:

| Controller tRFC | typical collision | worst | over legacy budget |
|---|--:|--:|--:|
| 350 ns (8 Gb, matches model) | 49 cy / 490 ns | 56 cy / 560 ns | 1–5 of 500 |
| **160 ns (2 Gb, the real part)** | **30 cy / 300 ns** | **37 cy / 370 ns** | **0 of 500** |

**Zero data errors in both runs.** The 2 Gb run does produce 74 `tRFC violation
during Activate` errors from the DDR3 model — that is the 8 Gb model correctly
objecting to 2 Gb timing, i.e. the density mismatch talking, not a controller
bug. Data is verified on every read, so if a violation had actually corrupted a
read the error count would say so. It does not.

That refines the conclusion in a way that matters:

> **Legacy machines already fit, refresh collisions and all — 0 of 500 reads
> exceeded the ~490 ns window in any access pattern.** Refresh control is needed
> for the **IIgs only**, where a 370 ns collision overruns the 180 ns window by
> 2× on roughly 1 access in 70.

`rtl/latency_probe.sv` measures the same thing on real hardware, against a real
2 Gb device with real timing rather than a model.

### ⚠ The refresh assumption does not hold as stated

The project brief assumes UberDDR3 allows taking control of **manual refresh**.
Reading the source: it does not.

- Auto-refresh is issued by the controller's internal instruction ROM on its own
  `tREFI` timer (`localparam tREFI = 7_800_000` ps, ROM instructions 19–22). The
  user has no hook to schedule, defer, or force it.
- What *is* exposed is **self-refresh** — `i_user_self_refresh` / the
  `SELF_REFRESH` parameter. That is the opposite of what is wanted: it hands
  refresh *to the DRAM* and makes the controller unavailable, and exiting costs
  `tXSDLL` (512 nCK, ~1.3 µs at 400 MHz) for DLL relock.

The one concession already in the controller is that it waits for pending
requests to drain before starting a refresh (`PRE_REFRESH_DELAY`, `pause_counter`
at ROM instruction 22) — so a refresh will not pre-empt an in-flight access, but
it can still start in the window just before one.

This is a **fixable gap, not a blocker**, and it is the main reason to pick an
open core in the first place. The measurement below settles which fix is needed:
an **`i_refresh_ok` gate** on the ROM's advance out of instruction 22, driven by
the Apple bus logic. The bus logic asserts it whenever the upcoming cycle will be
served from an already-fetched line, and the controller takes its refresh then.

The more invasive alternative — an explicit `i_refresh_req` / `o_refresh_ack`
pair with the whole schedule driven from outside — is not needed, and it would
move the JEDEC refresh budget onto us for no gain.

The patch must live in this repo as a patch file against the pinned commit, so a
future UberDDR3 bump cannot silently drop it.

### Licensing: UberDDR3 is GPL-3.0-or-later, and so is this project

**Settled.** UberDDR3 is GPL-3.0-**or-later**, a bitstream containing it is a
derivative work, so this project's gateware is GPL-3.0-or-later. AppleTini is
BSD-2 and appletini-mega is MIT; strudelworks deliberately differs from both.

Files that stand alone stay BSD-2-Clause so they can be lifted into non-GPL
projects, the carrier board will be licensed separately under CERN-OHL (`hw/`),
and every file carries an SPDX header. Full reasoning, the per-file table, the
Vivado and anti-tivoization consequences, and the two third-party traps waiting
in the v5 port are in [`../LICENSING.md`](../LICENSING.md).

### Traps found in the upstream reference designs

- **The Arty-S7 demo is internally inconsistent.** `arty_ddr3.v` passes
  `CONTROLLER_CLK_PERIOD(12_000)` / `DDR3_CLK_PERIOD(3_000)` (83.33/333.33 MHz)
  and its comments agree — but the `clk_wiz.v` checked in beside it is
  configured `CLKFBOUT_MULT 12 / CLKOUT0_DIVIDE 12 / CLKOUT1_DIVIDE 3`, i.e.
  100 MHz and 400 MHz. Do not copy that pair as a matched set; the controller's
  timing localparams are all derived from the *parameters*, so a mismatch
  silently computes DDR3 timing for the wrong clock. `rtl/clk_gen.v` and
  `rtl/ddr3_wrapper.sv` are commented with the requirement that they move
  together.
- Only `rtl/ddr3_top.v`, `rtl/ddr3_controller.v` and `rtl/ddr3_phy.v` belong in
  the build. `rtl/ecp5_phy/` is the Lattice PHY and will not synthesise for
  Artix-7; `rtl/axi/`, `rtl/ecc/` and `rtl/spd/` are unused features.
- MIG's XDC contains `IO_BUFFER_TYPE NONE` on `ddr3_ck_p/n` and a large block of
  `PHASER_*`/`OUT_FIFO`/`PLLE2` LOC constraints. None of it transfers — UberDDR3
  instantiates its own `OBUFDS` and has no such hierarchy. `constr/ddr3.xdc`
  documents each omission at the top.

## The latency budget this all has to fit

**Both machine classes are targets**: a IIgs at 2.8 MHz and any legacy Apple II
at ~1.023 MHz. The IIgs sets the spec, because its window is the short one.

| Machine | φ0 period | Address-valid → data-needed | Slack after a ~100 ns random read |
|---|--:|--:|--:|
| Apple II/II+///e, 1.023 MHz | 978 ns | ~490 ns | ~390 ns |
| IIgs, 2.8 MHz | 357 ns | ~180 ns | ~80 ns |

The window has to cover, end to end: level-shifter propagation both ways, input
synchronisers on the FPGA side, the DDR3 access, and the return path with setup
margin at the CPU. Only the DDR3 access is what UberDDR3 changes, so the ~80 ns
of IIgs slack is the budget for *everything else*, and it is not generous.

The memory requirement rules out doing this in BRAM: a IIgs ships with 8 MB and
expansion cards for the legacy machines are likewise far past the A35T's ~225 KB.
So DDR3 stays, and worst-case random-access latency is the number to drive down.

### ⚠ This makes refresh control mandatory, not optional

From the measured results above, on the Au's 2 Gb part:

```
random read, no refresh collision    120 ns   fits IIgs, ~60 ns left for the rest
random read during a refresh        ~370 ns   BLOWS the 180 ns IIgs window, 2x over
                                              (~1 access in 70)
```

A single refresh collision misses the IIgs deadline on its own, before any level
shifter or synchroniser is counted. So option 2 from "the refresh assumption does
not hold" above is **required for the IIgs target**, not a nice-to-have. It is
milestone 2 and it gates milestone 5.

Note this is not a *throughput* problem that a cache or a wider burst would fix —
the stall lands on one unlucky access in seventy, and on a machine with a hard
per-cycle deadline one late access is a wrong answer, not a slow one.

### …and the scheduling problem is not close to hard

The Wishbone burst is **16 bytes**. Instruction fetch — the majority of 6502/65816
bus cycles — is heavily linear, so once a line is fetched the next ~16 fetches are
already in hand and **the DDR3 is completely idle for those entire bus cycles**,
not merely for a half-cycle. We also know it *in advance*: whether the upcoming
cycle is a line hit is decidable before the cycle begins.

So the question is not "can we find a 160 ns gap", it is "how absurdly many gaps
do we have":

| Machine | bus cycle | refresh needed every | refreshes that fit in ONE free cycle |
|---|--:|--:|--:|
| legacy Apple II, 1.023 MHz | 978 ns | 8.0 cycles | 6 |
| IIgs, 2.8 MHz | 357 ns | 21.8 cycles | 2 |

Margin, as a ratio of free cycles available to free cycles required:

| Line miss rate | legacy | IIgs |
|---|--:|--:|
| 1 in 16 (pure linear fetch) | 7.5× | 20.5× |
| 1 in 8 | 7.0× | 19.1× |
| 1 in 4 (pessimistic) | 6.0× | 16.4× |

Even at a miss rate four times worse than linear instruction fetch implies, there
are six free bus cycles for every one refresh needs. Note the legacy machine is
the tighter one *per bus cycle* (a refresh every 8 rather than every 22) but its
cycle is long enough to retire six refreshes back to back, so it is not close
either.

**Consequence: run the refresh account in credit, not debt.** Rather than
deferring refreshes and hoping for a window before the deadline, issue them
*eagerly* whenever the upcoming cycle is a known line hit, spending JEDEC's
allowance to pull refreshes in (up to 8×tREFI early) instead of to postpone them.
The scheduler is then always ahead of schedule, the deadline case never arises,
and there is no need to stretch φ0 or drop RDY. That removes the one failure mode
worth actually fearing here — a starved refresh corrupts memory silently, which is
far worse than a stalled cycle.

Keep a deadline backstop anyway. It should never fire; if it ever does, that is a
bug report, not a performance event.

## Milestones

**1a. DDR3 latency in simulation.** ✅ **done**
`sim/run_latency_tb.sh`. Random read = 12 cycles / 120 ns, zero data errors,
refresh collisions the only thing over budget. Results above.

**1a-ii. Timing closure at DDR3-800.** ✅ **done**
`build/build.sh`, Vivado 2025.1, `xc7a35tftg256-2`. Bitstream builds and timing is
met with margin:

```
setup WNS  +2.285 ns   0 failing of 7181 endpoints   (clk_ctrl, 100 MHz)
hold  WHS  +0.080 ns   0 failing of 7181 endpoints
0 violated paths, 0 register pins with no clock, inter-clock table empty
utilisation: 3284/20800 LUT (16%), 2655/41600 FF (6%), 0/50 BRAM, 60/170 IOB
```

With the UART report added (milestone 1c) it still closes, with the expected cost
of more logic:

```
setup WNS  +1.906 ns   0 failing of 9265 endpoints
hold  WHS  +0.066 ns   0 failing of 9265 endpoints
utilisation: 3991/20800 LUT (19%), 3280/41600 FF (8%), 0/50 BRAM, 59/170 IOB
```

So **the DDR3-667 fallback is not needed** and the 120 ns random-read figure
stands rather than degrading to ~144 ns.

Two honest caveats:

- **Static timing passing is necessary, not sufficient, for 400 MHz.** The 400 MHz
  domains show only pulse-width slack (+0.908 ns) and contribute no setup/hold
  endpoints, because the PHY's fast logic lives inside OSERDESE2/ISERDESE2
  primitives rather than in register-to-register paths the STA engine analyses.
  The real 400 MHz risk on an HR bank with no ODELAY is **whether calibration
  converges on hardware** — read/write levelling against real board skew. Only
  milestone 1b answers that.
- **Hold margin is thin** (+0.080 ns, +0.066 ns with the UART report) but met
  post-route, which is the number that counts — hold is a property of routing, and
  the fast-process corner is already what the analysis uses. Worth knowing where
  it lives, though: with the report added the worst hold path moved *out* of the
  DDR3 controller and into `u_probe/win_count_reg -> u_report/b2b_bin_reg`, a
  register-to-register hop with almost no logic between. That path is entirely
  non-critical — the report fires at 1 Hz — so if it ever fails to close, add a
  pipeline stage on `value_of()` and forget about it. Do not let it drive
  decisions about the DDR3 path.

Also worth banking for later: **0 of 50 BRAM tiles used**, so the entire ~1800 Kb
is available for the milestone-2b line buffer, and IOB usage is 60/170 with the
Apple bus (~30) and FT601 (~40) still to add — about 130/170, which fits.

**1b. DDR3 latency on hardware.** ✅ **done**
`build/results/au_top.bit` flashed to the Alchitry Au on the v5 carrier. LEDs
settled into the alternating display, which by construction means
`calib_complete` is high and `data_error` is low — the LED output has only three
states and the other two are constant patterns.

Observed: `B 0 1 0 0 1 0 B` (B = blinking at the 4 Hz frame rate). The middle six
bits `010010` are a palindrome, so the reading is orientation-independent:

```
led[7]   = frame tag                 led[6:1] = 010010      led[0] = value bit 0
-> 0b0100100 = 36 cycles = 360 ns    and    0b0100101 = 37 cycles = 370 ns
```

| | simulated worst case | hardware |
|---|--:|--:|
| sequential | 37 cy / 370 ns | 36 or 37 cy |
| random | 37 cy / 370 ns | 37 or 36 cy |

**Hardware agrees with simulation to within one controller clock.** Three things
are now confirmed on real silicon rather than modelled:

1. **Calibration converges at 400 MHz** on an HR bank with no ODELAYE2. This was
   the largest single risk in the project and static timing could not answer it.
2. **Reads return correct data**, continuously, against a real device.
3. **The worst case is refresh, at the predicted magnitude.** The simulation's
   density-substitution trick (controller at 2 Gb tRFC, model at 8 Gb) is
   therefore validated — it predicted the real number to within 10 ns.

**1c. UART reporting.** ✅ **done** — built, verified in simulation, run on hardware
The LEDs structurally cannot show the typical case — `latency_probe` accumulates
maxima only, and those saturate at the refresh worst case within a second. So the
Au's own USB-serial bridge (pinned, previously just looped back) now prints a full
summary once a second at 115200 8N1:

```
-- strudelworks latency  win=00000042  1 cy = 10 ns --
SEQ min=010 mean=010.4 max=037 gt18=000071 gt49=000000
RND min=012 mean=012.1 max=037 gt18=000069 gt49=000000
errors=0
```

Statistics are per **window** of 2**16 accesses of one pattern, snapshotted at
window end, rather than cumulative — so the mean is not swallowed by the worst
case. A window is a power of two on purpose: the mean is then a shift, not a
divide. `gt18`/`gt49` use the same IIgs and legacy thresholds as
`sim/latency_tb.sv`, so the board and the simulator print comparable numbers.

`sim/run_report_tb.sh` decodes the serial line the way a real UART would —
mid-bit sampling at the real 115200 divisor — and diffs it against the expected
180-byte report. It currently reports **180 of 180 bytes matching**, so the
formatting and framing are verified without a board.

> **Line endings must be `"\015\n"`, never `"\r\n"`.** Verilog string literals do
> not define `\r` as an escape — it yields the literal character `'r'` (114), not
> CR (13). The first build printed a stray `r` and no carriage return, so every
> line overwrote the previous one. Worse, the testbench *passed*: `TEMPLATE` and
> `EXPECT` both used `"\r\n"`, so the test compared the bug against itself and
> reported 180/180. `report_tb.sv` now asserts the numeric byte values (every LF
> preceded by byte 13), which a self-consistent encoding mistake cannot satisfy.

### Hardware results ✅

From the board, after ~1878 windows (**123,076,608 accesses, zero errors**):

```
-- strudelworks latency  win=00001878  1 cy = 10 ns --
SEQ min=009 mean=009.2 max=036 gt18=000993 gt49=000000
RND min=009 mean=011.0 max=037 gt18=001142 gt49=000000
errors=0
```

| | simulated | **hardware** |
|---|--:|--:|
| sequential typical | 10 cy / 100 ns | **9.2 cy / 92 ns** |
| random typical | 12 cy / 120 ns | **11.0 cy / 110 ns** |
| best case | 10 cy / 100 ns | **9 cy / 90 ns** |
| worst case | 37 cy / 370 ns | **36–37 cy / 360–370 ns** |
| over IIgs budget | 1.40 % | **1.52 % / 1.74 %** |
| over legacy budget | 0 | **0** |

**Hardware beats simulation by one controller clock.** The explanation is in the
controller: `added_read_pipe` is a per-lane 0-or-1 cycle padding chosen during
calibration (`MAX_ADDED_READ_ACK_DELAY = 2`) so the ack waits for the slowest
byte lane. The behavioural ISERDES/IDELAY models needed 1; the real board's DQS
round trip landed inside the window and needed 0. That is calibration doing its
job, and it is not something simulation could have predicted.

Everything else lands where the model said. The refresh-collision *rate* is
1.5–1.7 % against a simulated 1.4 % — refresh is every 7.8 µs regardless of how
many accesses you count it over, so the rate is the invariant, not the count.
`gt49` is **0 in every window**: the legacy machines have never once missed their
deadline, refresh included.

Net: **random access is 110 ns typical, 90 ns best, 370 ns worst.** The IIgs'
180 ns window has 70 ns of headroom for level shifters and synchronisers in the
typical case, and misses only on the 1.7 % of accesses that collide with refresh —
which is exactly what milestone 2 removes.
Build `rtl/au_top.sv` (`build/build.sh`), run it on the v5 board, read the LEDs.
Confirms the simulated numbers against real timing, real calibration, and the
real 2 Gb tRFC — and confirms 400 MHz closes on an HR bank without ODELAY, which
simulation cannot tell us.

**1c. Same probe against MIG.** Drop `latency_probe.sv` onto v5's `mig_wrapper`
(the Wishbone-to-app-interface shim is small) and measure the same way. Turns
"UberDDR3 is faster" into a measured ratio on one board, one clock, one device —
the only comparison worth quoting.

**2. Refresh control.** ✅ **patch written, proven in simulation**
`patches/0001-refresh-gate.patch` against the pinned commit, applied
automatically by `third_party/fetch_uberddr3.sh` (verified to survive a clean
re-fetch — without that step a re-fetch would silently revert it, and the symptom
would be an intermittent refresh landing mid-cycle, not an obvious failure).

**How it works, and why it cannot go wrong.** The controller sequences refresh
through a ROM: instruction 21 is a NOP whose delay slot is tREFI — the countdown
during which the bus is open — and 22 raises the stall to drain pending requests
before the precharge-all/refresh pair at 19/20. The patch adds `i_refresh_ok` and,
when it is high, cuts the instruction-21 countdown short so the refresh is taken
*now*, in a window the caller has declared free.

The critical property is that it **only ever moves a refresh earlier**. If
`i_refresh_ok` never asserts, the tREFI counter expires exactly as upstream, so
refresh cannot be starved and retention is safe by construction. That is what
makes the credit-not-debt scheme need no deadline backstop of its own — the
existing timer *is* the backstop. Guarded by `REFRESH_GATE`, default 0, so
upstream behaviour and its formal properties are untouched unless enabled.

One floor: an early refresh is only taken once half of tREFI has elapsed.
Without it an always-idle bus would refresh continuously; with it the worst case
is twice the nominal rate, costing about 4 % of bandwidth.

**Result.** `sim/latency_tb.sv` gained a `GATED` pattern — same scattered
addresses as `RANDOM`, but with an idle bus cycle between accesses (35 controller
clocks, one IIgs cycle) and `refresh_ok` asserted for the first 6 of them, which
is what real bus logic must do: assert at the *start* of a known-free cycle so any
refresh it triggers (~23 clocks) finishes before the cycle ends.

| | RANDOM (ungated) | **GATED** |
|---|--:|--:|
| typical | 12 cy / 120 ns | **10.8 cy / 108 ns** |
| max | **37 cy / 370 ns** | **13 cy / 130 ns** |
| over IIgs budget | 7 of 500 | **0 of 500** |
| histogram tail | 30,31,32,33,36,37 | **nothing above 13** |

**The refresh tail is gone.** Worst case drops from 370 ns to 130 ns, which fits
the IIgs' 180 ns window with 50 ns to spare *on every single access*, not just
typically. Zero data errors, and the model raises no refresh-interval or
retention complaint — refreshes are still happening, just where we put them.

The typical case improves too (12 → 10.8 cycles) because an idle bus leaves the
request pipeline empty, so `t_wait` is zero. That is representative: from DDR3's
point of view the real Apple II bus is idle most of the time.

At the matched 8 Gb density (`--model-density`) the run is completely clean —
**zero model ERRORs**, only the benign `MICRON_SIM` warnings about the
deliberately shortened power-on sequence.

### ⚠ The refresh has to FIT inside the free window

Running `GATED` at 8 Gb turned up a constraint that the 2 Gb run hides, and it is
worth stating before someone changes the memory:

| device | tRFC | full refresh sequence | fits a 35-clock IIgs cycle? | GATED result |
|---|--:|--:|:--:|--:|
| **2 Gb (the Au)** | 160 ns / 16 cy | ~23 cy / 230 ns | **yes**, 127 ns spare | max 13 cy, **0** over budget |
| 8 Gb | 350 ns / 35 cy | ~42 cy / 420 ns | **no**, 70 ns over | max 25 cy, 50 of 500 over budget |

The sequence is `PRE_REFRESH_DELAY` + tRP + tRFC. If it is longer than the free
window, the refresh overruns into the following access and stalls it — the gate
still helps (8 Gb worst case fell from 56 to 25 cycles, and legacy overruns from
5 to 0) but it can no longer hide refresh completely.

So the rule for the bus logic is **not** "assert `refresh_ok` whenever idle", it
is "assert it only when at least tRFC + ~7 clocks of idle remain". At 1.023 MHz
one bus cycle is 978 ns and this is never in question; at 2.8 MHz the Au's 2 Gb
part fits with room, but a larger device would need two consecutive free cycles.
The `GATED` pattern is sensitive to this — it is what caught it — so keep it in
the suite as the regression that guards the assumption.

**Built and verified in hardware terms.** `latency_probe` gained a `GATE_EMULATE`
mode that stands in for the line buffer until 2b exists: a 35-clock idle gap
before every access (one IIgs bus cycle) with `refresh_ok` asserted for the first
6. The build closes:

```
setup WNS  +1.536 ns    hold WHS  +0.078 ns
18.75 % LUT, 7.90 % FF, 0/50 BRAM
```

**Verifying that the gate is actually synthesized matters more than the build
passing.** The first rebuild after the patch reported +1 LUT and +1 FF for a
16-bit comparator plus gating logic - Vivado had constant-propagated the whole
feature away, because `au_top` tied `refresh_ok` to `1'b0`. A green build proved
only that the RTL parses. Querying the routed checkpoint is the check that does
not lie:

```
u_ddr3/u_ddr3/ddr3_controller_inst/i_refresh_ok    <- reaches the controller
u_probe/refresh_ok_i_1_n_0, refresh_ok_i_2_n_0     <- LUTs driving it
```

If a feature is gated on a signal tied to a constant, the synthesis result tells
you nothing about the feature. Drive it, then look in the netlist.

### Hardware result ✅ — the refresh tail is gone

```
-- strudelworks latency  win=00000424  1 cy = 10 ns --
SEQ min=009 mean=009.0 max=010 gt18=000000 gt49=000000
RND min=009 mean=009.7 max=012 gt18=000000 gt49=000000
errors=0
```

27,787,264 accesses, zero errors.

| | ungated hardware | **gated hardware** |
|---|--:|--:|
| SEQ mean / max / over-IIgs | 9.2 / 36 cy / 993 | 9.0 / **10 cy** / **0** |
| RND mean / max / over-IIgs | 11.0 / 37 cy / 1142 | 9.7 / **12 cy** / **0** |

**Worst-case random read falls from 370 ns to 120 ns, and `gt18` reads 0** — not
"rarely misses", but *no access in 27.8 million exceeded the IIgs' 180 ns window*,
with 60 ns spare at the worst case. That is the milestone-2 objective, met on
silicon rather than in a model.

Hardware again came in one controller clock faster than simulation predicted (max
12 vs 13, mean 9.7 vs 10.8) — the same calibration-chosen `added_read_pipe`
effect seen in milestone 1, now confirmed twice. **The simulation is reliably
pessimistic**, which is the direction you want a model to err.

> ⚠ **What this does and does not prove.** `GATE_EMULATE` hands the controller a
> perfectly regular 35-clock window before *every* access. Real bus logic will
> not be that tidy - consecutive line misses arrive back to back with no gap
> between them. So this proves the *mechanism* works and costs nothing, not that
> the real access pattern always supplies a window. The margin analysis says it
> will (6x at 1 MHz, 20x at 2.8 MHz even at a pessimistic 1-in-4 miss rate), but
> milestone 2b is what turns that from an argument into a measurement.


**2b. Line buffer.** Falls out of milestone 2 rather than being separate work:
the 16-byte burst granularity means a line buffer exists whether or not we call it
one, and its hit signal is what drives `i_refresh_ok`. It also collapses *average*
latency to a cycle or two, since only misses reach the DDR3 at all.

Coherency is a **non-problem by design decision** (see "Two memory modes" below):
in internal-memory mode this design is the only writer, so the line buffer needs
no external invalidation and no snooping — only self-invalidation on our own
writes. That is a few comparators, not a cache-coherency protocol.

**3. FT601 + host path.** Port `ft600_fifo.sv` and `tini_bus_arbiter.sv` from
v5. Unchanged hardware, so this is a port, not a design.

**4. CPU-socket carrier.** The only new PCB. Reuse the connector part and the
pin map already worked out in appletini-mega
(`components/AppleII/CPUBus_Header_2x20_DIP40`, `modules/cpu_pinmap.zen`) — the
DIP-perimeter pad numbering there deleted a whole breakout board and should not
be re-derived.

**5. Apple bus logic.** Port from v5, retargeted from the slot edge to the CPU
socket.

## Two memory modes, and the DMA decision

The design has two distinct modes, and nearly every question about caching,
coherency and refresh resolves differently in each:

- **Internal-memory mode** — the soft CPU is fed from our own DDR3. This is the
  accelerated path, the one everything above is about, and the one that needs the
  line buffer and the refresh gate. **DMA is explicitly forbidden in this mode and
  the design is stated as incompatible with it.**
- **Host-memory mode** — the soft CPU operates against the motherboard's real
  physical memory. No DDR3 in the path, so no line buffer, no refresh scheduling
  problem, and DMA is somebody else's business.

**The mode is chosen at host boot and never changes while running.** A transition
therefore only ever happens across a reboot, at which point no memory state is
worth preserving — it is all reconstructed by the new boot. So there is no
handover, no cross-mode flush, and no dirty-line writeback path to design. Worth
stating because a mode switch that could happen *while running* would need all
three.

Forbidding DMA in internal-memory mode is a deliberate scope decision, and it is
worth the trade: it is what makes the line buffer trivially correct. With no
external writer there is nothing to snoop and nothing to invalidate but our own
writes. Every alternative — snooping the bus for foreign writes, or flushing on
every DMA grant — costs latency in the path this project exists to make fast.

**If DMA is asserted anyway, that is undefined behaviour, not a hardware hazard.**
The mechanism differs by machine model, but in every case asserting DMA
disconnects us from the bus rather than fighting us for it, so there is no
contention to design against. What we lose is knowledge: writes happen that we
never see, our copy of memory silently diverges from the host's, and the machine
is unlikely to stay stable for long. That is a correctness consequence of an
unsupported configuration, not a failure mode to harden against — do not spend
gates on it.

The cost is real and should be stated plainly rather than discovered: cards that
DMA (IIgs SCSI among them) will not work in internal-memory mode. That is a
documentation obligation, not a bug.

## Settled

- **Both machine classes are targets** — IIgs at 2.8 MHz and legacy at ~1 MHz.
  The IIgs sets the spec at ~180 ns.
- **DDR3 is required.** 8 MB on a IIgs and comparable expansion cards on the
  legacy machines are far past the A35T's ~225 KB of BRAM.
- **Refresh control is mandatory**, not conditional — the measurement settled it.
- **Refresh scheduling is easy**, because linear instruction fetch off a 16-byte
  burst leaves the DDR3 idle for whole bus cycles, predictably and in advance.
  Issue refreshes eagerly into known line hits; run the account in credit.
- **The address map is not a latency lever.** Measured, not assumed; see
  BANK_ROT vs ROW_MISS above.
### Why 400 MHz, and why not slower or faster

Xilinx's own MIG limit table ships with Vivado at
`data/ip/xilinx/mig_7series_v4_2/data/dlib/7series/time_periods.csv`. For
`artix7 / -2 / ftg / HR / DDR3 / 1.35V / Single Rank / Components`:

```
4:1  min 2500 ps   max 3300 ps      (2:1  min 2858 ps)
```

So the legal DDR3 clock range is **303-400 MHz**, and 2500 ps is the *fastest*
supported point. Note the column is a **minimum PERIOD**, i.e. a MAXIMUM
frequency - slower is always easier, and 533 MHz (1875 ps) is simply not offered.

The accompanying `time_periods.xml` shows `threshold="3000"` is a GUI
*PHY-ratio default selector*, not a reliability warning: `tmin_hr="2500"` is the
hard supported minimum. Running at 2500 ps is qualified, not marginal - and the
board confirms it, calibrating and running 151 M accesses without an error.

Slower is legal but strictly worse, because **the read pipeline is 6 controller
clocks at every frequency** (measured with `sim/run_params_dump.sh` at 133/100/83
MHz). Longer cycles simply make the same 6 cycles take longer:

| DDR3 period | freq | legal | best / worst (gated) |
|---|---|:--:|--:|
| 1875 ps | 533 MHz | no | - |
| **2500 ps** | **400 MHz** | **yes, fastest** | **90 / 120 ns** |
| 3000 ps | 333 MHz | yes | ~108 / 132 ns |
| 3300 ps | 303 MHz | yes | ~119 / 145 ns |

#### Tried and rejected: DDR3-1000 (125 MHz / 500 MHz) — fails to calibrate

Worth recording because the analysis alone would not have settled it, and because
the failure mode is instructive.

The reasoning for trying: the DRAM is a **DDR3-1600** part, loafing at 400 MHz, so
it is not the limit. And MIG's `tmin_hr = 2500` characterises MIG's PHY, which is
not the one we use - MIG drives the hard `PHASER_IN`/`PHASER_OUT`/`PHY_CONTROL`
blocks, UberDDR3 uses a soft PHY of plain `ISERDESE2`/`OSERDESE2`/`IDELAYE2`. It
was therefore an open question whether the Xilinx number bound us at all.

What happened, in order:

1. **133 MHz / 533 MHz routed and MET TIMING** — WNS +0.330 ns, WHS +0.065 ns,
   zero failing endpoints. No min-period or pulse-width violation on the BUFG or
   the SERDES. (It failed bitgen only on two setup errors of mine: a
   `CLKFBOUT_MULT_F` off the MMCM's 0.125 grid, and a 213 MHz IDELAYCTRL
   reference where `IDELAYE2` declares 200.)
2. **125 MHz / 500 MHz built completely clean** — VCO 1000, MULT 10.0, exact
   200 MHz reference. Setup +0.680 ns, hold +0.066 ns, 0 critical warnings.
3. **On hardware it does not calibrate.**

**So the fabric can carry the clock; the PHY cannot train at it.** The unit
interval shrinks from 1.25 ns to 1.00 ns, and this HR bank has no `ODELAYE2`, so
write deskew has only the 90-degree clock to work with. Xilinx's `tmin_hr = 2500`
turns out to bound the soft PHY too - it is a device/bank characterisation limit,
not a MIG software limit.

**The reusable lesson: timing closure is necessary but not sufficient for a DDR3
interface.** Two builds passed static timing at rates that cannot work. STA knows
nothing about training margin. The only check that counts is whether calibration
converges on the board - visible immediately on the LEDs, since a stuck
single-LED pattern means `calib_complete` never asserted.

Not tried: the edge between 400 and 500 MHz. Something around 433-466 MHz might
train at room temperature, but it would be above the characterised limit for
perhaps 10 % more acceleration, with no PVT guarantee - and a marginal DDR3
interface fails as silent data corruption, which is exactly what the probe's
`errors=0` currently protects.

**A faster fabric is not available on this device.** The controller clock is not
an independent choice: `ddr3_phy.v` drives OSERDESE2 with `DATA_WIDTH(4)` SDR /
`DATA_WIDTH(8)` DDR and `.CLKDIV(i_controller_clk)`, so CLKDIV must be CLK/4 -
the controller clock IS the SERDES divided clock. 200 MHz controller would mean
800 MHz DDR3, double the ceiling.

MIG does offer a 2:1 PHY (and `PhyDefault="2:1"` for this part), which at its
2858 ps minimum would give 350 MHz DDR3 and a **175 MHz** `ui_clk` - a genuinely
faster fabric. It is not a route worth taking: UberDDR3 has no 2:1 PHY, and
adopting MIG to get one forfeits the refresh gate, which is worth 370 ns -> 120 ns
on the worst case. No fabric speed-up buys back a quarter-microsecond stall.

- **DDR3-800 (400 MHz) works on hardware**, not just in static timing: +2.285 ns
  setup / +0.080 ns hold, and calibration converges on the real board. The
  DDR3-667 fallback in `clk_gen.v` is not needed.
- **Simulation predicts this board to within one controller clock**, and errs
  pessimistic — hardware came in 1 cycle faster on every figure, because
  calibration chose a smaller `added_read_pipe` than the behavioural models
  needed. The testbench can be trusted for milestone 2.
- **Random access is 110 ns typical / 90 ns best / 370 ns worst**, measured.
- **Legacy machines never miss**: `gt49 = 0` in every window, refresh included.
- **The 2 Gb refresh cost is measured, not scaled** — 30 cycles typical, 37 worst.
  No Micron download was needed; see the density note above.
- **Licence: GPL-3.0-or-later** for the gateware, BSD-2-Clause per-file where a
  file stands alone, CERN-OHL for the board. See [`../LICENSING.md`](../LICENSING.md).
- **Line buffer coherency is a non-problem.** DMA is forbidden in
  internal-memory mode, so we are the only writer and self-invalidation is the
  whole of it.
- **Mode switching happens only across a host reboot**, so there is no state to
  hand over and no flush path to design.
- **Asserting DMA anyway is undefined behaviour, not a hardware hazard.** The
  machine's own DMA mechanism disconnects us from the bus, so there is nothing to
  guard against electrically.

## Programming the board without Vivado

`build/load.sh` (openFPGALoader, SRAM) + `build/report.sh` (UART) is the working
loop: a few seconds per iteration, entirely in WSL, no GUI. Getting there turned
up several things that cost hours and would cost them again.

### ⚠ Flash the board once before SRAM loading will work

**A JTAG SRAM load could not bring the DDR3 up from cold.** With a flash image
that never touched the DRAM, every openFPGALoader SRAM load stalled in read DQS
training - `state_calibrate` oscillating between 2 (`MPR_READ`) and 4
(`ANALYZE_DQS`) - while Vivado's load of the *identical bitstream* reached 23
(`DONE_CALIBRATE`). Once the design was written to flash with
`openFPGALoader -b alchitry_au -f <bit>`, so that power-on boots a design that
initialises the DRAM, SRAM loading began working every time (6/6).

This is an **empirical correlation, not a proven mechanism** - why a cold DRAM
defeats a JTAG-loaded init when flash-boot manages it is not established. If SRAM
loads ever start failing this way again (single lit LED, no UART), the first move
is one flash write.

Evidence that narrowed it, in the order that mattered:

- `rtl/diag_top.sv` - MMCM + LED blink + unconditional UART, **no DDR3**. It ran
  perfectly under openFPGALoader, which ruled out "held in reset" and "clocks not
  running". Needed because in `au_top` a single lit LED is ambiguous: `led = 0x01`
  is both the "calibrating" indicator and the reset value of `calib_complete`.
- Reporting `ddr3_debug` (= `state_calibrate`) over the UART unconditionally. That
  turned "calibration fails" into "read DQS training retries forever", which is a
  different and much smaller problem.
- Reading openFPGALoader's `src/xilinx.cpp`: it does issue `JSHUTDOWN`+`JPROGRAM`
  before loading and `toggleClk(2000)` after `JSTART`, so neither a missing config
  clear nor a starved startup sequence explains it.
- JTAG frequency is not a factor (1, 3 and 6 MHz all behave identically).

### The USB plumbing

The Au's FT2232H (`0403:6010`) carries JTAG on channel A and the UART on channel
B, so usbipd moves both at once. While attached to WSL, Windows has neither.

- One-time, as Administrator: `usbipd bind --busid <id>`. **`Shared` does not take
  the device from Windows** - only `Attached` does, so binding is safe to leave.
- `ftdi_sio` claims BOTH channels on attach. openFPGALoader detaches the kernel
  driver itself, so this is not fatal, but `/etc/udev/rules.d/98-ft2232-jtag-noserial.rules`
  keeps it off interface 0 anyway.
- **The board re-enumerates for a few seconds after any programming session.**
  Two "the board has vanished" incidents were attaches issued inside that window.

### Reading the UART: use pyserial, not stty+cat

Two independent ways to get silence from a board that is transmitting perfectly,
both hit here:

- `stty -F PORT ...` applies settings then **closes the port, reverting them**;
  the following `cat` opens fresh at the default baud.
- Setting termios by hand and zeroing `c_cflag` leaves the baud bits at **B0**,
  which on Linux means *hang up the line*: DTR drops and the receiver is disabled.

`build/report.sh` uses pyserial, which gets both right.

### Fallback: headless Vivado

`build/program.tcl` programs via `open_hw_manager` **without opening the project**,
so it does not take the lock that breaks `build/build.sh`. Useful as a control
when comparing loaders, and as a fallback.

## Open questions

**None.** Milestone 1 is closed end to end. Typical, best and worst case latency
are all measured on hardware, the collision rate is measured, and 123 million
accesses have run without a data error. Everything below is construction, not
de-risking.
