#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The IIgs's ADB microcontroller, driven directly: the keyboard's characters,
# $C025's modifiers, a Talk register 0, and the auto-repeat whose delay is
# forty-five frames and so cannot be reached from the boot bench.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/adb_work"
mkdir -p "$work"
python3 "$root/tools/gen_adb_keymap.py" --check
python3 "$root/tools/gen_adb_revmap.py" --check
verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module gs_adb_tb \
    -I"$root/rtl/common" -I"$root/rtl/gs" \
    -GKEYMAP="\"$root/rtl/gs/adb_keymap.hex\"" \
    -Mdir "$work/obj" "$root/sim/gs_adb_tb.sv" "$root/rtl/gs/gs_adb.sv" \
    -o gs_adb_tb > "$work/verilator.log" 2>&1 || {
        echo "verilator build failed:" >&2; tail -30 "$work/verilator.log" >&2; exit 1; }
"$work/obj/gs_adb_tb" | tee "$work/gs_adb.log" | grep -v '^\$finish' || true
grep -q '^PASS$' "$work/gs_adb.log"
