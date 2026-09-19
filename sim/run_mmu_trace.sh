#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Replay a captured Apple II bus trace through rtl/a2/apple_mmu.sv and check its
# memory-map decisions against what the real machine returned.
#
#   sim/run_mmu_trace.sh path/to/capture.bustrace [--rom=FILE] [--max=N] [--show=N]
#
# The ROM defaults to the host's assets/Apple2e_Enhanced.rom when it is beside
# this repo; without one, ROM-class reads are counted but not compared.
#
# See sim/mmu_trace_check.cpp for what this proves and why nothing else can.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/mmu_work"

if [ $# -lt 1 ]; then
    echo "usage: $(basename "$0") TRACE_FILE [--rom=FILE] [--max=N] [--show=N] [--verbose]" >&2
    exit 2
fi
trace="$1"; shift
[ -f "$trace" ] || { echo "no such trace: $trace" >&2; exit 2; }

rom_arg=""
default_rom="$root/../strudelworks-host/assets/Apple2e_Enhanced.rom"
case " $* " in *" --rom="*) ;; *) [ -f "$default_rom" ] && rom_arg="--rom=$default_rom" ;; esac

mkdir -p "$work"
verilator --cc --exe --build -O2 -Wno-fatal --top-module apple_mmu \
    -Mdir "$work/obj_dir" "$root/rtl/a2/apple_mmu.sv" "$root/sim/mmu_trace_check.cpp" \
    -o mmu_trace_check > "$work/verilator.log" 2>&1 || {
        echo "build failed:" >&2; tail -20 "$work/verilator.log" >&2; exit 1; }

exec "$work/obj_dir/mmu_trace_check" --trace="$trace" $rom_arg "$@"
