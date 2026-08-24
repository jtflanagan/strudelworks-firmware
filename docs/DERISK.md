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

### Licensing: the source is GPL-2.0-or-later, the bitstream is GPL-3.0-or-later

**Settled.** Our own files are GPL-2.0-**or-later** — chosen while the project was
unreleased and solely ours to relicense. UberDDR3 is GPL-3.0-**or-later**, and a
bitstream containing it is a derivative work, so the built gateware is
GPL-3.0-or-later. The `-or-later` on our files is what makes that combination
legal; GPL-2-only would not. AppleTini is BSD-2 and appletini-mega is MIT;
strudelworks deliberately differs from both.

`tools/ft601/ft601_probe.c` is the one exception, GPL-3.0-or-later by inheritance
from LeechCore-plugins. The carrier board will be licensed separately under
CERN-OHL (`hw/`), and every file carries an SPDX header. Full reasoning, the
source-vs-bitstream distinction, the Vivado and anti-tivoization consequences, and
the two third-party traps waiting in the v5 port are in
[`../LICENSING.md`](../LICENSING.md).

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

**3. FT601 + host path.** ~~Port `ft600_fifo.sv` and `tini_bus_arbiter.sv` from
v5. Unchanged hardware, so this is a port, not a design.~~ **Link closed on
hardware: 335.4 MB/s, sequence verified.** The "port, not a design" expectation
was wrong, and how it was wrong is the useful part.

*Measured.* 335.4 MB/s sustained FPGA→host, every word of a 32-bit counter
arriving in order, 0 timeouts and 0 errors, repeatable run to run. Throughput
scales 172→335 MB/s from queue depth 1→4 and then flattens while latency grows
linearly, so the host link is **latency-bound, not per-byte-bound**: a
single-outstanding driver caps near 175 MB/s, a multi-URB ring reaches 335. That
is measured through WSL's USB/IP tunnel, i.e. a floor, not a ceiling — within 7%
of what apertus report natively for the same chip.

*The host side needs no FTDI code.* `tools/ft601/ft601_probe` does enumeration,
chip configuration (vendor request `0xCF`) and streaming over plain libusb.
D3XX has no supported ARM Linux build, and linking a proprietary blob into a
GPL-3 work is a licence problem, so this removes a dependency the Pi 5 target
could not have carried anyway. Note `OptionalFeatureSupport = 0x0000` does NOT
mean the session request is optional — the FT601 only offers the fabric write
space once the host has announced a pending read on endpoint `0x01`. Without it
TXE# never asserts and the link moves exactly zero bytes.

*Why the board was flaky, finally.* `constr/ft601.xdc` assigned pins and never
constrained I/O timing — the delay constraints were auto-generated with
placeholder values, commented out, and false-pathed as well. Vivado never
checked when data reached the chip, so placement decided whether the FT601
sampled the current word or the previous one. Real constraints exposed **−5.216
ns of setup violation on 50 endpoints**, worst path `ft_txe` crossing the state
machine combinationally into a FIFO pop within a half cycle. This is why the
link would work, then stop working after an unrelated edit, with throughput
unchanged and nothing to point at. It was never run-to-run randomness; it was
build-to-build placement roulette on an untimed interface.

*Still open.* Output clock-to-out is not closed (WNS −2.030 ns, worst on
`ft_rd`, an RX control signal the TX benchmark does not exercise). The remaining
fix is registering the outbound bus in the IOBs — data and the `OBUFT` enable
packed together, or they skew apart — which needs the FSM re-derived for the
extra cycle. The I/O delay values in `constr/ft601.xdc` are estimates and must
be checked against `DS_FT600Q-FT601Q`. `tini_bus_arbiter.sv` is not yet ported;
this milestone covered the link, not the bus.

*FT601 silicon errata: transfers ending on a 1024-byte boundary do not
terminate.* Measured here, not inherited on faith. `tools/ft601/ft601_probe zlp`
announces N bytes on the session endpoint and then reads into a larger buffer:

    N        multiple of 1024?   got     result
    1024     yes                 0       timed out
    2048     yes                 0       timed out
    4096     yes                 0       timed out
    8192     yes                 0       timed out
    5120     yes                 0       timed out
    1020     no                  1020    terminated in 0.2 ms
    1028     no                  1028    terminated in 0.2 ms
    3000     no                  3000    terminated in 0.2 ms

Perfect correlation, with the non-multiples as a control group proving the method
sound. 1024 is wMaxPacketSize for SuperSpeed bulk, so a transfer of exactly
N*1024 has no short packet to end it and requires a zero-length packet the chip
never sends. Note the chip delivers **nothing at all**, not "the data without a
terminator".

