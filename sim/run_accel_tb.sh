#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The core faster than the bus: the sequencer between the real core and the
# real driver, the reader on the pins, the MMU shadow, the ROM, the page
# cache, the page client, the arbiter and the boot hold, running sim/accel.s
# against the 128K IIe model of sim/mem_integ_tb.sv - mode 0 (the old
# machine), then reads on the card, then reads and writes, the governor, a
# DMA, the hold, a reset.  ~2 min.  See sim/accel_tb.sv.
#
#   sim/run_accel_tb.sh [PHI0_HIGH ...]    default: 49, then 47 - the sweep of
#                                          the core-to-present margin
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

highs=("$@"); [ ${#highs[@]} -eq 0 ] && highs=(49 47)
for high in "${highs[@]}"; do
    rm -f "$work/accel_tb.out"
    if ! iverilog -g2012 -I "$root/rtl/common" -I "$root/rtl/a2" -o "$work/accel_tb.out" -s accel_tb \
            -Paccel_tb.UCODE="\"$root/rtl/a2/cpu65c02_ucode.hex\"" \
            -Paccel_tb.PROG="\"$work/accel.hex\"" \
            -Paccel_tb.PHI0_HIGH="$high" \
            "$root/sim/accel_tb.sv" "$root/rtl/a2/cpu65c02.sv" "$root/rtl/a2/accel_seq.sv" "$root/rtl/a2/l1i.sv" "$root/rtl/a2/tlb.sv" "$root/rtl/a2/dline.sv" \
            "$root/rtl/common/synchronizer.sv" "$root/rtl/common/apple_bus_read.sv" "$root/rtl/common/apple_bus_write.sv" \
            "$root/rtl/common/boot_hold.sv" \
            "$root/rtl/a2/apple_mmu.sv" "$root/rtl/a2/rom_loader.sv" "$root/rtl/a2/page_cache.sv" \
            "$root/rtl/a2/way_ram.sv" "$root/rtl/common/page_client.sv" "$root/rtl/common/wb_arb.sv" "$root/rtl/common/event_merge.sv" \
            > "$work/iverilog.log" 2>&1; then
        grep -vE "sorry: constant selects|cannot be synthesized" "$work/iverilog.log" >&2
        echo "compile failed" >&2
        exit 1
    fi
    echo "== PHI0_HIGH = $high"
    vvp -N "$work/accel_tb.out" | tee "$work/accel_tb_$high.log" | grep -v "^\$finish"
    grep -q '^PASS$' "$work/accel_tb_$high.log"
done
