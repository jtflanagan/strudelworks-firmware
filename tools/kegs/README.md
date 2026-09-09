# KEGS as the IIgs reference

KEGS 1.38 lives at `/home/flana/repos/kegs.1.38` (unzipped from
`kegs.1.38.zip`, the tree made writable, `src/vars` = `vars_x86linux`, built
with `make` after `libxext-dev` and `libpulse-dev`).  It is the behavioural
reference for `docs/GS.md`; nothing here is vendored.

## The trace hook: `kegs-1.38-trace.patch`

Three small changes so a KEGS run can produce a deterministic per-instruction
trace of the ROM from reset:

- `-trace FILE`: every executed instruction's `Pc_log` record (KEGS's own
  32-byte log entry, `defc.h`) is appended to FILE, using the `-logpc` engine
  variant that already fills the in-memory ring.
- `-tracemax N`: stop and exit after N instructions (default 20,000,000).
- `-pintime SECS`: the clock chip answers a fixed time (seconds since
  1904-01-01) instead of the host's, so the ROM's clock reads are the same
  every run.

Apply to a pristine tree with `patch -p1 < kegs-1.38-trace.patch` in
`kegs.1.38/`, then `make` in `src/`.

## Producing the reference: `trace_rom.sh`

    tools/kegs/trace_rom.sh OUT.bin [N] [ROM]

Boots the ROM (default the host's `assets/apple2gs_rom3.bin`) with NO disks
and all-zero battery RAM at 2.8 MHz (`g_limit_speed = 2`), the clock pinned to
2026-09-08 12:00:00, and writes N instructions (default 5,000,000) to OUT.bin.
An X display is needed (WSLg's `:0` serves).

## Reading it: `decode_trace.py`

    tools/kegs/decode_trace.py OUT.bin [--from N] [--limit N]

One line per instruction: index, `pbr/pc`, opcode and operand bytes, A X Y S
D DBR P E, and the cycle count.  This is the shape `boot_gs_tb`'s
`trace_diff816.py` (rung 3) compares against.

## What a comparison can and cannot expect

The instruction SEQUENCE from reset is deterministic in both machines up to
the first point where timing enters: a VBL poll, the scan of a device that
answers at a different cycle, an interrupt.  KEGS's cycle model is not the
card's (it does not model refresh, and its 1 MHz stretch applies only to I/O
and shadowed writes), so `trace_diff816.py` compares in instruction order and
treats a wait loop (the same PC repeating) as one event on either side.
