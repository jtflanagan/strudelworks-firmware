# strudelworks-firmware - working rules

The FPGA card (Alchitry Pt V2, Vivado, Verilator). Its host sibling is
`../strudelworks-host`; the two repos commit in lock-step on one branch name
with mirrored subjects (`/strudelworks-host:commit-both`). First thing in any
session: `git status` both repos and get old work committed before editing.

- Every shell command starts with `cd /home/flana/repos/strudelworks-firmware &&`
  or uses absolute paths. Never rely on a persisted cwd.
- TWO CARDS, THREE RTL TREES (2026-09-18, docs/CORE_REFACTOR_65C02.md rung 1):
  `rtl/common` (link, DDR3, ring, register cut, telemetry, the peripherals both
  machines carry), `rtl/a2` (the 65C02 card: its core, L1, L2, sequencer,
  IIe-only cards, `a2_top.sv`) and `rtl/gs` (the 65816 card: its core, the
  chipset, its own copies of L1/L2/sequencer, `gs_top.sv`).  The two cards'
  cache decisions are independent (docs/REQ_65C02.md, docs/REQ_65816.md); a
  change in `rtl/common` is built by both tops.  The layer between the core
  and the page cache is L1: on the a2 card L1-I = `l1i` + `tlb` (rung 4, the TLB
  points into L2), L1-D = `dline`; on the gs card still iline + iscan + dline.
  "front" is retired and its identifiers are renamed as modules are touched.
- The card design is `build/build.sh --master` (a2_top) or `--gs` (gs_top); the bit is
  `build/results/master_top.bit`, loaded with `build/load.sh build/results/master_top.bit`
  (SRAM, volatile). Use the skills: `/strudelworks-firmware:fw-build TAG`,
  `/strudelworks-firmware:fw-sim SUITE`, `/strudelworks-firmware:fw-load`.
- A timing miss is a WARNING to build.tcl: the build exits 0 and still
  writes a .bit. Read WNS (`build/wns.sh`), never the exit status. A miss is
  never green. A new deep tail (`build/depth_baseline.txt`) is named.
- Stop swhost on the Pi (verified) before any load; the link cannot resync.
  The FT2232H cable is needed only for loading (JTAG); the UART report is
  GONE (2026-09-19): a card whose DDR3 has not calibrated answers every
  register over USB3 on the ring's boot lane (LINK_STAT, RING_STATUS,
  DDR3_DBG1..4), so that is where a calibration failure is read.
- Verilator-first: `sim/suite.sh quick|cpu|battery|boot`; iverilog only with
  `--iverilog` or when asked. Monitor long benches by their progress counters
  (`sim/progress.sh`), never timeout-and-retry; abort on bad/mism > 0.
- A readable register is read through the register cut (`rtl/wb_regfile.sv`:
  a `_s` shadow, a line in the flop block) and, if a host should see it move,
  added to `rtl/telem_map.vh` - with the layout number bumped and the host's
  `src/telemetry_map.hpp` changed in the same commit pair
  (`../strudelworks-host/tools/check_telem_map.py`). docs/TELEMETRY.md.
- Explain the change and the expected result before every test run.
- Every `docs/*.md` opens with a `Status:` line (date, branch, WNS, check
  count); update it when a change lands. `docs/BOOT_BENCH.md` and
  `docs/DLINE.md` "Phasing and proof" hold the gate.
- Commit only when asked; never push.
