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
#     --tlb=N          the TLB's entries (default 16; docs/CORE_REFACTOR_65816.md's census lever)
#     --l2=N           the L2's sets (default 16, gs_top's; docs/CORE_REFACTOR_65816.md)
#     --ways=N         ...and its ways a set (default 8)
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
#     --fd525=FILE     a 140K .dsk/.po in 5.25" drive 1 on the IWM (tools/nib525.py
#                      nibblizes it as the host's floppy service does)
#     --fd525-delay=N  clocks the modelled host takes to answer a 5.25" seek (50000)
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
#     --vflags=FLAGS   extra Verilator flags (a -D for an RTL switch)
#     --room=P         the merge's no-room model: P of 256 per clock starts a burst (12; 0 = never)
#     --eng-slice=N    the RISC-V engine's RUN slice at reset, in clocks (4096)
#     --eng-yield=P    force a RUN yield request on P of 256 clocks (0)
#     --eng-tn=N       the engine's page table entries (4)
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

tlbn=16 l2sets=16 l2ways=8 waydefs= fastdma=1 instrs=20000 clks=400000000 mode=2 target=0 ddrlat=12 tag=gs vl=1 ref="" floor="" disktrace=0 lctrace=0 wfrom=0 wto=0 engtrace=0 bram="" keyat=0 keycode=0 keymods=0 keyhold=20000 btnat=0 btnhold=2000000 mirror="" pagewatch=0
rom="$root/../strudelworks-host/assets/apple2gs_rom3.bin"
hdrom="$root/../strudelworks-host/assets/hdc_smartport_gs.bin"
hdv=""
fd35="" fd35delay=50000 fd35trace=0 fd525="" fd525delay=50000
trace=""
for a in "$@"; do
    case "$a" in
        --instrs=*) instrs="${a#*=}" ;;
        --tlb=*) tlbn="${a#*=}" ;;
        --slowdma) fastdma=0 ;;
        --l2=*) l2sets="${a#*=}" ;;
        --ways=*) l2ways="${a#*=}" ;;
        --clks=*) clks="${a#*=}" ;;
        --mode=*) mode="${a#*=}" ;;
        --target=*) target="${a#*=}" ;;
        --ddrlat=*) ddrlat="${a#*=}" ;;
        --rom=*) rom="${a#*=}" ;;
        --hdv=*) hdv="${a#*=}" ;;
        --fd35=*) fd35="${a#*=}" ;;
        --fd525=*) fd525="${a#*=}" ;;
        --fd525-delay=*) fd525delay="${a#*=}" ;;
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
        --vflags=*) vflags="${a#*=}" ;;
        --room=*) roomp="${a#*=}" ;;
        --eng-slice=*) engslice="${a#*=}" ;;
        --eng-yield=*) engyield="${a#*=}" ;;
        --eng-tn=*) engtn="${a#*=}" ;;
        --button=*) IFS=: read -r btnat btnhold <<< "${a#*=}"; btnhold="${btnhold:-2000000}" ;;
        --hold=*) keyhold="${a#*=}" ;;
        --mirror=*) mirror="${a#*=}" ;;
        --page-watch=*) pagewatch="${a#*=}" ;;
        --engine=*) engine_vm="${a#*=}" ;;
        --guest=*) engine_guest="${a#*=}" ;;
        --guest-at=*) engine_at="${a#*=}" ;;
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
has_fd525=0
if [ -n "$fd525" ]; then
    has_fd525=1
    [ -f "$fd525" ] || { echo "no image at $fd525" >&2; exit 2; }
    python3 "$root/tools/nib525.py" "$fd525" --hex "$work/fd525_$tag.hex" --bits --counts "$work/fd525_$tag.counts" > /dev/null
else
    : > "$work/fd525_$tag.hex"; : > "$work/fd525_$tag.counts"
fi
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
    "$root/rtl/gs/cpu65816.sv" "$root/rtl/gs/accel_seq.sv"
    "$root/rtl/gs/l1i.sv" "$root/rtl/gs/iscan.sv" "$root/rtl/gs/l1i_store.sv" "$root/rtl/gs/store_ram.sv" "$root/rtl/gs/tlb.sv" "$root/rtl/gs/l1d.sv" "$root/rtl/gs/bank_census.sv"
    "$root/rtl/common/synchronizer.sv" "$root/rtl/common/apple_bus_read.sv" "$root/rtl/common/apple_bus_write.sv"
    "$root/rtl/gs/gs_io.sv" "$root/rtl/gs/gs_adb.sv" "$root/rtl/gs/gs_doc.sv" "$root/rtl/gs/gs_clock.sv" "$root/rtl/gs/gs_intc.sv" "$root/rtl/gs/gs_iwm.sv"
    "$root/rtl/gs/apple_mmu.sv" "$root/rtl/gs/rom_loader.sv" "$root/rtl/gs/page_cam.sv"
    "$root/rtl/gs/way_ram.sv" "$root/rtl/common/page_client.sv" "$root/rtl/common/wb_arb.sv"
    "$root/rtl/common/hd_card.sv" "$root/rtl/common/ft601_msg_rx.sv" "$root/rtl/common/fd_bank.sv"
    "$root/rtl/gs/rv_engine.sv" "$root/rtl/gs/rv_pipe.sv" "$root/rtl/gs/rv_mem.sv"
)
# THE RISC-V ENGINE (docs/REQ_RVVM.md): --engine=VM.bin (apple/rvvm/rvengine.s,
# assembled for bank $F1) --guest=PROG.bin [--guest-at=ADDR, default $020000]
# runs the guest through the engine instead of booting the ROM.
if [ -n "${engine_vm:-}" ]; then
    [ -f "$engine_vm" ] && [ -f "${engine_guest:-}" ] || { echo "--engine needs the VM and --guest" >&2; exit 2; }
    # the header's guest pc (+12) and sp (+16): the guest's load address, and a
    # stack top in RAM ($80-$DF is VOID until the engine's memory work lands)
    engine_at_dec=$(( ${engine_at:-0x020000} ))
    python3 - "$engine_vm" "$work/engine_vm_$tag.bin" "$engine_at_dec" <<'PY'
