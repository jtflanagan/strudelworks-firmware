#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# An application backed by RISC-V (docs/RVV2_INTEROP.md), built into OUTDIR:
#   APP.stub  the stub's raw bytes (apple/rvvm/stub/stub.s with apple/rvvm/APP/app.inc)
#   APP       the stub as a GS/OS application (tools/omf_s16.py: S16 + ~Direct)
#   APP.RV    the program: apple/rvvm/APP/*.c with apple/rvvm/guest/crt0_app.S and
#             librvgs (apple/rvvm/guest/rvgs.c, png.c), a static PIE flattened; its image
#             header sizes its memory (apple/rvvm/APP/app.mk may set HEAP / STACK, bytes)
#   APP.res   the resources beside it: apple/rvvm/APP/resources.sh OUTDIR, if there is
#             one, makes them and names them (one a line)
#
#   apple/rvvm/build_app.sh APP OUTDIR
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="${1:?usage: build_app.sh APP OUTDIR}"
out="${2:?usage: build_app.sh APP OUTDIR}"
src="$root/apple/rvvm/$app"
env="$root/apple/rvvm/guest"
up="$(echo "$app" | tr a-z A-Z)"
[ -f "$src/app.inc" ] || { echo "no $src/app.inc" >&2; exit 1; }
mkdir -p "$out"
printf 'MEMORY { S: start = $0000, size = $10000, file = %%O; }\nSEGMENTS { CODE: load = S, type = ro; }\n' > "$out/stub.cfg"
ca65 -I "$src" -o "$out/$up.o" "$root/apple/rvvm/stub/stub.s"
ld65 -C "$out/stub.cfg" -o "$out/$up.stub" "$out/$up.o"
python3 "$root/tools/omf_s16.py" "$out/$up.stub" "$out/$up" > /dev/null
HEAP=0x10000; STACK=0x10000
[ -f "$src/app.mk" ] && . "$src/app.mk"
clang --target=riscv32-unknown-elf -march=rv32im_zba_zbb_zifencei -mabi=ilp32 -O2 -fPIE -ffreestanding \
    -ffunction-sections -fdata-sections -Wl,--gc-sections \
    -nostdlib -fuse-ld=lld -Wl,-pie -Wl,--no-dynamic-linker -T "$env/link.ld" -I"$env" \
    -Wl,--defsym=__heap_size=$HEAP -Wl,--defsym=__stack_size=$STACK \
    "$env/crt0_app.S" "$env/rvgs.c" "$env/png.c" "$src"/*.c -o "$out/$up.RV.elf"
llvm-objcopy -O binary "$out/$up.RV.elf" "$out/$up.RV"
: > "$out/$up.res"
[ -x "$src/resources.sh" ] && "$src/resources.sh" "$out" > "$out/$up.res"
true
