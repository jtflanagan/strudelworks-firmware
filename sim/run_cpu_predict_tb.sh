#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The split I/D front and the late-cancel contract, on the Klaus suites.
#
# sim/run_cpu_tb.sh proves the core computes; this proves the properties the
# L1 caches lean on: a cancelled clock consumes nothing (it is fed garbage on
# din to make sure), a cancelled cycle retries identically, and i_pred names
# the address of every program-stream fetch before it happens.  See
# sim/cpu_predict_main.cpp for the contract statement.
#
# Three regimes per suite:
#   stall 0        - every clock advances: the 1-clock-per-cycle ceiling
#   stall 100      - scattered single-clock cancels: redirects and D misses
#   stall 400 + bursts - miss-latency-shaped holds, the ugly case
#
# ~1 minute for all six runs.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tests="$root/third_party/6502_tests/bin_files"
work="$root/sim/cpu_predict_work"

if [ ! -d "$tests" ]; then
    echo "Test images missing.  Run third_party/fetch_6502_tests.sh first." >&2
    exit 1
fi

mkdir -p "$work"

python3 "$root/sim/gen_microcode.py" --check

verilator --cc --exe --build -O2 -Wno-fatal --top-module cpu65c02 \
    -I"$root/rtl/common" -I"$root/rtl/a2" \
    -GUCODE_FILE="\"$root/rtl/a2/cpu65c02_ucode.hex\"" \
    -Mdir "$work/obj_dir" "$root/rtl/a2/cpu65c02.sv" "$root/sim/cpu_predict_main.cpp" \
    -o cpu_predict_sim > "$work/verilator.log" 2>&1 || {
        echo "build failed:" >&2; tail -20 "$work/verilator.log" >&2; exit 1; }

find_success() {
    awk '/S U C C E S S/ {hot=1; next}
         hot && /^[0-9a-f]{4} :/ {print substr($0,1,4); exit}' "$1"
}

run_one() {
    local name="$1" start="$2" dir="$3"; shift 3
    local bin="$dir/$name.bin" lst="$dir/$name.lst"
    local hex="$work/$name.hex" success rc=0 out trap line

    success="$(find_success "$lst")"
    [ -n "$success" ] || { echo "could not find success trap in $lst" >&2; exit 1; }

    [ -f "$hex" ] || od -An -v -tx1 -w1 "$bin" | tr -d ' ' > "$hex"

    echo "=============================================================="
    out="$("$work/obj_dir/cpu_predict_sim" --hex="$hex" --start="$start" \
          --success="$success" "$@")" || rc=$?
    echo "$out"
    [ $rc -eq 0 ] && return 0

    trap="$(sed -n 's/^TRAP=//p' <<<"$out")"
    if [ -n "$trap" ] && [ "$trap" != "none" ] && [ "$trap" != "stp" ] \
       && [ "$trap" != "contract" ]; then
        echo
        echo "--- $name.lst around \$$trap ---------------------------------"
        line="$(grep -n -m1 "^$trap :" "$lst" | cut -d: -f1 || true)"
        if [ -n "$line" ]; then
            sed -n "$((line > 24 ? line - 24 : 1)),$((line + 2))p" "$lst"
        else
            echo "(address not found in listing)"
        fi
    fi
    return 1
}

base_dir="$root/sim/cpu_work/base_test"
if [ ! -f "$base_dir/65C02_base_opcodes_test.bin" ]; then
    bash "$root/third_party/build_base_65c02_test.sh"
fi

fail=0
for cfg in "--stall=0" "--stall=100 --seed=2" "--stall=400 --burst=300 --seed=3"; do
    # shellcheck disable=SC2086
    run_one 6502_functional_test    0400 "$tests"   $cfg || fail=1
    # shellcheck disable=SC2086
    run_one 65C02_base_opcodes_test 0400 "$base_dir" $cfg || fail=1
done

echo "=============================================================="
if [ $fail -eq 0 ]; then echo "predict/cancel contract holds"; else echo "FAILURES"; fi
exit $fail
