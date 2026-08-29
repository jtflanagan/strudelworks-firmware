#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The VBL lock: the scanner found on the floating bus during the boot hold
# and followed from then on, through the real reader, driver, core and hold
# against an Apple with Sather's scanner counters.  A few minutes: several
# hundred thousand bus cycles.  See sim/vbl_lock_tb.sv and docs/VBL.md.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/sim/vbl_lock_tb.out"
iverilog -g2012 -I "$root/rtl" -o "$out" -s vbl_lock_tb \
    -P vbl_lock_tb.UCODE=\"$root/rtl/cpu65c02_ucode.hex\" \
    "$root/sim/vbl_lock_tb.sv" \
    "$root/rtl/synchronizer.sv" \
    "$root/rtl/apple_bus_read.sv" \
    "$root/rtl/apple_bus_write.sv" \
    "$root/rtl/cpu65c02.sv" \
    "$root/rtl/boot_hold.sv" \
    "$root/rtl/vbl_lock.sv"
exec vvp -n "$out"
