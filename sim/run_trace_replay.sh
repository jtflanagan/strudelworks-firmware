#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Replay a captured Apple II bus trace against rtl/a2/cpu65c02.sv.
#
#   sim/run_trace_replay.sh path/to/capture.bustrace [--skew=N] [...]
#
# The trace comes from strudelworks-host:  tools/pi.sh trace FILE --reset
# (recorded on the desktop over TCP; nothing is written on the Pi).  That
# capture arms on RES', so the file starts at a reset and the machine's state at
# word 0 is known - which is the precondition for replaying it at all.
#
# WHAT THIS ANSWERS that nothing else here can.  run_cpu_tb.sh proves the core
# computes the right results and run_cpu_cycles_tb.sh proves each opcode takes
# the right NUMBER of cycles.  Neither has a bus, so neither can say which
# address is driven during a cycle whose value the instruction discards.  The
# unverified ones are listed in rtl/a2/cpu65c02.sv's header - the indexed
# page-cross fixup, JMP (abs)'s extra cycle, the decimal extra cycle, $5C's
# filler, and reset's two reads at PC.  A real 65C02 driving a real Apple II is
# the reference, and this compares against it.
#
# Verilated, like run_cpu_tb.sh: a trace is millions of cycles and iverilog is
# three orders of magnitude too slow for that.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/trace_work"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    exec "$(dirname "${BASH_SOURCE[0]}")/trace_work/obj_dir/trace_replay" --help 2>/dev/null ||
        { echo "build it first: run this script with a trace file" >&2; exit 2; }
fi

if [ $# -lt 1 ]; then
    echo "usage: $(basename "$0") TRACE_FILE [--skew=N] [--no-seed-s] [--max=N]" >&2
    echo "  captures come from:  swhost --real --trace FILE" >&2
    exit 2
fi

trace="$1"; shift
if [ ! -f "$trace" ]; then
    echo "no such trace: $trace" >&2
    exit 2
fi

mkdir -p "$work"

# Same contract as run_cpu_tb.sh: a ROM that does not match its generator means
# the datapath and the microcode are describing different machines.
python3 "$root/sim/gen_microcode.py" --check

verilator --cc --exe --build -O2 -Wno-fatal --top-module cpu65c02 \
    -I"$root/rtl/common" -I"$root/rtl/a2" \
    -GUCODE_FILE="\"$root/rtl/a2/cpu65c02_ucode.hex\"" \
    -Mdir "$work/obj_dir" "$root/rtl/a2/cpu65c02.sv" "$root/sim/trace_replay_main.cpp" \
    -o trace_replay > "$work/verilator.log" 2>&1 || {
        echo "build failed:" >&2; tail -20 "$work/verilator.log" >&2; exit 1; }

exec "$work/obj_dir/trace_replay" --trace="$trace" "$@"
