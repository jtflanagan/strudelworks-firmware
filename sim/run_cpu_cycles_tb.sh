#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Every opcode's cycle count against the published 65C02 table.  ~5 s.
#
# This is the check the functional suites cannot make.  Klaus Dormann's tests
# verify that the CPU computes the right answer; they never look at how long it
# took.  A core can pass both suites end to end with instructions a cycle short,
# and in a machine where video, refresh and every peripheral are timed off the
# same phi0, that core is useless.  Run this before believing a green functional
# run means anything about timing.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/cpu_work"
mkdir -p "$work"

python3 "$root/sim/gen_microcode.py" --check
python3 "$root/sim/gen_cycle_table.py" "$work/cycle_vectors.hex"

# iverilog emits "sorry: constant selects in always_* processes" for part-selects
# read inside always_comb.  It is about the SENSITIVITY list it infers, not the
# expression's value - it makes the block sensitive to the whole signal rather
# than the selected bits, which is conservative and harmless for combinational
# logic.  Filtered so a real message is not lost in thirty copies of that one.
#
# The old binary is deleted first and the exit status is checked, NOT piped
# through grep.  Filtering in a pipeline hands the pipeline grep's status, so a
# failed compile looked successful and vvp then ran the PREVIOUS build - which
# reported a pass for code that no longer compiled.  A stale green is worse than
# a red.
rm -f "$work/cpu_cycles_tb.out"
if ! iverilog -g2012 -I "$root/rtl/common" -I "$root/rtl/a2" -o "$work/cpu_cycles_tb.out" -s cpu_cycles_tb \
        -Pcpu_cycles_tb.UCODE="\"$root/rtl/a2/cpu65c02_ucode.hex\"" \
        "$root/sim/cpu_cycles_tb.sv" "$root/rtl/a2/cpu65c02.sv" \
        > "$work/iverilog.log" 2>&1; then
    grep -vE "sorry: constant selects|cannot be synthesized" "$work/iverilog.log" >&2
    echo "compile failed" >&2
    exit 1
fi
grep -vE "sorry: constant selects|cannot be synthesized" "$work/iverilog.log" || true

exec vvp -n "$work/cpu_cycles_tb.out" +vec="$work/cycle_vectors.hex"