The exact failure condition needs BOTH halves:

  - announce N and read exactly N        -> always works, multiples included
  - announce N and read MORE than N      -> works only if N is not a 1024 multiple

That is why the streaming benchmark never trips it: the source is continuous, so
the chip always holds more than the announced amount and the host's buffer fills
by length. It is precisely the bounded request/response case this milestone still
has to build.

**This is silicon, not driver.** ufrisk/pcileech-fpga documents it as "a bug (in
chip or driver)"; we reproduce it through our own libusb with no FTDI code
anywhere, which settles which. Their workaround - five magic `0x66665555` DWORDs
padding every stream by 20 bytes, relying on payloads being a multiple of 32
bytes so 20 is always enough - is therefore load-bearing, not decoration, and is
inherited correctly by matching their controller.

*Why posting exact-length reads is not the answer, though it works.* The failure
needs the host to be expecting more than arrives, so a read posted for exactly
the announced length is always satisfied by length and never asks the chip to
terminate anything. That is measured, not theoretical - every 335 MB/s run in
this milestone posted exact-length reads of 262,144 bytes, which is 256 x 1024,
and never tripped the errata. The multiple-of-1024 property is irrelevant unless
the read is longer than the data.

So a strict request/response protocol could sidestep this entirely at full speed.
This design is not going to be strict request/response: it wants to post large
speculative buffers as well, which structurally puts the host back in the
"asking for more than arrives" case. Exact-length reads therefore remain useful
where they apply, but cannot be relied on.

Posting 1024-byte reads instead - so a read can never outrun the data - also
works and also cannot be relied on: measured at 2.8 to 4.5 MB/s across queue
depths, about 75x below the link, because per-transfer cost dominates. Fine for a
control path, useless for bulk.

*Intended approach.* Insert a payload-free frame when the transmitter finds
itself idle at a 1024-byte boundary: no next message ready, nothing in flight,
and the byte count sitting exactly on the boundary. That shifts the boundary
without padding anything that is carrying data, costs nothing while traffic
flows, and unlike the reference's magic DWORDs it is a real frame the receiver
already parses rather than an in-band constant it must filter by value - which
matters because real payload can legitimately BE 0x66665555.

The framing protocol itself is deliberately not designed yet. What is settled is
that the errata is real, is in the silicon, and that the transmitter - not the
host, and not a padding constant - is where it gets handled.

*Method note worth keeping.* Throughput alone certifies nothing — every corrupt
build above still ran at 335 MB/s. The sequence check is what distinguished a
working link from a fast broken one, and it should stay in any future test.

**4. CPU-socket carrier.** The only new PCB. Reuse the connector part and the
pin map already worked out in appletini-mega
(`components/AppleII/CPUBus_Header_2x20_DIP40`, `modules/cpu_pinmap.zen`) — the
DIP-perimeter pad numbering there deleted a whole breakout board and should not
be re-derived.

**5. Apple bus logic.** Port from v5, retargeted from the slot edge to the CPU
socket. **Bus SNOOPING is closed on hardware** — see below; the write side and
the CPU-socket retarget are what remain.

### Bus snooping closed on hardware ✅

`snoop_top` captures every bus cycle and streams it to a host process over the
FT601 link, framed as BUS_EVENTS messages (`docs/PROTOCOL.md`). Measured in a
running Apple II: **2,035,230 events in 2.00 s = 1,017,361/s**, the card's own
event count matching the host's exactly, and a dump that decodes as coherent
6502 execution:

    c27d:  E6 4E        INC $4E      read 37, read 37, write 38
    c27f:  D0 0A        BNE +10      -> c281+0x0A = c28b
    c28b:  AD 00 C0     LDA $C000    keyboard: 1B, bit 7 clear, no key
    c28e:  10 ED        BPL -19      -> c290-19 = c27d

