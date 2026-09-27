#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The RISC-V engine's 65816 runtime (apple/rvvm/rvengine.s) as the card's ROM
# bank $F1 (docs/RVV2_INTEROP.md): assembled for $F1, padded to the whole 64 KB
# bank, and written where the host ships its assets from - the host's conf key
# `gs_rvrom = assets/rvruntime.bin` sends it at every start.  Committed there,
# like the panel's assets/gspanel.bin, so a Pi without cc65 still has it.
#
#   apple/rvvm/build_runtime.sh [OUT]   (default ../strudelworks-host/assets/rvruntime.bin)
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="${1:-$root/../strudelworks-host/assets/rvruntime.bin}"
work="$root/sim/rvvm_work"
mkdir -p "$work"
ca65 -g -o "$work/rvruntime.o" "$root/apple/rvvm/rvengine.s"
ld65 -C "$root/apple/rvvm/rvengine.cfg" -o "$work/rvruntime.raw" -Ln "$work/rvruntime.lbl" "$work/rvruntime.o"
n=$(stat -c %s "$work/rvruntime.raw")
[ "$n" -le 65536 ] || { echo "the runtime is $n bytes: more than the one bank" >&2; exit 1; }
cp "$work/rvruntime.raw" "$out"
truncate -s 65536 "$out"
echo "$out: $n bytes of runtime in the 64 KB bank \$F1 (door \$F1:0020 -> $(grep -m1 'app_entry' "$work/rvruntime.lbl" | awk '{print $2}'))"
