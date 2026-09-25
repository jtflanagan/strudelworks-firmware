#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The card's flash block (rtl/common/flash_ctrl.sv) and the IPROG sequencer, behind
# the real reg_bridge and against a behavioural SST26VF032B (docs/BOOT_LOADER.md BL2).
# See sim/flash_ctrl_tb.sv.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/flash_ctrl_work"
mkdir -p "$work"
verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module flash_ctrl_tb \
    -Mdir "$work/obj" \
    "$root/sim/flash_ctrl_tb.sv" "$root/sim/sst26_model.sv" \
    "$root/rtl/common/flash_ctrl.sv" "$root/rtl/common/flash_exec.sv" \
    "$root/rtl/common/iprog.sv" "$root/rtl/common/reg_bridge.sv" \
    -o flash_ctrl > "$work/verilator.log" 2>&1 || {
        echo "build failed:" >&2; tail -30 "$work/verilator.log" >&2; exit 1; }
exec "$work/obj/flash_ctrl" "$@"