Both branch targets compute exactly, `$4E` (RNDL, the monitor's random seed)
increments monotonically across iterations, and the read at `c290` is the 6502
speculatively fetching past the branch operand. Three independent numbers agree:
the loop is 15 cycles and writes are **6.7%** of events (1 in 15); the rate is
0.3% under the 1.0205 MHz nominal, which is the stretched long cycle every 65;
and the read-read-write at `$004E` is the **65C02** RMW signature, so the capture
identifies the CPU variant.

*Only the sampling half was ported.* `apple_bus_read.sv` takes the synchronisers
and the two sample taps from v5's `apple_bus_wrapper.sv` and leaves behind
driving data/addr/RW, asserting INH/IRQ/RDY/DMA/NMI/RES, the bus_emit state
machine and the soft-switch strobe. The Apple pins are declared **input**, not
inout, so a snooper cannot drive the bus by construction rather than by
discipline.

*The taps are empirical and clock-dependent.* Address and control are sampled 20
cycles after phi0 falling, data 45 cycles after phi0 rising, counted at 100 MHz
against a ~1.023 MHz phi0. A IIgs at 2.8 MHz needs them re-derived.

*A trap worth recording.* An early capture looked broken: nothing in pages 1–B
or D–F, everything collapsed into `0x0xxx` and `0xCxxx`, which is exactly the
signature of A12/A13 stuck at 0 — ROM at `$D000+` aliasing down into `$C000`.
The pins were fine. The machine was executing from `$C2xx` with its variables in
zero page, so those pages genuinely never appear. **A page histogram cannot tell
a stuck address bit from a program that does not use those pages; only decoding
the instruction stream can.** Check the sequence before blaming the wiring.

### ⬜ Next: taking the bus by DMA — a fresh bring-up

**This has never been attempted on this hardware.** Treat it as bring-up, not as
a port.

*Why from a slot at all.* The card in hand is from a prior project and samples
the **slot** bus; it is not the CPU-socket approach of milestone 4. On a legacy
Apple II a slot card can pull the **DMA line**, after which it can drive address
and data on every cycle and stand in for the CPU — similar to, but not identical
to, sitting in the socket. The IIgs and the 65816 are **out of scope** until a
new hardware spin, which is weeks away at least. Nothing here should be
generalised to them.

*The mechanism, as understood from the hardware.* Asserting DMA′ is what
deactivates the 6502: there is circuitry on the Apple II motherboard that
explicitly shuts off the transceivers connecting the CPU to the bus. The CPU is
disconnected, not merely out-voted.

That has a useful consequence for the bring-up ladder. **Contention is not a
hazard to tiptoe around**, so the first experiment can assert DMA′ and drive in
one step; there is no need for a separate "assert DMA′ and drive nothing" rung
to prove it is safe to drive.

*What v5 does NOT give us.* The DMA path there is scaffolding:

  - `apple_addr_rw_enable` in `apple_bus_wrapper.sv` is declared, wired into the
    address and R/W tristates, assigned `0`, and never set anywhere else. v5
    never drove the address bus.
  - `apple_dma_pin` is `inout` and feeds the read synchroniser, but has **no
    driver at all**.
  - `ab_write.assert_dma` and `wr_addr_rw_en` are aggregated in
    `apple_bus_write_arbiter.sv` and consumed by nothing.

So the structs and the arbiter are shaped for it and the wrapper stops short.
Budget this as design work.

*What the board DOES give us.* `tini_addr_dir_pin` is in the pinout, so the
address-bus level shifters are bidirectional with direction control — the
capability is in the hardware, v5 simply never exercised it. Note the card
brings out DMA′ but **not the DMA daisy-chain pins**: single-card DMA is fine,
priority arbitration against another DMA card is not expressible.

*The one number we cannot derive ourselves.* The DMA timings are documented and
need looking up before the first attempt. The sampler's taps (address at +20,
data at +45 cycles from a phi0 edge) describe when the **CPU** presents its
signals; driving requires the setup and hold the rest of the machine expects,
which is a different figure and is not recoverable from a capture of someone
else driving.

*The instrument already exists.* Unusually for a bring-up, the bus can be
watched while it is interfered with — `snoop_top` is validated against a running
machine (above), so every driven cycle is checkable against a capture rather
than inferred. Keep `rtl/apple_bus_read.sv` **input-only**; put driving in a
separate module so the instrument can never become a participant. The `--snoop`
build's Apple pins would become `inout` only in a master top.

**6. The 65C02 soft core.** 🟡 **base-65C02 variant, functionally complete, all
256 opcodes cycle-verified, reset sequence corrected; bus-level comparison
against a real part has a tool, one capture, and an exerciser awaiting its
run**

`rtl/cpu65c02.sv`. This is the piece that makes the CPU socket worth having: the
card can only stand in for the CPU if it behaves like one on every cycle, not
just at the end of each instruction.

*Why not an off-the-shelf core.* There are many 6502 cores and most are correct
in the sense a software emulator needs — registers and memory end up right. The
socket needs a stricter property, because the rest of the machine watches the bus
every cycle: the same **number** of cycles per instruction, and the same
**address** driven during each of them, including the dummy reads where RW says
"read" and the CPU discards the byte.

*What the structure guarantees.* Every state performs exactly one bus access and
every bus access is one state. There is no state that skips the bus and none that
touches it twice, so an instruction's cycle count is exactly the length of its
state path and a dummy cycle is an ordinary state that happens to discard `din`.
That is the precondition for cycle accuracy, and it is the thing a core organised
around instructions gets wrong — it has to bolt dummy cycles on afterwards, which
is how they end up missing or at the wrong address.

