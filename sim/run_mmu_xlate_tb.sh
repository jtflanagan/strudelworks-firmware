#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The region table against the classifier it replaced, over every reachable
# map (docs/PAGE_CACHE.md).  Verilator, about a minute.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/mmu_xlate_work"; mkdir -p "$work"
command -v verilator > /dev/null || { echo "verilator not found" >&2; exit 1; }
verilator --binary --timing -j 4 -O1 -Wno-fatal --top-module mmu_xlate_tb \
    -I"$root/rtl/common" -I"$root/rtl/a2" --Mdir "$work/obj_vl" \
    "$root/sim/mmu_xlate_tb.sv" "$root/rtl/a2/apple_mmu.sv" \
    > "$work/build.log" 2>&1 || { tail -30 "$work/build.log"; exit 1; }
exec "$work/obj_vl/Vmmu_xlate_tb" "$@"
