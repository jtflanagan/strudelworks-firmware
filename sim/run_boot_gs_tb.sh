#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Boot the IIgs ROM on the card, in simulation: the soft 65816 on the
# dispatcher, apple_mmu at GS = 1, the ROM through the posted-write seam, and
# a per-instruction trace compared against KEGS's by tools/trace_diff816.py.
# See sim/boot_gs_tb.sv and docs/GS.md rung 3.
#
#   sim/run_boot_gs_tb.sh [options]
#     --instrs=N       run length in INSTRUCTIONS (default 20000)
#     --clks=N         hard ceiling in 100 MHz clocks (default 400000000)
#     --mode=N         accel mode (default 2)
#     --target=N       governor target, 8.8 fixed point (0 = unlimited)
#     --rom=FILE       the IIgs ROM (default ../strudelworks-host/assets/apple2gs_rom3.bin)
#     --ref=FILE       the KEGS reference trace (default sim/boot_work/rom3.kegs.trc
#                      if it exists; produce it with tools/kegs/trace_rom.sh).
#                      With a reference, the run is diffed; --ref=none skips it
#     --floor=N        fail unless the traces agree for N collapsed events
#     --trace=FILE     trace output (default sim/boot_work/boot_gs_<tag>.trc)
#     --tag=NAME       names the log and the trace
#     --iverilog       use iverilog (Verilator is the default here)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/boot_work"
mkdir -p "$work"

instrs=20000 clks=400000000 mode=2 target=0 tag=gs vl=1 ref="" floor=""
rom="$root/../strudelworks-host/assets/apple2gs_rom3.bin"
trace=""
for a in "$@"; do
    case "$a" in
        --instrs=*) instrs="${a#*=}" ;;
        --clks=*) clks="${a#*=}" ;;
        --mode=*) mode="${a#*=}" ;;
        --target=*) target="${a#*=}" ;;
        --rom=*) rom="${a#*=}" ;;
        --ref=*) ref="${a#*=}" ;;
        --floor=*) floor="${a#*=}" ;;
        --trace=*) trace="${a#*=}" ;;
        --tag=*) tag="${a#*=}" ;;
        --iverilog) vl=0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done
[ -n "$trace" ] || trace="$work/boot_gs_$tag.trc"
# The reference is 160 MB and needs an X display to make, so it is not in the
# tree: tools/kegs/trace_rom.sh writes it and this is where it is looked for.
if [ -z "$ref" ] && [ -f "$work/rom3.kegs.trc" ]; then ref="$work/rom3.kegs.trc"; fi
if [ "$ref" = none ]; then ref=""; fi
[ -f "$rom" ] || { echo "no ROM at $rom" >&2; exit 2; }

python3 "$root/sim/gen_microcode816.py" --check

# KEGS's one ROM 3 patch, applied at load exactly as the host applies it
# (docs/GS.md: config.c:1262, a SmartPort routine that writes the IWM status
# into $C036).  Only for a 256 KB ROM 3.
size=$(stat -c%s "$rom")
chunks=$(( size / 512 ))
python3 - "$rom" "$work/gsrom_$tag.hex" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
b = bytearray(open(src, 'rb').read())
if len(b) == 262144:
    b[0x357C9] = 0x00
open(dst, 'w').write(''.join('%02x\n' % v for v in b))
PY

srcs=(
    "$root/sim/boot_gs_tb.sv"
    "$root/rtl/cpu65816.sv" "$root/rtl/accel_seq.sv"
    "$root/rtl/synchronizer.sv" "$root/rtl/apple_bus_read.sv" "$root/rtl/apple_bus_write.sv"
    "$root/rtl/gs_io.sv" "$root/rtl/gs_adb.sv" "$root/rtl/gs_clock.sv" "$root/rtl/gs_intc.sv" "$root/rtl/gs_iwm.sv"
    "$root/rtl/apple_mmu.sv" "$root/rtl/rom_loader.sv" "$root/rtl/page_cache.sv"
    "$root/rtl/way_ram.sv" "$root/rtl/page_client.sv" "$root/rtl/wb_arb.sv"
)
echo "== boot_gs_tb: rom=$(basename "$rom") ($chunks chunks) mode=$mode target=$target instrs=$instrs"

if [ "$vl" = 1 ]; then
    obj="$work/obj_gs_$tag"
    verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module boot_gs_tb \
        -I"$root/rtl" \
        -GUCODE="\"$root/rtl/cpu65816_ucode.hex\"" \
        -GUCODE0="\"$root/rtl/cpu65816_ucode0.hex\"" \
        -GUSEQ0="\"$root/rtl/cpu65816_useq0.hex\"" \
        -GROMF="\"$work/gsrom_$tag.hex\"" \
        -GTRACEF="\"$trace\"" \
        -GROM_CHUNKS="$chunks" \
        -GMODE="$mode" \
        -GTARGET="$target" \
        -GMAX_INSTRS="$instrs" \
        -GMAX_CLKS="$clks" \
        -Mdir "$obj" "${srcs[@]}" \
        -o boot_gs_tb > "$work/verilator_gs_$tag.log" 2>&1 || {
            echo "verilator build failed:" >&2; tail -40 "$work/verilator_gs_$tag.log" >&2; exit 1; }
    "$obj/boot_gs_tb" | tee "$work/boot_gs_$tag.log" | grep -v '^\$finish' || true
else
    out="$work/boot_gs_tb.out"
    if ! iverilog -g2012 -I "$root/rtl" -o "$out" -s boot_gs_tb \
            -Pboot_gs_tb.UCODE="\"$root/rtl/cpu65816_ucode.hex\"" \
            -Pboot_gs_tb.UCODE0="\"$root/rtl/cpu65816_ucode0.hex\"" \
            -Pboot_gs_tb.USEQ0="\"$root/rtl/cpu65816_useq0.hex\"" \
            -Pboot_gs_tb.ROMF="\"$work/gsrom_$tag.hex\"" \
            -Pboot_gs_tb.TRACEF="\"$trace\"" \
            -Pboot_gs_tb.ROM_CHUNKS="$chunks" \
            -Pboot_gs_tb.MODE="$mode" \
            -Pboot_gs_tb.TARGET="$target" \
            -Pboot_gs_tb.MAX_INSTRS="$instrs" \
            -Pboot_gs_tb.MAX_CLKS="$clks" \
            "${srcs[@]}" > "$work/iverilog_gs.log" 2>&1; then
        grep -vE "sorry: constant selects|cannot be synthesized" "$work/iverilog_gs.log" >&2
        echo "compile failed" >&2; exit 1
    fi
    vvp -N "$out" | tee "$work/boot_gs_$tag.log" | grep -v '^\$finish'
fi

if [ -n "$ref" ]; then
    [ -f "$ref" ] || { echo "no reference trace at $ref" >&2; exit 2; }
    dargs=()
    if [ -n "$floor" ]; then dargs+=(--floor "$floor"); fi
    python3 "$root/tools/trace_diff816.py" "$trace" "$ref" "${dargs[@]+"${dargs[@]}"}" \
        | tee -a "$work/boot_gs_$tag.log"
    drc=${PIPESTATUS[0]}
    [ "$drc" = 0 ] || { echo "trace_diff816: below the floor" >&2; exit 1; }
fi
grep -q '^PASS$' "$work/boot_gs_$tag.log"