*Timing contract.* One bus cycle per `cyc_en` pulse, with `addr`/`rw`/`dout`
registered and set up on the edge that ends the previous cycle. One `cyc_en` per
phi0 gives the address a full bus cycle of setup; `cyc_en` tied high runs a cycle
per clk for internal-memory mode. The core does not know which it is in.

*Verified.* Both of Klaus Dormann's suites pass — 96.6 M cycles for the NMOS
functional test and 66.9 M for the 65C02 extended-opcodes test — and all 256
opcodes match the published cycle table, including the conditional cases:
indexed page crossings, the write forms that pay for the fixup cycle whether or
not the index carried, ASL/LSR/ROL/ROR abs,X at 6-or-7 against INC/DEC abs,X at a
flat 7, taken and page-crossing branches, and the extra cycle decimal ADC/SBC
takes on the CMOS part.

Worth recording that the functional suites passed *first*, and the cycle table
then found six opcodes — the absolute stores and INC/DEC abs — taking one cycle
too many. A functional suite cannot see that class of bug at all, which is the
argument for `sim/run_cpu_cycles_tb.sh` existing separately.

*Implementation: microcoded, with a separate address unit.* The first working
version was a hand-written state machine. It passed everything and ran at
~118 MHz, and its critical path explained why: the state register out through a
256-way opcode decode, into the addressing-mode logic, into the effective-address
arithmetic, and back to the state register — 16 logic levels. The rewrite
attacks both halves of that.

**The decode is gone as logic.** The microcode ROM is addressed by
`{opcode, ucycle}` directly, with no mapping stage, so the opcode indexes the ROM
and there is no instruction decoder to walk through. It costs 3 block RAMs.

**The address arithmetic is eight bits wide, everywhere.** This is the part worth
internalising, because it is a property of the 6502 rather than a trick. Every
16-bit address computation on this architecture splits into an 8-bit add plus a
carry into the high byte — and the instruction set hands over an extra cycle
exactly when that carry actually has to propagate:

| the extra cycle | what it is really for |
|---|---|
| indexed page cross (+1) | ADL+X carried; ADH moves here |
| taken branch page cross (+1) | PCL+offset left the page; PCH moves here |
| JMP (abs) at 6 rather than 5 | the pointer's carry — which is the CMOS fix for the NMOS ($xxFF) wrap bug |

So the rule the microcode obeys is that **no microinstruction adds two arbitrary
8-bit operands into the high byte**. The AGU's low half is a real adder; its high
half is only ever an incrementer/decrementer driven by a carry that is either
produced this cycle or was saved from the cycle the ISA already paid for. The
AGU and the ALU run in parallel and neither feeds the other, so a cycle can form
an effective address and compute an ALU result at once.

A core that computes the full 16-bit effective address in one cycle is not being
clever — it is declining a cycle the architecture handed it, and paying for the
refusal in Fmax.

*Resource cost and speed, measured.* `build/synth_ooc.sh`, out of context on
`xc7a35tftg256-2`, routed:

```
                       microcoded      previous FSM
Slice LUTs             446  (2.1%)     1039  (5.0%)
Slice Registers         96  (0.2%)      152  (0.4%)
Block RAM                3  (6.0%)        0
setup WNS @ 10 ns    +0.929 ns        +0.057 ns
Fmax                  ~144 MHz         ~118 MHz
```

**~144 MHz**, closing in from above: a 7.0 ns target achieves 7.18 ns (139 MHz),
6.0 ns achieves 6.95 ns (144 MHz), and 5.5 ns achieves only 7.21 ns — the placer
thrashing on an unreachable goal, as it did on the FSM version. Less than half
the LUTs of the state machine, for three block RAMs out of fifty.

*What limits it now, and what does not.* The critical path is the microcode ROM
output, through the AGU operand mux, along the 8-bit adder's carry chain, and
back to the ROM address — the page-cross condition selecting the next
microinstruction. Nine logic levels against sixteen.

Notably it is **not** the Z flag, which is the usual wall for this class of core
and does not appear in the timing report at all. That is not luck, it is the same
property as the address arithmetic: a branch tests flags a previous instruction
wrote, never a flag computed in the same cycle, so the zero-detect is an ordinary
register-to-register hop with a whole cycle to itself.

*Behaviour preserved across the rewrite.* Both suites passed with **exactly** the
cycle totals the state-machine version produced — 96,561,329 and 66,905,009 —
which over 163 million cycles is a far stronger equivalence check than either
suite alone. (Both are now 2 higher, 96,561,331 and 66,905,011, since the reset
fix below lengthened the reset sequence by two cycles. The delta being exactly
two is what says nothing else moved with it.)

