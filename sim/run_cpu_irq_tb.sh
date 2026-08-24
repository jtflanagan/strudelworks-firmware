#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# A live hardware interrupt through the soft core.  ~1 s.
#
# The one path every other CPU test leaves out: irq_n asserted for real, taken
# at an instruction boundary, and returned from by RTI.  See sim/cpu_irq_tb.sv -
# it is the Mockingboard lockup written down as a test.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/cpu_work"
mkdir -p "$work"

python3 "$root/sim/gen_microcode.py" --check

# See run_cpu_cycles_tb.sh for why the compile status is checked directly rather
# than through the grep that filters iverilog's constant-select notes.
rm -f "$work/cpu_irq_tb.out"
if ! iverilog -g2012 -I "$root/rtl" -o "$work/cpu_irq_tb.out" -s cpu_irq_tb \
        -Pcpu_irq_tb.UCODE="\"$root/rtl/cpu65c02_ucode.hex\"" \
        "$root/sim/cpu_irq_tb.sv" "$root/rtl/cpu65c02.sv" \
        > "$work/iverilog_irq.log" 2>&1; then
    grep -vE "sorry: constant selects|cannot be synthesized" "$work/iverilog_irq.log" >&2
    echo "compile failed" >&2
    exit 1
fi
grep -vE "sorry: constant selects|cannot be synthesized" "$work/iverilog_irq.log" || true

exec vvp -n "$work/cpu_irq_tb.out"
