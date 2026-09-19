#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Where the IIgs chipset answers: gs_io's claim over banks x $C0xx x SHADOW, and
# the side effect following it (sim/gs_io_claim_tb.sv, docs/LONG_DATA.md rung 3).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/gs_io_claim_work"
mkdir -p "$work"
verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module gs_io_claim_tb \
    -I"$root/rtl/common" -I"$root/rtl/gs" \
    -GADB_KEYMAP="\"$root/rtl/gs/adb_keymap.hex\"" \
    -Mdir "$work/obj" "$root/sim/gs_io_claim_tb.sv" \
    "$root/rtl/gs/gs_io.sv" "$root/rtl/gs/gs_adb.sv" "$root/rtl/gs/gs_doc.sv" "$root/rtl/gs/gs_clock.sv" \
    "$root/rtl/gs/gs_intc.sv" "$root/rtl/gs/gs_iwm.sv" \
    -o gs_io_claim_tb > "$work/verilator.log" 2>&1 || {
        echo "verilator build failed:" >&2; tail -30 "$work/verilator.log" >&2; exit 1; }
"$work/obj/gs_io_claim_tb" | tee "$work/gs_io_claim.log" | grep -v '^\$finish' || true
grep -q '^PASS$' "$work/gs_io_claim.log"