*Two bugs the rewrite introduced, both worth recording* because both are specific
to this style. First, the page-cross fixup incremented ADH by one instead of by
the saved carry; reads only reach that cycle when the carry was set, so they
could not tell the difference, and it was a **stores-only** corruption. Second,
JMP indirect updated ADH on the same edge that drove the address built from it,
so the high byte was still stale — which reproduces precisely the NMOS page-wrap
bug the sixth cycle exists to fix. Both are the same underlying mistake: putting
work in the cycle that consumes it rather than the cycle before.

*⬜ What is NOT verified: the dummy-cycle addresses.* Counts are checked; which
address is driven during a dummy cycle is not. Three are informed guesses and are
listed in `rtl/cpu65c02.sv`'s header: the indexed page-cross fixup address, the
JMP (abs) extra cycle, and the decimal extra cycle. The 65C02
differs from the NMOS part on exactly these, and the difference is **not
recoverable from Klaus's suites**, which check results rather than buses. Closing
this needs a cycle-level reference — either a per-cycle bus trace from a real
65C02, which `snoop_top` can already capture, or a published cycle-by-cycle
reference. The filler cycles of `$5C`, the 8-cycle NOP, are a guess for the same
reason.

*🟡 The instrument for closing it now exists.* `sim/run_trace_replay.sh` replays a
captured Apple II bus trace against this core and compares the address and R/W on
every cycle. Traces come from the host — `swhost --real --trace FILE` — which
arms on RES′ so a capture begins at a reset and the machine's state at word 0 is
known. What remains is a capture from a real machine; the tool is verified
against a self-generated trace by `sim/run_trace_selftest.sh`, which also checks
that a deliberately corrupted trace fails at the word it was corrupted in.

*How it deals with what a trace cannot tell it.* Three things differ between the
traced machine and this core for reasons that are nobody's fault, and the tool
names each rather than letting it be mistaken for a finding:

  - **The stack pointer.** Reset does not load S, it decrements it, so a real
    machine leaves reset with whatever the previous hour of software left minus
    three. The tool reads both resets off their own buses — the descending
    page-one reads before the vector fetch — derives S on each side, reports the
    two, and seeds this core with the traced value through an injected
    `LDX #S / TXS`. Neither side's behaviour is assumed; the compensation is a
    measured difference.
  - **Alignment.** The run is aligned on the `$FFFC/$FFFD` vector fetch, which
    both machines perform and which puts them at the same PC with the same
    flags, rather than on the RES′ edge — how many cycles a part spends getting
    from one to the other is precisely what must not be assumed. Any residual
    offset is found by a skew search and reported.
  - **Interrupts are not in the trace.** The event word carries RES′ and nothing
    else, so an IRQ appears only as the traced part suddenly fetching `$FFFE`.
    The tool recognises that shape and says so.

*✅ CLOSED, by a capture from a real Apple II.* `sim/trace_work/apple.bustrace`,
64 MB from `swhost --real --trace`, replayed against this core: **9,397,687
cycles in lockstep with the architectural state never parting company**, which
is a far stronger statement about the core than either functional suite. Eleven
distinct dummy-cycle sites drive a different address, and they are all the same
underlying difference:

| opcode | cycle | real 65C02 | this core | seen | mode |
|---|---|---|---|---|---|
| `$6C` | 3 | `$FDEF` | `$FDF0` | 41239 | JMP (abs), the CMOS extra cycle |
| `$91` | 4 | `$003D` | `$BFB0` | 5846 | STA (zp),Y — the always-paid fixup |
| `$B0` | 3 | `$FC01` | `$FCF0` | 1350 | BCS, taken and page-crossing |
| `$D0` | 3 | `$FC10` | `$FCD9` | 410 | BNE, same |
| `$30` | 3 | `$C1FF` | `$C101` | 110 | BMI, same |
| `$10` | 3 | `$C1FB` | `$C101` | 24 | BPL, same |
| `$95` | 2 | `$FEA8` | `$0001` | 8 | STA zp,X |
| `$94` | 2 | `$FEA6` | `$0000` | 4 | STY zp,X |
| `$B4` | 2 | `$C196` | `$0000` | 4 | LDY zp,X |
| `$B5` | 2 | `$C19E` | `$0001` | 4 | LDA zp,X |
| `$BD` | 3 | `$FAAD` | `$FA01` | 2 | LDA abs,X, page crossed |

**One rule accounts for every row: the 65C02 re-reads the last address it
accessed during an internal cycle, where this core drives a partially-formed
effective address.** For `$6C`, `$BD` and the `zp,X` forms that is the last
program byte; for `$91` it is the pointer's high byte in zero page; for the
branches it is PC. This core's choices are the NMOS ones — `am_zpidx` in
`sim/gen_microcode.py` even says "dummy read at the UN-indexed address" — and
the NMOS part is precisely what the 65C02 changed here.

