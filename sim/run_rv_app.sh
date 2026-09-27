#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# A GS/OS application backed by RISC-V, its lifecycle in sim (docs/RVV2_INTEROP.md
# rungs I2-I3): the application (apple/rvvm/build_app.sh: the stub with its header,
# its program) entered as GS/OS's loader would, the runtime ($F1,
# apple/rvvm/rvengine.s) on the card's 65816 and the RISC-V engine with its own
# memory side (rv_mem on the card's map, sim/l2_model.h behind it, 32 MB), GS/OS
# played by sim/rvvm_run_main.cpp's stand-in - three cases, each launched twice on the one
# engine (as the Finder would; nothing resets it in between): a clean machine, with
# a dead application left in the registration table to reclaim (--stale), and with
# no program file (the runtime's -5, everything undone).
#
#   sim/run_rv_app.sh [APP, default splash] [RUNNER ARGS...]
# A run is stopped at 50M cycles: a runtime that loses its way would otherwise run
# to the runner's 2G.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:-splash}"
shift || true
up="$(echo "$app" | tr a-z A-Z)"
work="$root/sim/rvvm_work/app"
mkdir -p "$work"
"$root/sim/run_rvvm.sh" --build-only > /dev/null            # the runtime (and its RISC-V code)
# the runner with the engine's memory side: its own model, its own object directory
run="$work/obj/rvvm_run"
srcs=("$root/sim/rvvm_run_main.cpp" "$root/sim/rv_ref.h" "$root/sim/l2_model.h" "$root/sim/rvvm_sys.sv"
      "$root/rtl/gs/cpu65816.sv" "$root/rtl/gs/rv_engine.sv" "$root/rtl/gs/rv_pipe.sv" "$root/rtl/gs/rv_mem.sv"
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
        -GMEM=1 -GAW=25 -CFLAGS "-O2 -DRVVM_MEM=1" \
        -Mdir "$work/obj" "$root/sim/rvvm_sys.sv" "$root/rtl/gs/cpu65816.sv" \
        "$root/rtl/gs/rv_engine.sv" "$root/rtl/gs/rv_pipe.sv" "$root/rtl/gs/rv_mem.sv" "$root/sim/rvvm_run_main.cpp" \
        -o rvvm_run > "$work/verilator.log" 2>&1 || {
            echo "build failed:" >&2; tail -30 "$work/verilator.log" >&2; exit 1; }
fi
"$root/apple/rvvm/build_app.sh" "$app" "$work"
args=(--hex="$root/rtl/gs/cpu65816_ucode.hex" --vm="$root/sim/rvvm_work/rvengine.bin" --app="$work/$up.stub"
      --max-cycles=50000000 "$@")
rc=0
while read -r name extra; do
    if "$run" "${args[@]}" $extra > "$work/$app-$name.log" 2>&1; then
        echo "PASS rv-app-$app-$name: $(grep -m1 'trace step' "$work/$app-$name.log" | sed 's/^app: trace //')"
    else
        rc=1
        echo "FAIL rv-app-$app-$name"
        sed 's/^/    /' "$work/$app-$name.log" | tail -25
    fi
done <<CASES
clean --image=$work/$up.RV --launches=2
stale --image=$work/$up.RV --stale --launches=2
noimage --expect-code=-5 --launches=2
CASES
exit $rc
