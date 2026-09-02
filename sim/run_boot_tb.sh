#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Boot a real .hdv in simulation: the whole accelerated memory path, the real
# 16K IIe ROM, hd_card in its slot with the testbench playing the host, and a
# per-op trace written for cross-checkout divergence hunting.  See
# sim/boot_tb.sv; tools/trace_diff.py compares two traces.
#
#   sim/run_boot_tb.sh IMAGE.hdv [options]
#     --mode=N         accel mode (default 2)
#     --target=N       governor target in 8.8 fixed point, decimal (0 = unlimited)
#     --swint-off      the keyboard not internalized: dummies at $0000, $C00x on the bus
#     --slot=N         the hard disk's slot (default 7)
#     --cycles=N       run length in BUS CYCLES (default 2000000: ~2 s at 1x)
#     --clks=N         hard ceiling in 100 MHz clocks (default 400000000)
#     --verilator      build and run under Verilator --timing (much faster)
#     --trace=FILE     trace output (default sim/boot_work/boot_<tag>.trc)
#     --tag=NAME       names the log and trace
#     --rom=FILE       motherboard ROM (default ../strudelworks-host/assets/Apple2e_Enhanced.rom)
#     --hdrom=FILE     slot ROM (default ../strudelworks-host/assets/hdc_smartport.bin)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/boot_work"
mkdir -p "$work"

[ $# -ge 1 ] || { echo "usage: $(basename "$0") IMAGE.hdv [--mode=N ...]" >&2; exit 2; }
hdv="$1"; shift
[ -f "$hdv" ] || { echo "no such image: $hdv" >&2; exit 2; }

mode=2 target=0 slot=7 swint=0 cyclim=2000000 clks=400000000 tag=run vl=0
rom="$root/../strudelworks-host/assets/Apple2e_Enhanced.rom"
hdrom="$root/../strudelworks-host/assets/hdc_smartport.bin"
trace=""
for a in "$@"; do
    case "$a" in
        --mode=*) mode="${a#*=}" ;;
        --target=*) target="${a#*=}" ;;
        --swint-off) swint=1 ;;
        --slot=*) slot="${a#*=}" ;;
        --cycles=*) cyclim="${a#*=}" ;;
        --clks=*) clks="${a#*=}" ;;
        --verilator) vl=1 ;;
        --trace=*) trace="${a#*=}" ;;
        --tag=*) tag="${a#*=}" ;;
        --rom=*) rom="${a#*=}" ;;
        --hdrom=*) hdrom="${a#*=}" ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done
[ -n "$trace" ] || trace="$work/boot_$tag.trc"
[ -f "$rom" ] || { echo "no ROM at $rom" >&2; exit 2; }
[ -f "$hdrom" ] || { echo "no slot ROM at $hdrom" >&2; exit 2; }

python3 "$root/sim/gen_microcode.py" --check

# Hex images for $readmemh.  The hdv pads to a whole block.
size=$(stat -c%s "$hdv")
blocks=$(( (size + 511) / 512 ))
xxd -p -c1 "$rom" > "$work/rom.hex"
xxd -p -c1 "$hdrom" > "$work/hdrom.hex"
{ xxd -p -c1 "$hdv"; head -c $((blocks * 512 - size)) /dev/zero | xxd -p -c1; } > "$work/hdv_$tag.hex"

srcs=(
    "$root/sim/boot_tb.sv"
    "$root/rtl/cpu65c02.sv" "$root/rtl/accel_seq.sv"
    "$root/rtl/iline.sv" "$root/rtl/iscan.sv" "$root/rtl/dline.sv"
    "$root/rtl/synchronizer.sv" "$root/rtl/apple_bus_read.sv" "$root/rtl/apple_bus_write.sv"
    "$root/rtl/boot_hold.sv"
    "$root/rtl/apple_mmu.sv" "$root/rtl/apple_rom.sv" "$root/rtl/page_cache.sv"
    "$root/rtl/bank_ram.sv" "$root/rtl/page_client.sv" "$root/rtl/wb_arb.sv"
    "$root/rtl/hd_card.sv" "$root/rtl/slot_switches.sv"
    "$root/rtl/ft601_msg_rx.sv"
)
echo "== boot_tb: $(basename "$hdv") mode=$mode target=$target slot=$slot cycles=$cyclim clks=$clks vl=$vl"

if [ "$vl" = 1 ]; then
    obj="$work/obj_$tag"
    verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module boot_tb \
        -I"$root/rtl" \
        -GUCODE="\"$root/rtl/cpu65c02_ucode.hex\"" \
        -GROMF="\"$work/rom.hex\"" \
        -GHDROMF="\"$work/hdrom.hex\"" \
        -GHDVF="\"$work/hdv_$tag.hex\"" \
        -GTRACEF="\"$trace\"" \
        -GHDV_BLOCKS="$blocks" \
        -GMODE="$mode" \
        -GTARGET="$target" \
        -GSWINT_DIS="$swint" \
        -GHD_SLOT="$slot" \
        -GMAX_CYCLES="$cyclim" \
        -GMAX_CLKS="$clks" \
        -Mdir "$obj" "${srcs[@]}" \
        -o boot_tb > "$work/verilator_$tag.log" 2>&1 || {
            echo "verilator build failed:" >&2; tail -30 "$work/verilator_$tag.log" >&2; exit 1; }
    /usr/bin/time -v "$obj/boot_tb" 2> "$work/time_$tag.log" | tee "$work/boot_$tag.log" | grep -v '^\$finish' || true
    grep -E "Elapsed|Maximum resident" "$work/time_$tag.log" || true
else
    out="$work/boot_tb.out"
    if ! iverilog -g2012 -I "$root/rtl" -o "$out" -s boot_tb \
            -Pboot_tb.UCODE="\"$root/rtl/cpu65c02_ucode.hex\"" \
            -Pboot_tb.ROMF="\"$work/rom.hex\"" \
            -Pboot_tb.HDROMF="\"$work/hdrom.hex\"" \
            -Pboot_tb.HDVF="\"$work/hdv_$tag.hex\"" \
            -Pboot_tb.TRACEF="\"$trace\"" \
            -Pboot_tb.HDV_BLOCKS="$blocks" \
            -Pboot_tb.MODE="$mode" \
            -Pboot_tb.TARGET="$target" \
            -Pboot_tb.SWINT_DIS="$swint" \
            -Pboot_tb.HD_SLOT="$slot" \
            -Pboot_tb.MAX_CYCLES="$cyclim" \
            -Pboot_tb.MAX_CLKS="$clks" \
            "${srcs[@]}" \
            > "$work/iverilog.log" 2>&1; then
        grep -vE "sorry: constant selects|cannot be synthesized" "$work/iverilog.log" >&2
        echo "compile failed" >&2
        exit 1
    fi
    vvp -N "$out" | tee "$work/boot_$tag.log" | grep -v '^\$finish'
fi
grep -q '^PASS$' "$work/boot_$tag.log"