So the three addresses this section called informed guesses are now measured.
The indexed page-cross fixup and the JMP (abs) extra cycle are both wrong in the
same way; the decimal extra cycle did not appear in this capture, because the
monitor's idle loop does no decimal arithmetic. ⬜ **Not yet fixed** — it is a
change to `am_zpidx`, `am_absidx`, `am_idy` and the branch microcode, and it
wants its own pass.

*✅ The variant was wrong, and is now right: this is a BASE 65C02.* The chip in
the machine is a first-generation part — the CMOS additions, but none of
Rockwell's RMB/SMB/BBR/BBS and none of WDC's STP/WAI. The core implemented all
of them, which means it answered `$x7` with a read-modify-write where the real
chip does nothing for one cycle. On those encodings it was not standing in for
the part at all.

They are now one-byte, one-cycle NOPs, which is what the part does, and the
whole `$x3`/`$x7`/`$xB`/`$xF` space is handled uniformly in
`sim/gen_microcode.py`. The RTL keeps its `hlt` register and `halted` output:
against this ROM they are inert rather than dead, because `hlt` is set by
`ir == $DB` at `ucyc == 1` and a one-cycle NOP never reaches ucyc 1 — and a WDC
variant of the ROM would need them.

Verification moved with it. `sim/gen_cycle_table.py` now carries the base part's
timing, and nothing is excluded: `$CB` and `$DB` used to be skipped because STP
and WAI never reach a next opcode fetch, so **all 256 opcodes are measured**,
280 checks, 0 failures. And upstream's prebuilt 65C02 suite could no longer be
used as shipped — it is assembled with `rkwl_wdc_op = 1`, which fully tests
Rockwell's bit instructions — so `third_party/build_base_65c02_test.sh`
re-assembles it with that switch and `wdc_op` at **0**, which tests those
encodings *as NOPs*. That is stronger than skipping them: it would catch a core
that implemented them anyway.

That script proves its own toolchain before it is trusted. It first assembles
upstream's configuration **unchanged** and requires the result to reproduce
upstream's prebuilt binary byte for byte; only then does it build the variant,
which therefore differs by exactly two assignments. Getting that control to pass
took three corrections — as65 needs `-x` for the CMOS modes, its `.bin` begins
at the lowest used address rather than at zero, and it fills unused memory with
`$FF` — every one of which would otherwise have produced a subtly wrong test
whose failures got blamed on the core.

Both suites pass: 96,561,331 and 66,874,616 cycles.

*✅ CLOSED COMPLETELY, by a capture of `apple/bustest.s` on the real machine.*
24,717,434 cycles replayed in lockstep — the whole trace after the exerciser
starts — with the architectural state never parting company, and **77 distinct
(opcode, cycle) sites** where the dummy-cycle address differs. Every one of them
is the same rule, in three shapes:

| sites | what the real 65C02 drives |
|---|---|
| 64 | re-reads the last **program** byte |
| 8 | re-reads the last **zero-page** byte it read — the `(zp),Y` pointer high byte |
| 5 | `$5C`'s filler: `$FF00` once, then `$FFFF` |

by instruction group: 26 absolute,X/,Y · 23 zero-page,X/,Y · 16 `(zp),Y` and
`(zp,X)` · 5 taken page-crossing branches · 5 `$5C` · 1 `JMP (abs)` · 1
`JMP (abs,X)`. Each site was hit 14,612 times, once per pass, over 14,612
passes of the exerciser.

**The 65C02 re-reads the last address it accessed during an internal cycle,
where this core drives a partially-formed effective address.** That is the whole
finding, and the informed guesses this section used to list are now measurements
across the entire instruction set rather than whatever the monitor's idle loop
happened to reach. `$5C`'s filler and `JMP (abs)`'s extra cycle — the last two
unverified items — are settled.

✅ **Fixed, and the same trace now replays clean: 24,717,434 cycles, zero
differences.** The 9.4 M-cycle monitor-boot capture — entirely different code —
also replays clean, which is what says the fix is the rule and not a curve
fitted to one program.

*How, in one address source.* `ADDR["LAST"]` is the address driven during the
previous bus cycle, a registered mux input costing 16 flops and no arithmetic.
Almost every case is just that: zero-page indexed, `(zp,X)`, `(zp),Y`, the taken
page-crossing branch, `JMP (abs)` and `JMP (abs,X)` all re-read whatever they
read last, and the microcode does not need to know which mode it is in.

