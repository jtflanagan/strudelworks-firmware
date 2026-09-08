#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# sim/run_accel_tb.sh's bench under Verilator (--binary --timing): the same
# accel_tb.sv, the same program, the same checks - built for the branch-
# prefetch work, where the sim cycle is Verilator-only until the design is
# done.  Much faster than iverilog; the iverilog script remains the
# pre-hardware cross-check.
#
#   sim/run_accel_vl.sh [PHI0_HIGH ...]    default: 49, then 47
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/accel_work"
mkdir -p "$work"

python3 "$root/sim/gen_microcode.py" --check

for t in ca65 ld65 xxd verilator; do
    command -v "$t" > /dev/null || { echo "$t not found" >&2; exit 1; }
done
ca65 --cpu 65SC02 -l "$work/accel.lst" -o "$work/accel.o" "$root/sim/accel.s"
ld65 -C "$root/sim/mem_integ.cfg" -o "$work/accel.bin" "$work/accel.o"
xxd -p -c1 "$work/accel.bin" > "$work/accel.hex"

highs=("$@"); [ ${#highs[@]} -eq 0 ] && highs=(49 47)
for high in "${highs[@]}"; do
    obj="$work/obj_vl_$high"
    verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module accel_tb \
        -I"$root/rtl" \
        -GUCODE="\"$root/rtl/cpu65c02_ucode.hex\"" \
        -GPROG="\"$work/accel.hex\"" \
        -GPHI0_HIGH="$high" \
        -Mdir "$obj" \
        "$root/sim/accel_tb.sv" "$root/rtl/cpu65c02.sv" "$root/rtl/accel_seq.sv" "$root/rtl/fast_census.sv" \
        "$root/rtl/game_port.sv" \
        "$root/rtl/iline.sv" "$root/rtl/iscan.sv" "$root/rtl/dline.sv" \
        "$root/rtl/synchronizer.sv" "$root/rtl/apple_bus_read.sv" "$root/rtl/apple_bus_write.sv" \
        "$root/rtl/boot_hold.sv" \
        "$root/rtl/apple_mmu.sv" "$root/rtl/rom_loader.sv" "$root/rtl/page_cache.sv" \
        "$root/rtl/way_ram.sv" "$root/rtl/page_client.sv" "$root/rtl/wb_arb.sv" "$root/rtl/event_merge.sv" \
        -o accel_vl > "$work/verilator_$high.log" 2>&1 || {
            echo "verilator build failed:" >&2; tail -30 "$work/verilator_$high.log" >&2; exit 1; }
    echo "== PHI0_HIGH = $high"
    "$obj/accel_vl" | tee "$work/accel_vl_$high.log"
    grep -q '^PASS$' "$work/accel_vl_$high.log"
done
