#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# A GS/OS application backed by RISC-V, its lifecycle in sim (docs/RVV2_INTEROP.md
# rung I2): the stub with an application's header (apple/rvvm/stub + apple/rvvm/APP/app.inc)
# entered as GS/OS's loader would, the runtime ($F1, apple/rvvm/rvengine.s) on the
# card's 65816 and the RISC-V engine, GS/OS played by sim/rvvm_run_main.cpp's
# stand-in - twice: on a clean machine, and with a dead application left in the
# registration table to reclaim (--stale).
#
#   sim/run_rv_app.sh [APP, default splash] [RUNNER ARGS...]
# A run is stopped at 50M cycles (the lifecycle takes some 25K): a runtime that
# loses its way would otherwise run to the runner's 2G.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:-splash}"
shift || true
work="$root/sim/rvvm_work/app"
mkdir -p "$work"
"$root/sim/run_rvvm.sh" --build-only > /dev/null
printf 'MEMORY { S: start = $0000, size = $10000, file = %%O; }\nSEGMENTS { CODE: load = S, type = ro; }\n' > "$work/stub.cfg"
ca65 -I "$root/apple/rvvm/$app" -o "$work/$app.o" "$root/apple/rvvm/stub/stub.s"
ld65 -C "$work/stub.cfg" -o "$work/$app.bin" "$work/$app.o"
run="$root/sim/rvvm_work/obj/rvvm_run"
args=(--hex="$root/rtl/gs/cpu65816_ucode.hex" --vm="$root/sim/rvvm_work/rvengine.bin" --app="$work/$app.bin"
      --max-cycles=50000000 "$@")
rc=0
for extra in "" --stale; do
    if "$run" "${args[@]}" $extra > "$work/$app$extra.log" 2>&1; then
        echo "PASS rv-app-$app${extra:+ $extra}: $(grep -m1 'the low block' "$work/$app$extra.log" | sed 's/^app: //'); $(grep -m1 'deepest' "$work/$app$extra.log" | sed 's/^app: //')"
    else
        rc=1
        echo "FAIL rv-app-$app${extra:+ $extra}"
        sed 's/^/    /' "$work/$app$extra.log" | tail -25
    fi
done
exit $rc