*Except one, and it is the interesting one.* On the `abs,X`/`abs,Y` fixup cycle
what the part drives is **not a property of the instruction but of the data**:
if the index carried it re-reads the last program byte, and if it did not it
drives the effective address — which in that case is already correct. Reads and
the shifts only reach that cycle on a carry so they always take the first form;
stores and `INC`/`DEC abs,X` reach it either way and take both. Microcode cannot
see that, so `ADDR["FIXUP"]` makes the choice in hardware from the AGU's saved
carry — the same carry the cycle already uses to move ADH. It widened the
address field to 4 bits and the ROM to 51, still three block RAMs.

That distinction cost three rounds to find: fixing everything to "re-read the
last address" took 77 sites to 13, splitting conditional from mandatory took it
to 5, and only the five page-crossing stores left standing showed that the real
split is the carry.

`(zp),Y` re-reads its pointer either way, so `STA (zp),Y` re-reads its pointer
while `STA abs,X` does not. There is no obvious reason for that asymmetry; the
trace is the authority.

*Regression.* Both Klaus suites pass at **exactly** the cycle counts they had
before the change — 96,561,331 and 66,874,616 — which over 163 M cycles says the
fix moved nothing but which address is driven during cycles whose value is
discarded. All 256 opcodes still match the cycle table, 280 checks, 0 failures.
Lint clean.

⬜ **Not re-synthesised.** No Vivado on the workstation. The ROM is 51 bits
rather than 50 and the address mux has two more inputs, one of them a two-input
mux on the saved carry — the OOC numbers in this document are from before the
change and want redoing before the timing claims are relied on.

*⬜ The trace this needs next: `apple/bustest.s`.* The first capture covered
eleven dummy-cycle sites because that is all the monitor's keyboard loop
reaches. `bustest` is written to be watched rather than to pass — it executes
every opcode the part has, and every page-sensitive addressing mode in **both**
its same-page and page-crossing forms, so a trace of it contains the instruction
set rather than a sample of it.

It is assembled `--cpu 65SC02`, so the assembler refuses Rockwell's instructions
rather than the variant being a thing to remember; the crossings are held by
`.assert` directives comparing the page of each branch target against the page
after the branch, so a layout edit that stopped a branch from crossing fails the
build. Rockwell's and WDC's encodings are still *executed*, as raw bytes, because
"does nothing, in one cycle" is itself behaviour worth capturing.

`sim/run_bustest.sh` runs it on the core before it goes near hardware, and
reports what it actually covers rather than what it was meant to: **256 of 256
opcodes**, 1100 indexed accesses inside the page and 697 that carried into the
next, four passes in 13,514 cycles, and no access to `$C000-$CFFF` — where on
the Apple a *read* is not a read but a soft switch. It found two bugs in the
exerciser that a hardware trip would have paid minutes each for: `setup` wrote
the `JMP (abs)` pointer at `$42FF` and then filled `$4000-$43FF` over the top of
it, and `SCRATCH,X` with X=4 overlapped the pass counter, so every pass rewrote
it with the same value and a program that was running perfectly looked hung.

`apple/build.sh` assembles it and writes `bustest.dsk` by copying a **real DOS
3.3 disk** and adding two files to it with `a2kit`: `BUSTEST` as a binary at
`$6000`, and a `HELLO` that `BRUN`s it, so booting the disk installs the
exerciser without anyone typing anything. The file is then read back out through
DOS's own structures and compared against what was built.

*This replaced a hand-rolled image, and the reason is worth recording.* The
first version wrote its own boot sector and its own DOS 3.3 filesystem in
Python, because no DOS image was in the repo and Apple's DOS is not ours to
vendor. Both of those were true and neither was a good reason: there was a DOS
master sitting on the workstation, `a2kit` was one `cargo install` away, and
what got built instead was a solved problem solved again — including 60 bytes of
boot sector that no Apple had ever run. The rule it broke is a simple one:
**"not in the repo" is not "not available", and the answer to that is to ask.**

DOS itself is still not committed — `apple/base/` is ignored, and the script
says what to put there — but that is a reference to a file, not a
reimplementation of one.

*What was lost with it, honestly.* The hand-written loader could be simulated:
`sim/run_bustest.sh` used to boot the disk image with only the controller ROM's
read routine stubbed, which checked the slot arithmetic, the sector counting and
the physical/logical interleave. None of that exists to check now, because DOS
does the loading and DOS has been booting Apples since 1980. The check that
remains is the one that matters — that the bytes on the disk are the bytes that
were built — and `a2kit` does it by reading the file back rather than by
agreeing with itself.

*One thing the shrink was for is now moot, and one is not.* bustest went from
4265 bytes to **1449** by computing its page-crossing boundary instead of
pinning it at `$7000`; that was needed when everything had to fit on track 0
ahead of a boot sector, and DOS does not care. It stays because the padding was
never buying anything but a longer load, and the behaviour is byte-identical.

