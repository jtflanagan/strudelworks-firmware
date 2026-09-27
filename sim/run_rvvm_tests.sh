#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The riscv-tests smoke suites (rv32ui, rv32um, rv32uzba, rv32uzbb, rv32uf, rv32ud) and rvvm's
# own edge tests (apple/rvvm/guest/tests: bank crossings, every trap cause) on
# the RISC-V engine, each in lockstep with the reference model (docs/REQ_RVVM.md).
# An edge test names its verdict on a "# rvvm-expect: exit" or "trap N" line,
# its load (= link) address on "# rvvm-load:" (default $800000) and extra
# runner arguments on "# rvvm-args:".  A test marked "# rvvm-hi" needs the upper
# 16 MB, which only the engine's own memory side reaches: --engine-sys (the
# 65816 serving every access) skips it.  The C tests (apple/rvvm/guest/ctests)
# are static PIEs, each run at two load addresses (the identity map: crt0
# relocates itself), and one marked "rvvm-hi" (no I/O) at a third in the upper 16 MB.
#
#   sim/run_rvvm_tests.sh [--ref-only | --engine | --engine-mem | --engine-sys] [NAME-FILTER]
#
# The runner is the engine's core bench (sim/run_rv_core.sh; --engine names it
# explicitly); --engine-mem the core with its memory side and an L2 model
# (sim/run_rv_mem.sh); --engine-sys the engine behind its window with its
# 65816 VM (sim/run_rvvm.sh).  There is no software VM on riscv_v2: the 65816 cannot
# reach the engine's upper 16 MB, so the engine is the only way a guest runs.
#
# The tests come from the sibling checkout ../riscv-tests, assembled with the
# xPack GCC (three rv32uzbb sources carry 64-bit immediates GNU as truncates
# and the LLVM assembler rejects).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/rvvm_work/tests"
tests="${RISCV_TESTS:-$root/../riscv-tests}"
xgcc="${RVGCC:-$root/../xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-gcc}"
objcopy="${xgcc%gcc}objcopy"
# (the C tests' 64-bit division: libgcc, integer-only, the same ilp32 ABI as the apps')
libgcc="${xgcc%/bin/*}/lib/gcc/riscv-none-elf/15.2.0/rv32im/ilp32/libgcc.a"
env="$root/apple/rvvm/guest"
mkdir -p "$work"

mode=(--ref)
filter=""
# RVVM_EXTRA: more runner arguments for every test (e.g. --rung1 with --engine).
read -r -a extra_all <<< "${RVVM_EXTRA:-}"
runner="$root/sim/run_rv_core.sh"
sys=0
for a in "$@"; do
    case "$a" in
        --ref-only) mode=(--ref-only);;
        --engine) runner="$root/sim/run_rv_core.sh";;
        --engine-mem) runner="$root/sim/run_rv_mem.sh";;
        --engine-sys) runner="$root/sim/run_rvvm.sh"; sys=1;;
        *) filter="$a";;
    esac
done

[ -d "$tests/isa" ] || { echo "no riscv-tests at $tests" >&2; exit 1; }
[ -x "$xgcc" ] || { echo "no RISC-V gcc at $xgcc" >&2; exit 1; }
"$runner" --build-only >/dev/null

