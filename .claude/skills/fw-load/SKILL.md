---
name: fw-load
description: Load a bitstream into the card's SRAM the safe way - cable, Pi and swhost states checked, swhost stopped and verified, build/load.sh, swhost restarted, the firmware stamp confirmed over USB3. No UART unless asked.
disable-model-invocation: true
argument-hint: "[BIT] [--no-restart] [--conf NAME.conf]"
arguments: [bit, opts]
allowed-tools: Bash(cd /home/flana/repos/strudelworks-firmware && build/load_card.sh:*), Bash(cd /home/flana/repos/strudelworks-firmware && build/wns.sh:*), Bash(cd /home/flana/repos/strudelworks-host && tools/pi.sh status), Bash(cd /home/flana/repos/strudelworks-host && tools/pi.sh stop), Bash(cd /home/flana/repos/strudelworks-host && tools/pi.sh start:*), Bash(cd /home/flana/repos/strudelworks-host && tools/pi.sh run:*), Bash(cd /home/flana/repos/strudelworks-host && tools/pi.sh push), mcp__swhost__swhost, mcp__swhost__status, mcp__swhost__log_tail, Read
---

# fw-load: the bitstream into SRAM, with swhost stopped

Firmware repo: /home/flana/repos/strudelworks-firmware; host repo: /home/flana/repos/strudelworks-host.
Bit: `$bit` (empty = build/results/master_top.bit)  Options: `$opts`

The bit, its timing, and the three states right now:
!`cd /home/flana/repos/strudelworks-firmware && build/load_card.sh --dry-run $bit 2>&1 || true`

## Why the order matters

swhost holds both FT601 interfaces and its link parser cannot resynchronise
(strudelworks-host README "The link"): reprogramming the FPGA under a live swhost wedges
it. The card is USB-powered from the Pi, so no Pi means no card. The FT2232H cable
(JTAG + UART, via usbipd) is needed ONLY here. The Apple may be off throughout.

## Steps

1. Read the dry run above. Stop, naming the fix, on `CABLE ABSENT` (plug the FT2232H USB
   cable; `usbipd bind --busid` once as Administrator) or `PI OFF` (power the Pi). If the
   timing line says `TIMING MISS`, do not load unless the user explicitly says to.
2. If `SWHOST UP`: `mcp__swhost__swhost` with `action: "stop"`; it must answer
   `stopped (verified ...)`. Re-check with `action: "status"` until `SWHOST DOWN`. (If the MCP
   server is unavailable: `cd /home/flana/repos/strudelworks-host && tools/pi.sh stop`, then
   `tools/pi.sh status`.)
3. Load, in the foreground (a sudo prompt is possible; ~30 s):
   `cd /home/flana/repos/strudelworks-firmware && build/load_card.sh $bit`
   Quote a `LOAD FAILED` verbatim and stop.
4. Unless `--no-restart`: `mcp__swhost__swhost` with `action: "start"` (add `conf` when the
   user named one; with none it runs the user's swhost.conf, as a bare `pi.sh start` does).
   If the host sources changed too, `tools/pi.sh push` first (or `tools/pi.sh run`, which
   builds, pushes and starts).
5. Confirm over USB3: the start reply's `firmware: built YYYY-MM-DD HH:MM:SS` (or
   `mcp__swhost__status`'s `LINK UP (fw ...)`) must equal the build's stamp. Report
   `(fw <short sha>, bit <stamp>, SRAM)` for the docs.
6. `LINK DOWN` or `fw unknown` after the load: say so, and name `build/report.sh` /
   `build/ft601_status.sh` (the UART) as the user's next step - do not run them unasked.
   Remind that the Apple must be on for `tools/*_test.sh`.