*The event word had a SYNC bit in it the whole time, and not using it cost two
wrong answers.* The field the wire format calls `m2sel`, after the IIe slot
signal that pin nominally carries, is wired to the CPU's **SYNC** line — high
exactly on an opcode fetch. Established from this capture two ways: over 33.5 M
cycles the number that are *both* a write and `m2sel` is **zero**, and taking
each `m2sel` cycle's byte as an opcode, the distance to the next one matched the
published cycle count for **109,090 consecutive instructions**, allowing the
documented +1. (`m2b0` is never high at all.) That is also an independent
confirmation of the cycle table, from hardware.

Without it, instruction boundaries in a trace were being inferred from the
*core's* sync — the thing under test — and there was no way to tell an opcode
fetch from an operand or data read. Both of the wrong answers below came from
that.

*Two wrong answers this capture produced first, and why.* The replay picks the
reset with the longest clean run behind it, which is right for a capture *of* a
reset and wrong for a capture of a program the reset merely leads **to**. Here
it chose a later Ctrl-OpenApple-Reset and diverged 66 cycles in — inside the
monitor's own path, on a `PHP` after `BIT $C015`, where the real part's carry
had survived the reset and this core's had not. Not a finding: reset does not
clear A, X, Y or the flags, so those are unmodellable from outside, exactly as
this section already said.

The fix is `--from=ADDR`, which aligns on an opcode fetch at a given address
instead — unambiguous now that SYNC says where instructions start. A program
entered from a reset vector sets up its own stack and registers within a few
instructions, so both machines converge whatever they arrived with. Aligned at
the exerciser's entry, the same trace runs 24.7 M cycles without the state ever
parting company.

*A property of the capture worth keeping.* RES′ is a switch with nothing
debouncing it, so one press of Ctrl-Reset arrived as **seven** reset sequences,
five of which had under 1000 cycles behind them before the next bounce cut them
off. The replay tool picks the reset with the longest clean run rather than the
first, and refuses to return a verdict on a run under 5000 cycles at all — the
first version of it aligned on a bounce, got four cycles, and reported PASS.

*✅ A difference the tool found before any Apple II was involved, since fixed:
reset was two stack cycles, not three.* Found on the bus before any Apple II was involved —
the tool reads both machines' reset sequences in the same terms, so a synthetic
trace with a correct reset in front of it was enough to expose it. From `rst`
release this core drove `$0000`, `$0100`, `$01FF`, `$FFFC`, `$FFFD`: one dummy
read, **two** stack reads, the vector. A 65C02 does two dummy reads and **three**
stack reads, seven cycles. So the core left reset with S one byte higher than the
part does — a functional difference, not merely a bus-timing one.

Klaus's suites cannot see it, because both set S themselves before touching the
stack. `BRK` was correct all along — it pushes three times, `$01FF`/`$01FE`/
`$01FD` — so the fault was in reset's ENTRY, not in the shared microcode.

The cause is the ROM's pipeline. `uaddr` is `{ir, ucyc_next}`, so the slot
fetched during a cycle is the one that RUNS in the next; the cycle out of reset
runs the zeroed `uc`, and what it fetches is slot `ucyc+1`. Entering at `3'd1`
therefore skipped slot 1 outright. Entering at **`3'd7`** makes that zeroed cycle
stand in for a slot of its own and resumes at slot 0, which is the part's
sequence exactly: two reads at PC, three stack, two vector.

```
before   $0000  $0100  $01FF                $FFFC  $FFFD      5 cycles, S -= 2
after    $0000  $0000  $0100  $01FF  $01FE  $FFFC  $FFFD      7 cycles, S -= 3
```

Both Klaus suites still pass, and each total moved by **exactly +2 cycles** —
96,561,331 and 66,905,011 against 96,561,329 and 66,905,009 — which is the two
cycles reset gained and nothing else. Over 163 million cycles that is a sharper
statement than "still passes": no other instruction's behaviour moved at all.
The 278-check cycle table is unaffected.

Reset's two reads at PC are now themselves on the unverified list: this core
drives them at PC and PC, and a real part may show PC and PC+1.

*Variant.* The **base 65C02** — the first-generation part. The CMOS additions
are all present; Rockwell's RMB/SMB/BBR/BBS and WDC's STP/WAI are not, because
the chip this core stands in for does not have them. Undefined encodings are the
CMOS NOPs throughout, never the NMOS undocumented instructions.

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
- **Licence: GPL-2.0-or-later** for our source, GPL-3.0-or-later for any bitstream
  built from it (UberDDR3), CERN-OHL for the board. See [`../LICENSING.md`](../LICENSING.md).
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
