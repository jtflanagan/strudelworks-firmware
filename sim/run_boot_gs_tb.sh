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
#     --hdv=FILE       the SmartPort image to boot from (slot 7)
#     --fd35=FILE      an 800K .po in the 3.5" drive on the IWM (tools/nib35.py
#                      nibblizes it; docs/IWM35.md).  The FTA demos boot from
#                      here: --fd35=XMAS_DEMO.po --instrs=16000000
#                      --clks=1200000000 sees the demo launch - the ROM's
#                      scan times out on slot 6 first, then the loader turns
#                      the disk at its real rate (the KEGS reference of that
#                      boot is sim/boot_work/xmas/xmas.kegs.trc; the diff is
#                      blind past the slot scan, as always)
#     --fd35-delay=N   clocks the modelled host takes to answer a seek (50000)
#     --fd35-trace=N   name the first N IWM accesses with the byte and the drive's state
#     --hdrom=FILE     its slot ROM (default the IIgs's,
#                      ../strudelworks-host/assets/hdc_smartport_gs.bin; the //e's
#                      is a different firmware and speaks a different FIFO)
#     --disktrace      name every $C0Fx write and every $40-$47 write from the
#                      first EXECUTE on (docs/GS.md rung 3e)
#     --lctrace        name every $C08x touch with the state it left
#     --watch=A:B      print every CPU cycle between instructions A and B
#     --engtrace       name every page-cache fill and victim in the ROM's pages
#     --mirror=DIR     write DIR/ops.bin and DIR/pages.bin for the host's
#                      mirror to be replayed against (tests/gs_replay_test)
#     --hold=N         hold the key N clocks (default 20000); tens of frames
#                      and the ADB micro's auto-repeat should fire
#     --button=AT[:HOLD]  hold the MOUSE BUTTON (PB0) down at instruction AT
#                      for HOLD clocks.  The XMAS demo's "CLICK MOUSE" prompt
#                      does NOT take a key - it polls $C061 for the button.
#     --key=CODE:AT[:MODS]  press an ADB keycode at instruction AT, with the
#                      modifier byte MODS in $C025's order (1 shift, 2 ctrl,
#                      4 caps, $40 option, $80 command)
#     --bram=SLOTS     ship a battery RAM naming these slots "Your Card"
#                      (tools/gs_bram.py), e.g. --bram=6,7 or --bram=none.
#                      OFF by default: KEGS boots with an all-zero battery RAM,
#                      so shipping one parts the two machines at once
#     --iverilog       use iverilog (Verilator is the default here)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/boot_work"
mkdir -p "$work"

instrs=20000 clks=400000000 mode=2 target=0 ddrlat=12 tag=gs vl=1 ref="" floor="" disktrace=0 lctrace=0 wfrom=0 wto=0 engtrace=0 bram="" keyat=0 keycode=0 keymods=0 keyhold=20000 btnat=0 btnhold=2000000 mirror="" pagewatch=0
rom="$root/../strudelworks-host/assets/apple2gs_rom3.bin"
hdrom="$root/../strudelworks-host/assets/hdc_smartport_gs.bin"
hdv=""
fd35="" fd35delay=50000 fd35trace=0
trace=""
for a in "$@"; do
    case "$a" in
        --instrs=*) instrs="${a#*=}" ;;
        --clks=*) clks="${a#*=}" ;;
        --mode=*) mode="${a#*=}" ;;
        --target=*) target="${a#*=}" ;;
        --ddrlat=*) ddrlat="${a#*=}" ;;
        --rom=*) rom="${a#*=}" ;;
        --hdv=*) hdv="${a#*=}" ;;
        --fd35=*) fd35="${a#*=}" ;;
        --fd35-delay=*) fd35delay="${a#*=}" ;;
        --fd35-trace=*) fd35trace="${a#*=}" ;;
        --hdrom=*) hdrom="${a#*=}" ;;
        --ref=*) ref="${a#*=}" ;;
        --floor=*) floor="${a#*=}" ;;
        --trace=*) trace="${a#*=}" ;;
        --tag=*) tag="${a#*=}" ;;
        --disktrace) disktrace=1 ;;
        --lctrace) lctrace=1 ;;
        --engtrace) engtrace=1 ;;
        --bram=*) bram="${a#*=}" ;;
        --key=*) IFS=: read -r keycode keyat keymods <<< "${a#*=}"; keymods="${keymods:-0}" ;;
        --button=*) IFS=: read -r btnat btnhold <<< "${a#*=}"; btnhold="${btnhold:-2000000}" ;;
        --hold=*) keyhold="${a#*=}" ;;
        --mirror=*) mirror="${a#*=}" ;;
        --page-watch=*) pagewatch="${a#*=}" ;;
        --watch=*) wfrom="${a#*=}"; wto="${wfrom#*:}"; wfrom="${wfrom%%:*}" ;;
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
# AS SHIPPED: KEGS's $357C9 SmartPort patch is no longer copied (the ROM's
# self-test checksums the ROM and failed on it - docs/GS.md rung 4's gate);
# the host loads the same bytes (src/fd_service.cpp load_sys_rom).
open(dst, 'w').write(''.join('%02x\n' % v for v in b))
PY

