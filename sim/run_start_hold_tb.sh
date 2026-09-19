#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The start hold (docs/CLEAN_START.md CS1) against a modelled RES' line: a
# wired-OR of the hold, the host's pulse and a finger, a slow bouncy rise and a
# synchroniser.  See sim/start_hold_tb.sv.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/start_hold_work"
mkdir -p "$work"
verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module start_hold_tb \
    -I"$root/rtl/common" -I"$root/rtl/a2" -Mdir "$work/obj" \
    "$root/sim/start_hold_tb.sv" "$root/rtl/common/start_hold.sv" \
    -o start_hold > "$work/verilator.log" 2>&1 || {
        echo "build failed:" >&2; tail -30 "$work/verilator.log" >&2; exit 1; }
exec "$work/obj/start_hold" "$@"
