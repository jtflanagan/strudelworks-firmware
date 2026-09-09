#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The Apple IIe's own keyboard through the ADB micro: the ASCII the IOU hands
# over, run backwards into a keycode and forwards again, for all 128 values.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/kbd_a2_work"
mkdir -p "$work"
python3 "$root/tools/gen_adb_keymap.py" --check
python3 "$root/tools/gen_adb_revmap.py" --check
verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module gs_kbd_a2_tb \
    -I"$root/rtl" \
    -GKEYMAP="\"$root/rtl/adb_keymap.hex\"" \
    -GREVMAP="\"$root/rtl/adb_revmap.hex\"" \
    -Mdir "$work/obj" "$root/sim/gs_kbd_a2_tb.sv" \
    "$root/rtl/gs_kbd_a2.sv" "$root/rtl/gs_adb.sv" \
    -o gs_kbd_a2_tb > "$work/verilator.log" 2>&1 || {
        echo "verilator build failed:" >&2; tail -40 "$work/verilator.log" >&2; exit 1; }
"$work/obj/gs_kbd_a2_tb" | tee "$work/gs_kbd_a2.log" | grep -v '^\$finish' || true
grep -q '^PASS$' "$work/gs_kbd_a2.log"