import sys, struct
b = bytearray(open(sys.argv[1], 'rb').read())
b[12:16] = struct.pack('<I', int(sys.argv[3]))
b[16:20] = struct.pack('<I', 0x7E0000)
open(sys.argv[2], 'wb').write(b)
PY
    xxd -p -c1 "$work/engine_vm_$tag.bin" > "$work/engine_vm_$tag.hex"
    xxd -p -c1 "$engine_guest" > "$work/engine_guest_$tag.hex"
    engine_on=1
    engine_at_dec=$(( ${engine_at:-0x020000} ))
    # the VM's entry: its header's offset at +6, in bank $F1
    engine_entry_dec=$(( 0xF10000 + $(od -An -tu2 -j6 -N2 "$engine_vm") ))
    ref=none
fi
echo "== boot_gs_tb: rom=$(basename "$rom") ($chunks chunks) mode=$mode target=$target instrs=$instrs"

if [ "$vl" = 1 ]; then
    obj="$work/obj_gs_$tag"
    verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module boot_gs_tb ${vflags:-} \
        -I"$root/rtl/common" -I"$root/rtl/gs" \
        -GUCODE="\"$root/rtl/gs/cpu65816_ucode.hex\"" \
        -GUCODE0="\"$root/rtl/gs/cpu65816_ucode0.hex\"" \
        -GUSEQ0="\"$root/rtl/gs/cpu65816_useq0.hex\"" \
        -GROMF="\"$work/gsrom_$tag.hex\"" \
        -GTRACEF="\"$trace\"" \
        -GROM_CHUNKS="$chunks" \
        -GMODE="$mode" \
        -GTARGET="$target" \
        -GDDR_LAT="$ddrlat" \
        -GMAX_INSTRS="$instrs" \
        -GTLB_N="$tlbn" \
        -GL2_SETS="$l2sets" -GL2_WAYS="$l2ways" $waydefs -GFAST_DMA="$fastdma" -GROOM_P="${roomp:-12}" -GENG_SLICE="${engslice:-4096}" -GENG_YIELD="${engyield:-0}" -GENG_TN="${engtn:-4}" \
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
        -GENGINE="${engine_on:-0}" -GXROMF="\"$work/engine_vm_$tag.hex\"" -GGUESTF="\"$work/engine_guest_$tag.hex\"" \
        -GGUEST_AT="${engine_at_dec:-131072}" -GVM_ENTRY="${engine_entry_dec:-15794176}" \
        -GKEY_AT="$keyat" -GKEY_CODE="$keycode" -GKEY_MODS="$keymods" \
        -GBTN_AT="$btnat" -GBTN_HOLD="$btnhold" \
        -GKEY_HOLD="$keyhold" -GPAGE_WATCH="${pagewatch:-0}" \
        -GOPSF="\"${mirror:+$mirror/ops.bin}\"" -GPAGESF="\"${mirror:+$mirror/pages.bin}\"" \
        -GADB_KEYMAP="\"$root/rtl/gs/adb_keymap.hex\"" \
        -GBRAMF="\"$work/gsbram_$tag.hex\"" -GHAS_BRAM="$has_bram" \
        -GFD35F="\"$work/fd35_$tag.hex\"" -GFD35_COUNTSF="\"$work/fd35_$tag.counts\"" \
        -GHAS_FD35="$has_fd35" -GFD35_DELAY="$fd35delay" -GFD35_TRACE="$fd35trace" \
        -GFD525F="\"$work/fd525_$tag.hex\"" -GFD525_COUNTSF="\"$work/fd525_$tag.counts\"" -GHAS_FD525="$has_fd525" -GFD525_DELAY="$fd525delay" \
        -Mdir "$obj" "${srcs[@]}" \
        -o boot_gs_tb > "$work/verilator_gs_$tag.log" 2>&1 || {
            echo "verilator build failed:" >&2; tail -40 "$work/verilator_gs_$tag.log" >&2; exit 1; }
    "$obj/boot_gs_tb" | tee "$work/boot_gs_$tag.log" | grep -v '^\$finish' || true
else
    out="$work/boot_gs_tb.out"
    if ! iverilog -g2012 -I "$root/rtl/common" -I "$root/rtl/gs" -o "$out" -s boot_gs_tb \
            -Pboot_gs_tb.UCODE="\"$root/rtl/gs/cpu65816_ucode.hex\"" \
            -Pboot_gs_tb.UCODE0="\"$root/rtl/gs/cpu65816_ucode0.hex\"" \
            -Pboot_gs_tb.USEQ0="\"$root/rtl/gs/cpu65816_useq0.hex\"" \
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

if [ -n "$ref" ] && [ "$ref" != none ]; then
    [ -f "$ref" ] || { echo "no reference trace at $ref" >&2; exit 2; }
    dargs=()
    if [ -n "$floor" ]; then dargs+=(--floor "$floor"); fi
    python3 "$root/tools/trace_diff816.py" "$trace" "$ref" "${dargs[@]+"${dargs[@]}"}" \
        | tee -a "$work/boot_gs_$tag.log"
    drc=${PIPESTATUS[0]}
    [ "$drc" = 0 ] || { echo "trace_diff816: below the floor" >&2; exit 1; }
fi
grep -q '^PASS$' "$work/boot_gs_$tag.log"
