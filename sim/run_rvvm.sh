#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The RISC-V engine driven by its 65816 VM (apple/rvvm/rvengine.s) on the
# card's own 65816, alone (sim/rvvm_run_main.cpp).  Builds the runner when its
# sources changed and assembles the VM every time, then runs it with the
# arguments given.
#
#   sim/run_rvvm.sh --guest=PROG.bin [--ref] [--prof] [--trace=N] ...
#   sim/run_rvvm.sh --build-only
#
# The machine is sim/rvvm_sys.sv: the 65816 and the RISC-V engine (its window at
# $EF:FE00).  --engine-vm is accepted and ignored (the engine's VM is the only one).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/rvvm_work"
mkdir -p "$work"

run="$work/obj/rvvm_run"
srcs=("$root/sim/rvvm_run_main.cpp" "$root/sim/rv_ref.h" "$root/sim/rvvm_sys.sv" "$root/rtl/gs/cpu65816.sv"
      "$root/rtl/gs/rv_engine.sv" "$root/rtl/gs/rv_pipe.sv" "$root/rtl/gs/cpu65816_ucode.hex")
stale=0
[ -x "$run" ] || stale=1
for s in "${srcs[@]}"; do [ "$s" -nt "$run" ] && stale=1; done
if [ $stale = 1 ]; then
    python3 "$root/sim/gen_microcode816.py" --check
    verilator --cc --exe --build -O2 -Wno-fatal --public-flat-rw --top-module rvvm_sys \
        -I"$root/rtl/common" -I"$root/rtl/gs" \
        -GUCODE_FILE="\"$root/rtl/gs/cpu65816_ucode.hex\"" \
        -GUCODE0_FILE="\"$root/rtl/gs/cpu65816_ucode0.hex\"" \
        -GUSEQ0_FILE="\"$root/rtl/gs/cpu65816_useq0.hex\"" \
        -CFLAGS -O2 \
        -Mdir "$work/obj" "$root/sim/rvvm_sys.sv" "$root/rtl/gs/cpu65816.sv" \
        "$root/rtl/gs/rv_engine.sv" "$root/rtl/gs/rv_pipe.sv" "$root/sim/rvvm_run_main.cpp" \
        -o rvvm_run > "$work/verilator.log" 2>&1 || {
            echo "build failed:" >&2; tail -30 "$work/verilator.log" >&2; exit 1; }
fi

for t in ca65 ld65; do
    command -v "$t" >/dev/null || { echo "need $t on PATH (cc65)" >&2; exit 1; }
done
vmsrc=rvengine
args=()
for a in "$@"; do
    [ "$a" = "--engine-vm" ] || args+=("$a")
done
set -- "${args[@]+"${args[@]}"}"
ca65 -g -o "$work/$vmsrc.o" "$root/apple/rvvm/$vmsrc.s"
ld65 -C "$root/apple/rvvm/$vmsrc.cfg" -o "$work/$vmsrc.bin" -Ln "$work/$vmsrc.lbl" "$work/$vmsrc.o"

[ "${1:-}" = "--build-only" ] && { echo "built $run and $work/$vmsrc.bin ($(stat -c %s "$work/$vmsrc.bin") bytes)"; exit 0; }
exec "$run" --hex="$root/rtl/gs/cpu65816_ucode.hex" --vm="$work/$vmsrc.bin" "$@"
