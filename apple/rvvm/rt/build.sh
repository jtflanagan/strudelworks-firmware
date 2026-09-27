#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The RISC-V code the 65816 runtime carries in its own bank (apple/rvvm/rvengine.s
# segment RVCODE, at $F1E000) and runs in place: each .S here, linked where it
# sits and flattened, into OUTDIR for ca65's --bin-include-dir.
#
#   apple/rvvm/rt/build.sh OUTDIR
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
out="${1:?usage: build.sh OUTDIR}"
xgcc="${RVGCC:-$root/../xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-gcc}"
objcopy="${xgcc%gcc}objcopy"
[ -x "$xgcc" ] || { echo "no RISC-V gcc at $xgcc" >&2; exit 1; }
mkdir -p "$out"
for src in "$root"/apple/rvvm/rt/*.S; do
    n="$(basename "$src" .S)"
    "$xgcc" -march=rv32im_zba_zbb_zifencei -mabi=ilp32 -nostdlib -nostartfiles -Wl,-Ttext=0xF1E000 \
        -o "$out/$n.elf" "$src"
    "$objcopy" -O binary "$out/$n.elf" "$out/$n.bin"
done
