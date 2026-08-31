#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The core faster than the bus: the sequencer between the real core and the
# real driver, the reader on the pins, the MMU shadow, the ROM, the cache, the
# DDR3 client, the arbiter and the boot hold, running sim/accel.s against the
# 128K IIe model of sim/mem_integ_tb.sv - mode 0 (the old machine), then reads
# on the card, then reads and writes, the governor, a DMA, the hold, a reset,
# an invalidate, the slow zone.  ~2 min.  See sim/accel_tb.sv.
#
#   sim/run_accel_tb.sh [--verilator] [PHI0_HIGH ...]
#                                          default: 49, then 47 - the sweep of
#                                          the core-to-present margin
#   --verilator: ~60x the runtime (one ~40s build per sweep); the iverilog
#   path stays for cross-checks - the two have produced byte-identical
#   traces on this design, and a disagreement is itself a finding.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/accel_work"
mkdir -p "$work"

python3 "$root/sim/gen_microcode.py" --check

for t in ca65 ld65 xxd; do
    command -v "$t" > /dev/null || { echo "$t not found (apt install cc65 xxd)" >&2; exit 1; }
done
ca65 --cpu 65SC02 -l "$work/accel.lst" -o "$work/accel.o" "$root/sim/accel.s"
ld65 -C "$root/sim/mem_integ.cfg" -o "$work/accel.bin" "$work/accel.o"
xxd -p -c1 "$work/accel.bin" > "$work/accel.hex"

vl=0
args=()
for a in "$@"; do
    case "$a" in
        --verilator) vl=1 ;;
        *) args+=("$a") ;;
    esac
done
highs=("${args[@]:-}"); [ -z "${highs[0]:-}" ] && highs=(49 47)

srcs=("$root/sim/accel_tb.sv" "$root/rtl/cpu65c02.sv" "$root/rtl/accel_seq.sv"
      "$root/rtl/class_tlb.sv" "$root/rtl/icache_l1.sv" "$root/rtl/l1_front.sv"
      "$root/rtl/d_front.sv" "$root/rtl/dcache_l1.sv" "$root/rtl/dcache_sa.sv"
      "$root/rtl/wb_lines.sv" "$root/rtl/event_merge.sv" "$root/rtl/synchronizer.sv"
      "$root/rtl/apple_bus_read.sv" "$root/rtl/apple_bus_write.sv"
      "$root/rtl/boot_hold.sv" "$root/rtl/kbd_inject.sv"
      "$root/rtl/apple_mmu.sv" "$root/rtl/apple_rom.sv" "$root/rtl/mem_cache.sv"
      "$root/rtl/cache_way_ram.sv" "$root/rtl/mem_client.sv" "$root/rtl/wb_arb.sv")

if [ "$vl" = 1 ]; then
    for high in "${highs[@]}"; do
        obj="$work/obj_vl_$high"
        verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module accel_tb \
            -I"$root/rtl" \
            -GUCODE="\"$root/rtl/cpu65c02_ucode.hex\"" \
            -GPROG="\"$work/accel.hex\"" \
            -GPHI0_HIGH="$high" \
            -Mdir "$obj" "${srcs[@]}" \
            -o accel_tb > "$work/verilator_$high.log" 2>&1 || {
                echo "verilator build failed:" >&2
                tail -20 "$work/verilator_$high.log" >&2; exit 1; }
        echo "== PHI0_HIGH = $high (verilator)"
        "$obj/accel_tb" | tee "$work/accel_tb_vl_$high.log" | grep -v "Verilog \$finish"
        grep -q '^PASS$' "$work/accel_tb_vl_$high.log"
    done
    exit 0
fi
for high in "${highs[@]}"; do
    rm -f "$work/accel_tb.out"
    if ! iverilog -g2012 -I "$root/rtl" -o "$work/accel_tb.out" -s accel_tb \
            -Paccel_tb.UCODE="\"$root/rtl/cpu65c02_ucode.hex\"" \
            -Paccel_tb.PROG="\"$work/accel.hex\"" \
            -Paccel_tb.PHI0_HIGH="$high" \
            "$root/sim/accel_tb.sv" "$root/rtl/cpu65c02.sv" "$root/rtl/accel_seq.sv" "$root/rtl/class_tlb.sv" "$root/rtl/icache_l1.sv" "$root/rtl/l1_front.sv" \
            "$root/rtl/d_front.sv" "$root/rtl/dcache_l1.sv" "$root/rtl/dcache_sa.sv" "$root/rtl/wb_lines.sv" "$root/rtl/event_merge.sv" \
            "$root/rtl/synchronizer.sv" "$root/rtl/apple_bus_read.sv" "$root/rtl/apple_bus_write.sv" \
            "$root/rtl/boot_hold.sv" "$root/rtl/kbd_inject.sv" \
            "$root/rtl/apple_mmu.sv" "$root/rtl/apple_rom.sv" "$root/rtl/mem_cache.sv" \
            "$root/rtl/cache_way_ram.sv" "$root/rtl/mem_client.sv" "$root/rtl/wb_arb.sv" \
            > "$work/iverilog.log" 2>&1; then
        grep -vE "sorry: constant selects|cannot be synthesized" "$work/iverilog.log" >&2
        echo "compile failed" >&2
        exit 1
    fi
    echo "== PHI0_HIGH = $high"
    vvp -N "$work/accel_tb.out" | tee "$work/accel_tb_$high.log" | grep -v "^\$finish"
    grep -q '^PASS$' "$work/accel_tb_$high.log"
done
