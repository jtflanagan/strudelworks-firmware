#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# A GS/OS application backed by RISC-V, its lifecycle in sim (docs/RVV2_INTEROP.md
# rungs I2-I5): the application (apple/rvvm/build_app.sh: the stub with its header,
# its program) entered as GS/OS's loader would, the runtime ($F1,
# apple/rvvm/rvengine.s) on the card's 65816 and the RISC-V engine with its own
# memory side (rv_mem on the card's map, sim/l2_model.h behind it, 32 MB), GS/OS
# played by sim/rvvm_run_main.cpp's stand-in - in the cases the application lists
# (apple/rvvm/APP/bench.cases): RVTEST a clean machine, a dead application left in
# the registration table to reclaim, and no program file, each launched twice on
# the one engine (nothing resets it in between); SPLASH its picture on mode 1.
#
#   sim/run_rv_app.sh [APP, default rvtest] [RUNNER ARGS...]   (after the case's: they win)
# The cases are the application's own: apple/rvvm/APP/bench.cases.
# A run is stopped at 200M cycles: a runtime that loses its way would otherwise run
# to the runner's 2G.  The application's resources (APP.res) are GS/OS's files too;
# RVTEST exits $100 | the key it was given.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:-rvtest}"
shift || true
up="$(echo "$app" | tr a-z A-Z)"
work="$root/sim/rvvm_work/app"
mkdir -p "$work"
"$root/sim/run_rvvm.sh" --build-only > /dev/null            # the runtime (and its RISC-V code)
# the runner with the engine's memory side: its own model, its own object directory
run="$work/obj/rvvm_run"
srcs=("$root/sim/rvvm_run_main.cpp" "$root/sim/rv_ref.h" "$root/sim/l2_model.h" "$root/sim/rvvm_sys.sv"
      "$root/rtl/gs/cpu65816.sv" "$root/rtl/gs/rv_engine.sv" "$root/rtl/gs/rv_pipe.sv" "$root/rtl/gs/rv_fpu.sv" "$root/rtl/gs/rv_mem.sv"
      "$root/rtl/gs/cpu65816_ucode.hex")
stale=0
[ -x "$run" ] || stale=1
for s in "${srcs[@]}"; do [ "$s" -nt "$run" ] && stale=1; done
if [ $stale = 1 ]; then
    verilator --cc --exe --build -O2 -Wno-fatal --public-flat-rw --top-module rvvm_sys \
        -I"$root/rtl/common" -I"$root/rtl/gs" \
        -GUCODE_FILE="\"$root/rtl/gs/cpu65816_ucode.hex\"" \
        -GUCODE0_FILE="\"$root/rtl/gs/cpu65816_ucode0.hex\"" \
        -GUSEQ0_FILE="\"$root/rtl/gs/cpu65816_useq0.hex\"" \
        -GMEM=1 -GAW=25 -CFLAGS "-O2 -DRVVM_MEM=1 -I$root/../berkeley-softfloat-3/source/include" -LDFLAGS "$root/../berkeley-softfloat-3/build/Linux-x86_64-GCC/softfloat.a" \
        -Mdir "$work/obj" "$root/sim/rvvm_sys.sv" "$root/rtl/gs/cpu65816.sv" \
        "$root/rtl/gs/rv_engine.sv" "$root/rtl/gs/rv_pipe.sv" "$root/rtl/gs/rv_fpu.sv" "$root/rtl/gs/rv_mem.sv" "$root/sim/rvvm_run_main.cpp" \
        -o rvvm_run > "$work/verilator.log" 2>&1 || {
            echo "build failed:" >&2; tail -30 "$work/verilator.log" >&2; exit 1; }
fi
"$root/apple/rvvm/build_app.sh" "$app" "$work"
files=()
while read -r f; do [ -n "$f" ] && files+=(--file="9:$f=$work/$f"); done < "$work/$up.res"
args=(--hex="$root/rtl/gs/cpu65816_ucode.hex" --vm="$root/sim/rvvm_work/rvengine.bin" --app="$work/$up.stub"
      --max-cycles=200000000 "${files[@]}")
rc=0
cases="$root/apple/rvvm/$app/bench.cases"
[ -f "$cases" ] || { echo "no $cases" >&2; exit 1; }
while read -r name rest; do
    case "$name" in ''|'#'*) continue;; esac
    eval "extra=($rest)"                        # $work and $up, as the cases file writes them
    if "$run" "${args[@]}" "${extra[@]}" "$@" < /dev/null > "$work/$app-$name.log" 2>&1; then
        echo "PASS rv-app-$app-$name: $(grep -m1 'trace step' "$work/$app-$name.log" | sed 's/^app: trace //')"
        grep -E "the program's report|the picture in" "$work/$app-$name.log" | sed 's/^app: /    /' || true
    else
        rc=1
        echo "FAIL rv-app-$app-$name"
        sed 's/^/    /' "$work/$app-$name.log" | tail -25
    fi
done < "$cases"
exit $rc
