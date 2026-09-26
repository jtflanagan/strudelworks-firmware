---
name: fw-load
description: Put a bitstream on the card DURABLY - the swhost MCP's `load` tool, which writes the card's flash over USB3 (the boot loader's own path, ~20 s) and falls back to JTAG into flash only when that fails. Never SRAM. The build must be green; the card's stamp is confirmed.
disable-model-invocation: true
argument-hint: "CONF [BIT]"
arguments: [conf, bit]
allowed-tools: mcp__swhost__load, mcp__swhost__status, mcp__swhost__swhost, mcp__swhost__log_tail, Bash(cd /home/flana/repos/strudelworks-firmware && build/wns.sh:*), Read
---

# fw-load: the bitstream into the card's flash, over USB3

Conf: `$conf` (a script's conf on the Pi - never the user's swhost.conf)  Bit: `$bit`
(empty = build/results/master_top_gs.bit; the GS card is the one this work targets)

The previous build:
!`cd /home/flana/repos/strudelworks-firmware && build/wns.sh 2>/dev/null | head -1 || echo "no previous results"`

## The rule (docs/BOOT_LOADER.md, and the user, 2026-09-26)

A bitstream goes on the card through `mcp__swhost__load` and nothing else. It:

1. refuses a build that is not green - TIMING MET, no undriven (Synth 8-3848) or
   multi-driven (8-6859) net - recomputed from the build's log;
2. ships the package to the Pi's images/, stops swhost (verified);
3. proves the flash's state from the card - LINK_RESET (it boots from flash; an SRAM load is
   gone), identify, QUERY (the card checks the record and the whole bitstream) - and writes it
   over USB3 (`swboot load --reboot`) only when it is sane but differs from the package's record
   (stamp, length, bitstream CRC), then proves it again;
4. falls back to JTAG into flash when the flash is not sane or the USB3 load or its re-check
   fails, and proves it again - a failure there is reported, nothing more is tried;
5. sets the conf's `image = images/<pkg>`, starts swhost twice (the first start after a new
   image leaves the native 6502 driving) and checks the card's stamp against the bit's.

`build/load_card.sh` by hand is refused by tools/hooks/load_guard.sh (strudelworks-host) unless
the user asked for a hand JTAG load (`--force`); `--sram` is refused outright.

## Steps

1. Say, in two sentences, which bit (stamp) goes on and which conf runs it (explain-before-test).
2. Call `mcp__swhost__load` with `conf` and, if given, `bit`.
3. Report its step lines verbatim in short: USB3 or JTAG, the erase/program/query times, and
   `LOADED (flash): the card runs <stamp>` - or the refusal / `WRONG IMAGE` / failure as it
   stands. A refusal is reported, never worked around.
4. Remind that the Apple must be on for `tools/*_test.sh`.
