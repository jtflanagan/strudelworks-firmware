#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The boot hold: the real core, the real driver and rtl/boot_hold.sv together,
# against a bus with a ROM at the vector and a keyboard.  ~2 s.
#
# The check worth the file is the keypress at every phase of the bus cycle,
# each seen exactly once - the blind $C000/$C010 alternation this replaced
# loses the ones that land just after the sample point.  See sim/boot_hold_tb.sv.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/cpu_work"
mkdir -p "$work"

python3 "$root/sim/gen_microcode.py" --check

# See run_cpu_cycles_tb.sh for why the compile status is checked directly rather
# than through the grep that filters iverilog's constant-select notes.
rm -f "$work/boot_hold_tb.out"
if ! iverilog -g2012 -I "$root/rtl" -o "$work/boot_hold_tb.out" -s boot_hold_tb \
        -Pboot_hold_tb.UCODE="\"$root/rtl/cpu65c02_ucode.hex\"" \
        "$root/sim/boot_hold_tb.sv" "$root/rtl/cpu65c02.sv" \
        "$root/rtl/apple_bus_write.sv" "$root/rtl/boot_hold.sv" \
        > "$work/iverilog_boot_hold.log" 2>&1; then
    grep -vE "sorry: constant selects|cannot be synthesized" "$work/iverilog_boot_hold.log" >&2
    echo "compile failed" >&2
    exit 1
fi
grep -vE "sorry: constant selects|cannot be synthesized" "$work/iverilog_boot_hold.log" || true

exec vvp -n "$work/boot_hold_tb.out"
