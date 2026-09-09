#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The IIgs map against a model taken from KEGS, not from the RTL.
# See sim/mmu_xlate_gs_tb.sv.  +quick sweeps a sample, for the quick set.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/mmu_xlate_work"
mkdir -p "$work"
verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module mmu_xlate_gs_tb \
    -I"$root/rtl" -Mdir "$work/obj_gs" \
    "$root/sim/mmu_xlate_gs_tb.sv" "$root/rtl/apple_mmu.sv" \
    -o mmu_xlate_gs > "$work/verilator_gs.log" 2>&1 || {
        echo "build failed:" >&2; tail -30 "$work/verilator_gs.log" >&2; exit 1; }
exec "$work/obj_gs/mmu_xlate_gs" "$@"
