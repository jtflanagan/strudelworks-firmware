#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 John Flanagan
# Live interrupts through the 65816, both modes.  ~2 s.  See sim/cpu816_irq_tb.sv:
# it is the GS/OS "every RTI two bytes late" bug written down as a test.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/cpu816_work/irq"
mkdir -p "$work"
python3 "$root/sim/gen_microcode816.py" --check
verilator --binary --timing -j 4 -O1 -Wno-fatal --top-module cpu816_irq_tb \
    -I"$root/rtl" \
    -GUCODE="\"$root/rtl/cpu65816_ucode.hex\"" \
    -GUCODE0="\"$root/rtl/cpu65816_ucode0.hex\"" \
    -GUSEQ0="\"$root/rtl/cpu65816_useq0.hex\"" \
    -Mdir "$work" "$root/sim/cpu816_irq_tb.sv" "$root/rtl/cpu65816.sv" \
    -o cpu816_irq_tb > "$work/verilator.log" 2>&1 || { echo "verilator build failed:" >&2; tail -30 "$work/verilator.log" >&2; exit 1; }
"$work/cpu816_irq_tb" | grep -v '^- '
