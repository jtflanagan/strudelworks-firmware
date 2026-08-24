#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Run apple/bustest.bin on rtl/cpu65c02.sv before it goes anywhere near an
# Apple II.  ~2 s.
#
# The round trip to hardware is minutes - assemble, build a disk, carry it over,
# boot, capture, bring the file back - and a program that wanders off on its
# third instruction costs the whole trip to discover.  This answers three
# questions here instead: does it run, what does it cover, and does it stay out
# of $C000-$CFFF, where a READ is not a read but a soft switch.
#
# It says nothing about whether the CORE is right.  That is what
# sim/run_cpu_tb.sh and sim/run_trace_replay.sh are for.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/bustest_work"
bin="$root/apple/build/bustest.bin"

[ -f "$bin" ] || bash "$root/apple/build.sh" >/dev/null

mkdir -p "$work/obj_dir"
python3 "$root/sim/gen_microcode.py" --check

verilator --cc --exe --build -O2 -Wno-fatal --top-module cpu65c02 \
    -I"$root/rtl" \
    -GUCODE_FILE="\"$root/rtl/cpu65c02_ucode.hex\"" \
    -Mdir "$work/obj_dir" "$root/rtl/cpu65c02.sv" "$root/sim/bustest_run_main.cpp" \
    -o bustest_run > "$work/verilator.log" 2>&1 || {
        echo "build failed:" >&2; tail -20 "$work/verilator.log" >&2; exit 1; }

exec "$work/obj_dir/bustest_run" --bin="$bin" --passes=4 "$@"
