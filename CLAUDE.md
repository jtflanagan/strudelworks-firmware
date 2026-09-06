# strudelworks-firmware - working rules

The FPGA card (Alchitry Pt V2, Vivado, Verilator). Its host sibling is
`../strudelworks-host`; the two repos commit in lock-step on one branch name
with mirrored subjects (`/strudelworks-host:commit-both`). First thing in any
session: `git status` both repos and get old work committed before editing.

- Every shell command starts with `cd /home/flana/repos/strudelworks-firmware &&`
  or uses absolute paths. Never rely on a persisted cwd.
- The card design is `build/build.sh --master`; the bit is
  `build/results/master_top.bit`, loaded with `build/load.sh build/results/master_top.bit`
  (SRAM, volatile). Use the skills: `/strudelworks-firmware:fw-build TAG`,
  `/strudelworks-firmware:fw-sim SUITE`, `/strudelworks-firmware:fw-load`.
- A timing miss is a WARNING to build.tcl: the build exits 0 and still
  writes a .bit. Read WNS (`build/wns.sh`), never the exit status. A miss is
  never green. A new deep tail (`build/depth_baseline.txt`) is named.
- Stop swhost on the Pi (verified) before any load; the link cannot resync.
  The FT2232H cable (JTAG + UART) is needed only for loading; the UART report
  is for a USB3 link that answers no register at all, never a routine step.
- Verilator-first: `sim/suite.sh quick|cpu|battery|boot`; iverilog only with
  `--iverilog` or when asked. Monitor long benches by their progress counters
  (`sim/progress.sh`), never timeout-and-retry; abort on bad/mism > 0.
- Explain the change and the expected result before every test run.
- Every `docs/*.md` opens with a `Status:` line (date, branch, WNS, check
  count); update it when a change lands. `docs/BOOT_BENCH.md` and
  `docs/DLINE.md` "Phasing and proof" hold the gate.
- Commit only when asked; never push.
