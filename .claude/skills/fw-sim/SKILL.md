---
name: fw-sim
description: Run a named simulation suite (quick, cpu, battery, boot, all) with the progress-counter monitoring the project insists on - percent and ETA from the bench's own counters, early abort on bad/mism/FAIL, never timeout-and-retry.
argument-hint: quick|cpu|battery|boot|all [--iverilog] [--images=A,B]
arguments: [suite, opts]
allowed-tools: Bash(cd /home/flana/repos/strudelworks-firmware && sim/suite.sh:*), Bash(cd /home/flana/repos/strudelworks-firmware && sim/progress.sh:*), Bash(tail:*), Bash(grep:*), Bash(cat:*), Read, Monitor, TaskStop
---

# fw-sim: the named suites, monitored

Repo: /home/flana/repos/strudelworks-firmware (every command starts with `cd` there).
Suite: `$suite`  Options: `$opts`

Boot images on this machine:
!`cat /home/flana/repos/strudelworks-firmware/sim/images.local 2>/dev/null || echo "no sim/images.local - the boot suite needs --images=A,B or that file"`
Microcode:
!`cd /home/flana/repos/strudelworks-firmware && python3 sim/gen_microcode.py --check 2>&1 | tail -1 || true`

## The suites (sim/suite.sh)

| suite | what | time |
|---|---|---|
| quick | lint + microcode + every bench under ~10 s (27) | ~45 s |
| cpu | cpu_tb (Klaus), cpu_cycles, cpu_irq, cpu_predict | ~2 min |
| battery | quick + accel_vl + mem_integ + page_cache + fb_sim_vl | ~6 min |
| boot | run_boot_tb.sh --verilator per image, in parallel | ~4 min |
| all | battery + cpu + boot | ~12 min |

`--iverilog` adds the iverilog accel battery (~2 min): the rung gate (docs/DLINE.md
"Phasing and proof") wants both simulators; the everyday loop is Verilator-first and does
not (user decision 2026-09-02). Every bench is expected green (the kbd_inject /
bus_event_filter / boot slot-4 failures of 2026-09-06 were bench wiring, fixed 2026-09-07):
a FAIL is a finding, never "known".

## Steps

1. Say what changed and what result is expected before running (explain-before-test).
2. `quick` and `cpu`: run in the foreground,
   `cd /home/flana/repos/strudelworks-firmware && sim/suite.sh $suite $opts`.
3. `battery`, `boot`, `all`: run the same command with `run_in_background: true`, output to
   the task file. Each bench prints `== running <bench> -> sim/suite_work/<bench>.log` first.
   For the long ones (accel_vl, boot_*, mem_integ) check the live log about every 60 s with
   `sim/progress.sh sim/suite_work/<bench>.log` and report like
   `boot 43% (bus cycles 860000/2000000, rate 1400k clk/s, ETA ~2m10s) bad 0 mism 0 blocks r31 w0`.
   Known-good rates: Verilator ~1.4M clk/s, iverilog ~36k clk/s.
4. **Abort early** (TaskStop the background task) when progress.sh exits 3 (bad/mism > 0 or a
   FAIL), or when no new progress line has appeared for more than 3x the expected interval
   (2M clocks: ~1.5 s Verilator, ~55 s iverilog). Never re-run a bench because it "seems slow".
5. Report the suite's per-bench table and its last line (`SUITE x: N/N PASS` or the FAIL
   list). For a FAIL, quote the bench log's FAIL lines. For the boot bench add its check
   count and the measured ops/x (the numbers the docs Status line quotes).

Needs nothing but this machine.
