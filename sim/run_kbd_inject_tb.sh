#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Keyboard injection: the real core, driver, READER and hold with
# rtl/kbd_inject.sv, against a bus with a ROM and a keyboard.  ~3 s.
#
# The check worth the file is that the byte the core latched and the byte the
# capture recorded are the same byte on every cycle - the substitution lands
# on one tap for both, and only the real reader can say so.  See
# sim/kbd_inject_tb.sv.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/cpu_work"
mkdir -p "$work"

python3 "$root/sim/gen_microcode.py" --check

rm -f "$work/kbd_inject_tb.out"
if ! iverilog -g2012 -I "$root/rtl" -o "$work/kbd_inject_tb.out" -s kbd_inject_tb \
        -Pkbd_inject_tb.UCODE="\"$root/rtl/cpu65c02_ucode.hex\"" \
        "$root/sim/kbd_inject_tb.sv" "$root/rtl/cpu65c02.sv" \
        "$root/rtl/apple_bus_write.sv" "$root/rtl/apple_bus_read.sv" \
        "$root/rtl/synchronizer.sv" "$root/rtl/boot_hold.sv" \
        "$root/rtl/kbd_inject.sv" "$root/rtl/pb_inject.sv" \
        > "$work/iverilog_kbd_inject.log" 2>&1; then
    grep -vE "sorry: constant selects|cannot be synthesized" "$work/iverilog_kbd_inject.log" >&2
    echo "compile failed" >&2
    exit 1
fi
grep -vE "sorry: constant selects|cannot be synthesized" "$work/iverilog_kbd_inject.log" || true

exec vvp -n "$work/kbd_inject_tb.out"