# The slot-7 image.  Without one the bench still runs - the ROM scans, finds
# no card, and sits in its retry loop - so this is optional and the run says
# which it did.
blocks=1
has_hdv=0
if [ -n "$hdv" ]; then
    has_hdv=1
    [ -f "$hdv" ] || { echo "no image at $hdv" >&2; exit 2; }
    hsize=$(stat -c%s "$hdv")
    blocks=$(( (hsize + 511) / 512 ))
    { xxd -p -c1 "$hdv"; head -c $((blocks * 512 - hsize)) /dev/zero | xxd -p -c1; } \
        > "$work/hdv_$tag.hex"
else
    : > "$work/hdv_$tag.hex"
fi
# The 3.5" image, nibblized track by track as the host will do it.
has_fd35=0
if [ -n "$fd35" ]; then
    has_fd35=1
    [ -f "$fd35" ] || { echo "no image at $fd35" >&2; exit 2; }
    python3 "$root/tools/nib35.py" "$fd35" --hex "$work/fd35_$tag.hex" --counts "$work/fd35_$tag.counts" > /dev/null
else
    : > "$work/fd35_$tag.hex"; : > "$work/fd35_$tag.counts"
fi
[ -z "$mirror" ] || mkdir -p "$mirror"
has_bram=0
if [ -n "$bram" ] && [ "$bram" != none ]; then
    has_bram=1
    python3 "$root/tools/gs_bram.py" --slots "$bram" --hex "$work/gsbram_$tag.hex"
else
    : > "$work/gsbram_$tag.hex"
fi
[ -f "$hdrom" ] || { echo "no slot ROM at $hdrom" >&2; exit 2; }
# WHICH ROM decides the command FIFO's shape, so the host model is told.  The
# two are different firmware (the host's firmware/hdc_smartport_gs.s header
# says why); named by the file, so pointing --hdrom at the //e's ROM tests
# the //e's protocol on this bench too.
case "$hdrom" in
    *_gs.bin) gs_hd_rom=1 ;;
    *)        gs_hd_rom=0 ;;
esac
xxd -p -c1 "$hdrom" > "$work/hdrom.hex"

srcs=(
    "$root/sim/boot_gs_tb.sv"
    "$root/rtl/cpu65816.sv" "$root/rtl/accel_seq.sv"
    "$root/rtl/iline.sv" "$root/rtl/iscan.sv" "$root/rtl/dline.sv" "$root/rtl/bank_census.sv"
    "$root/rtl/synchronizer.sv" "$root/rtl/apple_bus_read.sv" "$root/rtl/apple_bus_write.sv"
    "$root/rtl/gs_io.sv" "$root/rtl/gs_adb.sv" "$root/rtl/gs_doc.sv" "$root/rtl/gs_clock.sv" "$root/rtl/gs_intc.sv" "$root/rtl/gs_iwm.sv"
    "$root/rtl/apple_mmu.sv" "$root/rtl/rom_loader.sv" "$root/rtl/page_cache.sv"
    "$root/rtl/way_ram.sv" "$root/rtl/page_client.sv" "$root/rtl/wb_arb.sv"
    "$root/rtl/hd_card.sv" "$root/rtl/ft601_msg_rx.sv" "$root/rtl/fd_bank.sv"
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
        -GDDR_LAT="$ddrlat" \
        -GMAX_INSTRS="$instrs" \
        -GMAX_CLKS="$clks" \
        -GHDROMF="\"$work/hdrom.hex\"" \
        -GGS_HD_ROM=$gs_hd_rom \
        -GHDVF="\"$work/hdv_$tag.hex\"" \
        -GHDV_BLOCKS="$blocks" \
        -GHAS_HDV="$has_hdv" \
        -GDISK_TRACE="$disktrace" \
        -GLC_TRACE="$lctrace" \
        -GWATCH_FROM="$wfrom" -GWATCH_TO="$wto" \
        -GENG_TRACE="$engtrace" \
        -GKEY_AT="$keyat" -GKEY_CODE="$keycode" -GKEY_MODS="$keymods" \
        -GBTN_AT="$btnat" -GBTN_HOLD="$btnhold" \
        -GKEY_HOLD="$keyhold" -GPAGE_WATCH="${pagewatch:-0}" \
        -GOPSF="\"${mirror:+$mirror/ops.bin}\"" -GPAGESF="\"${mirror:+$mirror/pages.bin}\"" \
        -GADB_KEYMAP="\"$root/rtl/adb_keymap.hex\"" \
        -GBRAMF="\"$work/gsbram_$tag.hex\"" -GHAS_BRAM="$has_bram" \
        -GFD35F="\"$work/fd35_$tag.hex\"" -GFD35_COUNTSF="\"$work/fd35_$tag.counts\"" \
        -GHAS_FD35="$has_fd35" -GFD35_DELAY="$fd35delay" -GFD35_TRACE="$fd35trace" \
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
