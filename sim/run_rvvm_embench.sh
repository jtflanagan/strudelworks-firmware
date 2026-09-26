#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Embench-IoT on the RISC-V VM's toolchain (docs/REQ_RVVM.md): each benchmark
# from the sibling checkout ../embench-iot built as CoreMark is (clang -O2,
# rv32im_zba_zbb, picolibc, a static PIE), with the board layer in
# apple/rvvm/embench, then run on the core bench's reference model
# (sim/run_rv_core.sh --ref-only) with any extra arguments - --cachestudy for
# the row-cache sizing study.  A benchmark passes when it exits 0 (its own
# verify_benchmark()).
#
#   sim/run_rvvm_embench.sh [NAME-FILTER] [-- runner args, default --cachestudy]
#
# EMBENCH_RUNNER / EMBENCH_MODE pick the bench and its mode (default
# sim/run_rv_core.sh --ref-only); EMBENCH_RUNNER=sim/run_rv_mem.sh
# EMBENCH_MODE=--ref runs the RTL core and memory side in lockstep.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eb="${EMBENCH:-$root/../embench-iot}"
pico="$root/sim/rvvm_work/picolibc"
libgcc="${LIBGCC_DIR:-$root/../xpack-riscv-none-elf-gcc-15.2.0-1/lib/gcc/riscv-none-elf/15.2.0/rv32im/ilp32}"
g="$root/apple/rvvm/guest"
bs="$root/apple/rvvm/embench"
work="${EMBENCH_WORK:-$root/sim/rvvm_work/embench}"
filter="${1:-}"; [ $# -gt 0 ] && shift
[ "${1:-}" = "--" ] && shift
run_args=("$@"); [ ${#run_args[@]} -eq 0 ] && run_args=(--cachestudy)
mkdir -p "$work"
runner="${EMBENCH_RUNNER:-$root/sim/run_rv_core.sh}"; [[ "$runner" = /* ]] || runner="$root/$runner"
mode="${EMBENCH_MODE:---ref-only}"
[ -f "$pico/lib/libc.a" ] || "$root/sim/build_rvvm_picolibc.sh" > /dev/null
cflags=(--target=riscv32-unknown-elf -march=rv32im_zba_zbb -mabi=ilp32 -O2 -fPIE -ffreestanding
        -isystem "$pico/include" -I"$g" -I"$bs" -I"$eb/support"
        -DHAVE_BOARDSUPPORT_H -DWARMUP_HEAT=1 -DGLOBAL_SCALE_FACTOR=1 -w)
pass=0; fail=0; failed=""
for d in "$eb"/src/*/; do
    n="$(basename "$d")"
    [ -n "$filter" ] && [[ "$n" != *"$filter"* ]] && continue
    if ! clang "${cflags[@]}" -I"$d" -nostdlib -fuse-ld=lld -Wl,-pie -Wl,--no-dynamic-linker -T "$g/link.ld" \
            "$g/crt0.S" "$g/rvvm_stdio.c" "$bs/boardsupport.c" \
            "$eb/support/main.c" "$eb/support/beebsc.c" "$eb/support/chip.c" "$d"/*.c \
            -L"$pico/lib" -L"$libgcc" -Wl,--start-group -lc -lm -lgcc -Wl,--end-group \
            -o "$work/$n.elf" > "$work/$n.build.log" 2>&1; then
        echo "BUILD FAIL $n ($work/$n.build.log)"; fail=$((fail + 1)); failed="$failed $n"; continue
    fi
    llvm-objcopy -O binary "$work/$n.elf" "$work/$n.bin"
    if "$runner" --guest="$work/$n.bin" --load=0x20000 $mode "${run_args[@]}" > "$work/$n.log" 2>&1; then
        pass=$((pass + 1)); r=PASS
    else
        fail=$((fail + 1)); failed="$failed $n"; r=FAIL
    fi
    printf '%-4s %-16s %s %s\n' "$r" "$n" "$(grep -oE '[0-9]+ instructions' "$work/$n.log" | tail -1)" "$(grep -oE '[0-9.]+ clocks/instruction' "$work/$n.log" | tail -1)"
    grep '^cachestudy' "$work/$n.log" | sed 's/^/     /' || true
done
echo "$pass passed, $fail failed${failed:+:$failed}"
[ "$fail" -eq 0 ]
