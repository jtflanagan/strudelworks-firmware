#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The configuration flash's executor (docs/BOOT_LOADER.md BL1) against a
# behavioural SST26VF032B.  See sim/flash_exec_tb.sv.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/flash_exec_work"
mkdir -p "$work"
verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module flash_exec_tb \
    -Mdir "$work/obj" \
    "$root/sim/flash_exec_tb.sv" "$root/sim/sst26_model.sv" "$root/rtl/common/flash_exec.sv" \
    -o flash_exec > "$work/verilator.log" 2>&1 || {
        echo "build failed:" >&2; tail -30 "$work/verilator.log" >&2; exit 1; }
exec "$work/obj/flash_exec" "$@"
