#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The GS control panel's binary on the card's own 65816 (sim/gspanel_run_main.cpp,
# docs/GS_CONTROL_PANEL.md R0).
#
#   sim/run_gspanel.sh                         # the runner's self-test (sim/gspanel_selftest.s)
#   sim/run_gspanel.sh --bin PANEL.bin [runner args...]
#                                              # e.g. --keys='{down}{ret}{esc}' --expect=TEXT --stock=1
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/gspanel_work"
mkdir -p "$work"

bin=""
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --bin) bin="$2"; shift 2;;
        *) args+=("$1"); shift;;
    esac
done

python3 "$root/sim/gen_microcode816.py" --check

verilator --cc --exe --build -O2 -Wno-fatal --public-flat-rw --top-module cpu65816 \
    -I"$root/rtl/common" -I"$root/rtl/gs" \
    -GUCODE_FILE="\"$root/rtl/gs/cpu65816_ucode.hex\"" \
    -GUCODE0_FILE="\"$root/rtl/gs/cpu65816_ucode0.hex\"" \
    -GUSEQ0_FILE="\"$root/rtl/gs/cpu65816_useq0.hex\"" \
    -Mdir "$work/obj" "$root/rtl/gs/cpu65816.sv" "$root/sim/gspanel_run_main.cpp" \
    -o gspanel_run > "$work/verilator.log" 2>&1 || {
        echo "build failed:" >&2; tail -30 "$work/verilator.log" >&2; exit 1; }

run="$work/obj/gspanel_run"
hex="--hex=$root/rtl/gs/cpu65816_ucode.hex"

if [ -z "$bin" ]; then
    for t in ca65 ld65; do
        command -v "$t" >/dev/null || { echo "need $t on PATH (cc65)" >&2; exit 1; }
    done
    cat > "$work/selftest.cfg" <<'CFG'
MEMORY { ROM: start = $E20000, size = $10000, file = %O, fill = yes, fillval = $FF; }
SEGMENTS { CODE: load = ROM, type = ro; }
CFG
    ca65 -o "$work/selftest.o" "$root/sim/gspanel_selftest.s"
    ld65 -C "$work/selftest.cfg" -o "$work/selftest.bin" "$work/selftest.o"
    # Return chains once and writes S; Escape returns.  HIS on row 0.
    "$run" "$hex" --bin="$work/selftest.bin" --keys='x{ret}{esc}' --expect=HIS --stock=1 "${args[@]}"
else
    "$run" "$hex" --bin="$bin" "${args[@]}"
fi
