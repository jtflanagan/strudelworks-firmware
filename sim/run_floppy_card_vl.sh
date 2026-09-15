#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# sim/floppy_card_tb.sv under Verilator (sim/run_floppy_card_tb.sh is the
# iverilog run of the same bench).  The Disk II behind the real driver,
# receiver and arbiter: docs/FLOPPY.md.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/floppy_card_work"
mkdir -p "$work"
obj="$work/obj_vl"
verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module floppy_card_tb \
    -I"$root/rtl" -Mdir "$obj" \
    "$root/sim/floppy_card_tb.sv" \
    "$root/rtl/apple_bus_write.sv" "$root/rtl/ft601_msg_rx.sv" "$root/rtl/msg_arb.sv" \
    "$root/rtl/msg_master.sv" "$root/rtl/slot_switches.sv" "$root/rtl/fd_bank.sv" \
    "$root/rtl/floppy_card.sv" \
    -o floppy_card_vl > "$work/verilator.log" 2>&1 || {
        echo "verilator build failed:" >&2; tail -30 "$work/verilator.log" >&2; exit 1; }
"$obj/floppy_card_vl" | tee "$work/floppy_card_vl.log"
grep -q '^PASS$' "$work/floppy_card_vl.log"
