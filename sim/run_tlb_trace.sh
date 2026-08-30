#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# class_tlb against the MMU it caches, over captured Apple II bus traces.
#
#   sim/run_tlb_trace.sh [TRACE_FILE...]
#
# With no arguments, every .bustrace in sim/trace_work.  The comparison is
# internal (TLB entry vs the op path's cl_*, which run_mmu_trace.sh proves
# against the machine), so any capture exercises it - what the traces bring
# is tens of millions of real ops' worth of soft-switch traffic, LC banking
# and INTCXROM flips.  See sim/tlb_check_top.sv.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/tlb_work"

traces=("$@")
if [ ${#traces[@]} -eq 0 ]; then
    traces=("$root"/sim/trace_work/*.bustrace)
fi
[ -f "${traces[0]}" ] || { echo "no traces found" >&2; exit 2; }

mkdir -p "$work"
verilator --cc --exe --build -O2 -Wno-fatal --top-module tlb_check_top \
    -Mdir "$work/obj_dir" \
    "$root/sim/tlb_check_top.sv" "$root/rtl/apple_mmu.sv" "$root/rtl/class_tlb.sv" \
    "$root/sim/tlb_trace_main.cpp" \
    -o tlb_trace_check > "$work/verilator.log" 2>&1 || {
        echo "build failed:" >&2; tail -20 "$work/verilator.log" >&2; exit 1; }

fail=0
for t in "${traces[@]}"; do
    "$work/obj_dir/tlb_trace_check" --trace="$t" || fail=1
done
exit $fail
