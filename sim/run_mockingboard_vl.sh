#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# sim/mockingboard_tb.sv under Verilator (sim/run_mockingboard_tb.sh is the
# iverilog run of the same bench).  The Mockingboard behind the real bus
# driver, on an Apple-shaped phi0: docs/MOCKINGBOARD.md.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/mockingboard_work"
mkdir -p "$work"
obj="$work/obj_vl"
verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module mockingboard_tb \
    -I"$root/rtl/common" -I"$root/rtl/a2" -Mdir "$obj" \
    "$root/sim/mockingboard_tb.sv" \
    "$root/rtl/common/apple_bus_write.sv" "$root/rtl/common/mockingboard.sv" "$root/rtl/common/via6522.v" \
    "$root/rtl/common/ay_pair.sv" "$root/rtl/common/YM2149.sv" "$root/rtl/common/ssi263.sv" "$root/rtl/common/slot_switches.sv" \
    -o mockingboard_vl > "$work/verilator.log" 2>&1 || {
        echo "verilator build failed:" >&2; tail -30 "$work/verilator.log" >&2; exit 1; }
"$obj/mockingboard_vl" | tee "$work/mockingboard_vl.log"
grep -q '^PASS$' "$work/mockingboard_vl.log"
