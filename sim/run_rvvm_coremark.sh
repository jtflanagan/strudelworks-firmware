#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# CoreMark on the RISC-V engine's core bench (docs/REQ_RVVM.md).  From
# the sibling checkout ../coremark, clang -O2 for rv32im_zba_zbb, picolibc
# (sim/build_rvvm_picolibc.sh), the rvvm port in apple/rvvm/coremark; a static
# PIE, loaded at the runner's default $800000 and relocated by crt0.  One
# tick is one engine clock at a nominal 1 MHz, so CoreMark's score is the
# engine's CoreMark/MHz.
#
#   sim/run_rvvm_coremark.sh [ITERATIONS] [runner args, e.g. --ref --prof]
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cm="${COREMARK:-$root/../coremark}"
pico="$root/sim/rvvm_work/picolibc"
libgcc="${LIBGCC_DIR:-$root/../xpack-riscv-none-elf-gcc-15.2.0-1/lib/gcc/riscv-none-elf/15.2.0/rv32im/ilp32}"
g="$root/apple/rvvm/guest"
work="$root/sim/rvvm_work/coremark"
iters="${1:-1}"; [ $# -gt 0 ] && shift
mkdir -p "$work"
[ -f "$pico/lib/libc.a" ] || "$root/sim/build_rvvm_picolibc.sh" > /dev/null
opt="-O2"
cflags=(--target=riscv32-unknown-elf -march=rv32im_zba_zbb -mabi=ilp32 $opt -fPIE -ffreestanding
        -isystem "$pico/include" -I"$g" -I"$root/apple/rvvm/coremark" -I"$cm"
        -DITERATIONS="$iters" -DPERFORMANCE_RUN=1
        -DFLAGS_STR="\"$opt -march=rv32im_zba_zbb\"" -DCOMPILER_VERSION="\"clang $(clang -dumpversion)\"")
clang "${cflags[@]}" -nostdlib -fuse-ld=lld -Wl,-pie -Wl,--no-dynamic-linker -T "$g/link.ld" \
    "$g/crt0.S" "$g/rvvm_stdio.c" "$root/apple/rvvm/coremark/core_portme.c" \
    "$cm"/core_list_join.c "$cm"/core_main.c "$cm"/core_matrix.c "$cm"/core_state.c "$cm"/core_util.c \
    -L"$pico/lib" -L"$libgcc" -Wl,--start-group -lc -lgcc -Wl,--end-group \
    -o "$work/coremark.elf"
llvm-objcopy -O binary "$work/coremark.elf" "$work/coremark.bin"
echo "coremark.bin: $(stat -c %s "$work/coremark.bin") bytes, $iters iteration(s)"
exec "$root/sim/run_rv_core.sh" --guest="$work/coremark.bin" "$@"
