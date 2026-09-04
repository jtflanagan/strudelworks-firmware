#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# sim/run_fb_sim_tb.sh's bench under Verilator (--binary --timing): the same
# fb_sim_tb.sv, the same checks, about twenty seconds instead of minutes.
# The iverilog script remains the second opinion.  See docs/FLOATING_BUS.md.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/fb_work"
mkdir -p "$work"
command -v verilator > /dev/null || { echo "verilator not found" >&2; exit 1; }
verilator --binary --timing -j 4 -O1 -Wno-fatal --top-module fb_sim_tb \
    -I"$root/rtl" -GUCODE="\"$root/rtl/cpu65c02_ucode.hex\"" \
    --Mdir "$work/obj_vl" \
    "$root/sim/fb_sim_tb.sv" \
    "$root/rtl/synchronizer.sv" \
    "$root/rtl/apple_bus_read.sv" \
    "$root/rtl/apple_bus_write.sv" \
    "$root/rtl/cpu65c02.sv" \
    "$root/rtl/boot_hold.sv" \
    "$root/rtl/vbl_lock.sv" \
    "$root/rtl/apple_mmu.sv" \
    "$root/rtl/fb_sim.sv" \
    "$root/rtl/fd_bank.sv" > "$work/build.log" 2>&1 || { tail -30 "$work/build.log"; exit 1; }
exec "$work/obj_vl/Vfb_sim_tb"
