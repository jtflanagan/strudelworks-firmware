#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# What the engine's floating point buys (docs/RVV2_FP.md): Embench-IoT 1.0's four
# floating-point benchmarks (cubic, minver, nbody, st - Embench 2.0 dropped them;
# they come from the sibling checkout's embench-1.0 tag by git archive), each
# built by clang -O2 as the applications are, twice - soft float (rv32im_zba_zbb,
# ilp32, the soft-float picolibc and libgcc) and hard (rv32imfd_zba_zbb, ilp32d,
# picolibc's F/D variant, whose libm - cubic's cos, acos, pow - runs on the FPU
# too, and libgcc's ilp32d multilib) - and run under RUN on the core bench in
# lockstep with the reference model (sim/run_rv_core.sh --ref --run).
#
#   sim/run_rv_fp_embench.sh [NAME-FILTER]
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ebgit="${EMBENCH:-$root/../embench-iot}"
work="$root/sim/rvvm_work/fp_embench"
gcclib="$root/../xpack-riscv-none-elf-gcc-15.2.0-1/lib/gcc/riscv-none-elf/15.2.0"
g="$root/apple/rvvm/guest"
bs="$root/apple/rvvm/embench"
filter="${1:-}"
mkdir -p "$work"
[ -d "$work/eb1/src" ] || { mkdir -p "$work/eb1"; git -C "$ebgit" archive embench-1.0 src/cubic src/minver src/nbody src/st support | tar -x -C "$work/eb1"; }
[ -f "$root/sim/rvvm_work/picolibc/lib/libc.a" ] || "$root/sim/build_rvvm_picolibc.sh" > /dev/null
[ -f "$root/sim/rvvm_work/picolibc-fd/lib/libc.a" ] || "$root/sim/build_rvvm_picolibc.sh" fd > /dev/null
"$root/sim/run_rv_core.sh" --build-only > /dev/null
eb="$work/eb1"

fail=0
printf '%-8s %12s %12s %8s   %s\n' bench "soft clocks" "hard clocks" speedup "instructions soft -> hard"
for d in "$eb"/src/*/; do
    n="$(basename "$d")"
    [ -n "$filter" ] && [[ "$n" != *"$filter"* ]] && continue
    declare -A clk=() ins=()
    for v in soft hard; do
        if [ $v = soft ]; then
            isa=(-march=rv32im_zba_zbb -mabi=ilp32); pico="$root/sim/rvvm_work/picolibc"; libgcc="$gcclib/rv32im/ilp32"
        else
            isa=(-march=rv32imfd_zba_zbb -mabi=ilp32d); pico="$root/sim/rvvm_work/picolibc-fd"; libgcc="$gcclib/rv32imfd_zicsr/ilp32d"
        fi
        if ! clang --target=riscv32-unknown-elf "${isa[@]}" -O2 -fPIE -ffreestanding -fno-math-errno -w \
                -isystem "$pico/include" -I"$g" -I"$bs" -I"$eb/support" -I"$d" \
                -DHAVE_BOARDSUPPORT_H -DWARMUP_HEAT=1 -DGLOBAL_SCALE_FACTOR=1 -DCPU_MHZ=1 \
                -nostdlib -fuse-ld=lld -Wl,-pie -Wl,--no-dynamic-linker -T "$g/link.ld" \
                "$g/crt0.S" "$g/rvvm_stdio.c" "$bs/boardsupport.c" "$eb/support/main.c" "$eb/support/beebsc.c" "$d"/*.c \
                -L"$pico/lib" -L"$libgcc" -Wl,--start-group -lc -lm -lgcc -Wl,--end-group \
                -o "$work/$n.$v.elf" > "$work/$n.$v.build.log" 2>&1 ||
           ! llvm-objcopy -O binary "$work/$n.$v.elf" "$work/$n.$v.bin"; then
            echo "BUILD FAIL $n $v ($work/$n.$v.build.log)"; fail=$((fail + 1)); continue 2
        fi
        if ! "$root/sim/run_rv_core.sh" --guest="$work/$n.$v.bin" --load=0x20000 --ref --run > "$work/$n.$v.log" 2>&1; then
            echo "FAIL $n $v: $(grep -E 'rvvm: (exit|trap)|LOCKSTEP|differs' "$work/$n.$v.log" | head -2 | tr '\n' ' ')"
            fail=$((fail + 1)); continue 2
        fi
        # "rvvm: N instructions, M clocks, ..."
        read -r ins[$v] clk[$v] < <(sed -nE 's/^rvvm: ([0-9]+) instructions, ([0-9]+) clocks.*/\1 \2/p' "$work/$n.$v.log" | tail -1)
    done
    printf '%-8s %12s %12s %7.2fx   %s -> %s\n' "$n" "${clk[soft]}" "${clk[hard]}" \
        "$(echo "${clk[soft]} / ${clk[hard]}" | bc -l)" "${ins[soft]}" "${ins[hard]}"
done
[ $fail = 0 ]
