#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# sim/uthernet2_tb.sv under Verilator (sim/run_uthernet2_tb.sh is the iverilog
# run of the same bench).  The W5100 behind the sequencer's tightest op timing
# and the real message parser: docs/UTHERNET2.md.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/uthernet2_work"
mkdir -p "$work"
obj="$work/obj_vl"
verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module uthernet2_tb \
    -I"$root/rtl/common" -I"$root/rtl/a2" -Mdir "$obj" \
    "$root/sim/uthernet2_tb.sv" \
    "$root/rtl/common/ft601_msg_rx.sv" "$root/rtl/common/fd_bank.sv" \
    "$root/rtl/common/uthernet2_card.sv" \
    -o uthernet2_vl > "$work/verilator.log" 2>&1 || {
        echo "verilator build failed:" >&2; tail -30 "$work/verilator.log" >&2; exit 1; }
"$obj/uthernet2_vl" | tee "$work/uthernet2_vl.log"
grep -q '^PASS$' "$work/uthernet2_vl.log"
