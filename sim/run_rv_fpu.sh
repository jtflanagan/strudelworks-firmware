#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# rtl/gs/rv_fpu.sv against Berkeley SoftFloat 3 (RISCV specialization) and
# TestFloat's generated cases (sim/rv_fpu_main.cpp).  The two live beside this
# repo, built once:
#   ../berkeley-softfloat-3/build/Linux-x86_64-GCC: make SPECIALIZE_TYPE=RISCV
#   ../berkeley-testfloat-3/build/Linux-x86_64-GCC: make SPECIALIZE_TYPE=RISCV
#
#   sim/run_rv_fpu.sh                 random (200k) + TestFloat level 1, every op, format, mode
#   sim/run_rv_fpu.sh --rand N [--seed S]
#   sim/run_rv_fpu.sh --tf OP DBL RM  one TestFloat suite
#   sim/run_rv_fpu.sh --build-only
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sf="$root/../berkeley-softfloat-3"
tf="$root/../berkeley-testfloat-3/build/Linux-x86_64-GCC/testfloat_gen"
work="$root/sim/rv_fpu_work"
mkdir -p "$work"
run="$work/obj/rv_fpu_run"
srcs=("$root/rtl/gs/rv_fpu.sv" "$root/sim/rv_fpu_main.cpp")
stale=0
[ -x "$run" ] || stale=1
for s in "${srcs[@]}"; do [ "$s" -nt "$run" ] && stale=1; done
if [ $stale = 1 ]; then
    verilator --cc --exe --build -O2 -Wall -Wno-fatal --top-module rv_fpu \
        -CFLAGS "-O2 -I$sf/source/include" -LDFLAGS "$sf/build/Linux-x86_64-GCC/softfloat.a" \
        -Mdir "$work/obj" "$root/rtl/gs/rv_fpu.sv" "$root/sim/rv_fpu_main.cpp" \
        -o rv_fpu_run > "$work/verilator.log" 2>&1 || {
            echo "build failed:" >&2; grep -E '%Error|error' "$work/verilator.log" | head -20 >&2; exit 1; }
fi
rmname=(near_even minMag min max near_maxMag)
# testfloat_gen's function for (op, dbl); the -exact flag makes the int conversions raise NX
tfname() {
    local op=$1 d=$2 f; [ "$d" = 1 ] && f=f64 || f=f32
    case $op in
        add|sub|mul|div|sqrt|eq|lt|le) echo "${f}_$op" ;;
        madd)   echo "${f}_mulAdd" ;;
        cvtw)   echo "${f}_to_i32 -exact" ;;
        cvtwu)  echo "${f}_to_ui32 -exact" ;;
        cvtfw)  echo "i32_to_$f" ;;
        cvtfwu) echo "ui32_to_$f" ;;
        cvtff)  [ "$d" = 1 ] && echo "f64_to_f32" || echo "f32_to_f64" ;;
    esac
}
tf_gen() {
    local op=$1 d=$2 rm=$3
    # shellcheck disable=SC2046
    "$tf" -tininessafter -r"${rmname[$rm]}" $(tfname "$op" "$d")
}

case "${1:-}" in
    --build-only) echo "built $run"; exit 0 ;;
    --rand) shift; exec "$run" --rand "$@" ;;
    --tf)
        op=$2 dbl=$3 rm=$4
        exec "$run" --tf "$op" --dbl "$dbl" --rm "$rm" < <(tf_gen "$op" "$dbl" "$rm") ;;
esac

fails=0
echo "== random"
"$run" --rand 200000 --seed 1 || fails=$((fails + 1))
echo "== TestFloat level 1"
for op in add sub mul div sqrt madd eq lt le cvtw cvtwu cvtfw cvtfwu cvtff; do
    for d in 0 1; do
        for rm in 0 1 2 3 4; do
            # the compares and the exact conversions do not round
            case $op in eq|lt|le) [ $rm != 0 ] && continue ;; esac
            case $op in cvtfw|cvtfwu) [ "$d" = 1 ] && [ $rm != 0 ] && continue ;; esac
            [ "$op" = cvtff ] && [ "$d" = 0 ] && [ $rm != 0 ] && continue
            out=$("$run" --tf "$op" --dbl "$d" --rm "$rm" < <(tf_gen "$op" "$d" "$rm")) || fails=$((fails + 1))
            # a suite that checked nothing (testfloat_gen refused) is a failure
            echo "$out" | grep -q '^0 checked' && fails=$((fails + 1))
            printf '%-7s %s rm%d: %s\n' "$op" "$([ "$d" = 1 ] && echo d || echo s)" "$rm" "$(echo "$out" | tail -1)"
            echo "$out" | grep MISMATCH | head -3 || true
        done
    done
done
echo "== $fails failing suites"
[ $fails = 0 ]