pass=0; fail=0; skip=0; failed=()
for d in rv32ui rv32um rv32uzba rv32uzbb rv32uf rv32ud; do
    # (the FP suites hold sources RV32 does not build - rv32ud's move: its Makefrag names the rest)
    sc="$(sed -n '/_sc_tests *=/,/^$/p' "$tests/isa/$d/Makefrag" 2>/dev/null | tr -d '\\' | sed 's/.*=//')"
    for src in "$tests/isa/$d"/*.S; do
        n="$d-$(basename "$src" .S)"
        [ -n "$filter" ] && [[ "$n" != *"$filter"* ]] && continue
        case $d in rv32uf|rv32ud) [[ " $(echo $sc) " == *" $(basename "$src" .S) "* ]] || continue;; esac
        if ! "$xgcc" -march=rv32imfd_zba_zbb_zifencei -mabi=ilp32 -nostdlib -nostartfiles -T "$env/link.ld" \
                -Wl,--defsym=__load=0x800000 \
                -I"$env" -I"$tests/isa/macros/scalar" "$src" -o "$work/$n.elf" > "$work/$n.log" 2>&1 ||
           ! "$objcopy" -O binary "$work/$n.elf" "$work/$n.bin" >> "$work/$n.log" 2>&1; then
            fail=$((fail + 1)); failed+=("$n")
            printf "FAIL %-24s build: %s\n" "$n" "$(grep -m1 -i error "$work/$n.log")"
            continue
        fi
        if "$runner" --guest="$work/$n.bin" "${mode[@]}" "${extra_all[@]}" > "$work/$n.log" 2>&1; then
            pass=$((pass + 1))
            printf "PASS %-24s %s\n" "$n" "$(grep -oE '[0-9.]+ cycles/instruction' "$work/$n.log" || true)"
        else
            fail=$((fail + 1)); failed+=("$n")
            printf "FAIL %-24s %s\n" "$n" "$(grep -E 'rvvm: (exit|trap)|^ref:|LOCKSTEP|stray|runaway' "$work/$n.log" | head -2 | tr '\n' ' ')"
        fi
    done
done
for src in "$root/apple/rvvm/guest/tests"/*.S; do
    n="rvvm-$(basename "$src" .S)"
    [ -n "$filter" ] && [[ "$n" != *"$filter"* ]] && continue
    if [ $sys = 1 ] && grep -q '^# rvvm-hi$' "$src"; then skip=$((skip + 1)); continue; fi
    expect="$(sed -n 's/^# rvvm-expect: *//p' "$src")"
    read -r -a extra <<< "$(sed -n 's/^# rvvm-args: *//p' "$src")"
    at="$(sed -n 's/^# rvvm-load: *//p' "$src")"; at="${at:-0x800000}"
    extra+=(--load="$at")
    case "$expect" in
        exit) ;;
        "trap "*) extra+=(--expect-trap="${expect#trap }");;
        *) echo "FAIL $n: no rvvm-expect line"; fail=$((fail + 1)); failed+=("$n"); continue;;
    esac
    if ! "$xgcc" -march=rv32imfd_zba_zbb_zifencei -mabi=ilp32 -nostdlib -nostartfiles -T "$env/link.ld" \
            -Wl,--defsym=__load="$at" \
            -I"$root/apple/rvvm/guest/tests" "$src" -o "$work/$n.elf" > "$work/$n.log" 2>&1 ||
       ! "$objcopy" -O binary "$work/$n.elf" "$work/$n.bin" >> "$work/$n.log" 2>&1; then
        fail=$((fail + 1)); failed+=("$n")
        printf "FAIL %-24s build: %s\n" "$n" "$(grep -m1 -i error "$work/$n.log")"
        continue
    fi
    if "$runner" --guest="$work/$n.bin" "${mode[@]}" "${extra_all[@]}" "${extra[@]}" > "$work/$n.log" 2>&1; then
        pass=$((pass + 1))
        printf "PASS %-24s %s\n" "$n" "$(grep -E 'rvvm: (exit|trap)|^ref:' "$work/$n.log" | head -1)"
    else
        fail=$((fail + 1)); failed+=("$n")
        printf "FAIL %-24s %s\n" "$n" "$(grep -E 'rvvm: (exit|trap)|^ref:|LOCKSTEP|stray|runaway' "$work/$n.log" | head -2 | tr '\n' ' ')"
    fi
done
for src in "$root/apple/rvvm/guest/ctests"/*.c; do
    n="rvvm-c-$(basename "$src" .c)"
    [ -n "$filter" ] && [[ "$n" != *"$filter"* ]] && continue
    if ! clang --target=riscv32-unknown-elf -march=rv32imfd_zba_zbb -mabi=ilp32 -O2 -fPIE -ffreestanding -fno-math-errno \
            -nostdlib -fuse-ld=lld -Wl,-pie -Wl,--no-dynamic-linker -T "$env/link.ld" -I"$env" \
            "$env/crt0.S" "$src" "$libgcc" -o "$work/$n.elf" > "$work/$n.log" 2>&1 ||
       ! llvm-objcopy -O binary "$work/$n.elf" "$work/$n.bin" >> "$work/$n.log" 2>&1; then
        fail=$((fail + 1)); failed+=("$n")
        printf "FAIL %-24s build: %s\n" "$n" "$(grep -m1 -i error "$work/$n.log")"
        continue
    fi
    ats="0x800000 0x20000"
    # the upper 16 MB only for a test that does no I/O: the 65816 performs I/O,
    # and how a guest up there reaches it is the interop design's, still open
    grep -q 'rvvm-hi' "$src" && ats="$ats 0x1800000"
    for at in $ats; do
        [ $sys = 1 ] && [ $((at)) -ge $((0x1000000)) ] && { skip=$((skip + 1)); continue; }
        if "$runner" --guest="$work/$n.bin" --load="$at" "${mode[@]}" "${extra_all[@]}" > "$work/$n@$at.log" 2>&1; then
            pass=$((pass + 1))
            printf "PASS %-24s at %-8s %s\n" "$n" "$at" "$(grep -E 'rvvm: (exit|trap)|^ref:' "$work/$n@$at.log" | head -1)"
        else
            fail=$((fail + 1)); failed+=("$n@$at")
            printf "FAIL %-24s at %-8s %s\n" "$n" "$at" "$(grep -E 'rvvm: (exit|trap)|^ref:|LOCKSTEP|stray|runaway' "$work/$n@$at.log" | head -2 | tr '\n' ' ')"
        fi
    done
done
note=""; [ $skip -gt 0 ] && note=", $skip skipped (the upper 16 MB)"
echo "$pass passed, $fail failed${failed:+: ${failed[*]}}$note"
[ $fail = 0 ]
