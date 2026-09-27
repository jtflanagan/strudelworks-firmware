#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The RISC-V engine core WITH ITS MEMORY SIDE (rtl/gs/rv_mem.sv, an L2 model behind it) against the reference
# (sim/rv_core_main.cpp, sim/rv_ref.h).  Builds the bench when its sources
# changed, then runs it with the arguments given.
#
#   sim/run_rv_core.sh --guest=PROG.bin [--load=ADDR] [--prof] [--delegate-all] ...
#   sim/run_rv_core.sh --build-only
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# DROWS=N builds rv_mem's data row cache at N rows, in a work directory of its own
work="$root/sim/rv_mem_work${DROWS:+_$DROWS}${TN:+_t$TN}"
mkdir -p "$work"
run="$work/obj/rv_mem_run"
srcs=("$root/rtl/gs/rv_pipe.sv" "$root/rtl/gs/rv_fpu.sv" "$root/rtl/gs/rv_mem.sv" "$root/sim/rv_mem_tb.sv" "$root/sim/rv_core_main.cpp" "$root/sim/rv_ref.h")
stale=0
[ -x "$run" ] || stale=1
for s in "${srcs[@]}"; do [ "$s" -nt "$run" ] && stale=1; done
if [ $stale = 1 ]; then
    verilator --cc --exe --build -O2 -Wall -Wno-fatal --public-flat-rw --top-module rv_mem_tb ${DROWS:+-GDROWS=$DROWS} ${TN:+-GTN=$TN} -CFLAGS "-O2 -DRV_MEM -I$root/../berkeley-softfloat-3/source/include" -LDFLAGS "$root/../berkeley-softfloat-3/build/Linux-x86_64-GCC/softfloat.a" \
        -Mdir "$work/obj" "$root/rtl/gs/rv_pipe.sv" "$root/rtl/gs/rv_fpu.sv" "$root/rtl/gs/rv_mem.sv" "$root/sim/rv_mem_tb.sv" "$root/sim/rv_core_main.cpp" \
        -o rv_mem_run > "$work/verilator.log" 2>&1 || {
            echo "build failed:" >&2; grep -E '%Error' "$work/verilator.log" | head -20 >&2; tail -5 "$work/verilator.log" >&2; exit 1; }
fi
[ "${1:-}" = "--build-only" ] && { echo "built $run"; echo "verilator warnings: $(grep -c '%Warning' "$work/verilator.log" || true)"; exit 0; }
exec "$run" "$@"
