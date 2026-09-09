#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The Ensoniq 5503 through its four registers: the interrupt register that
# started this, the wavetable engine, the modes, and the interrupt queue.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/doc_work"
mkdir -p "$work"
verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module gs_doc_tb \
    -I"$root/rtl" -Mdir "$work/obj" \
    "$root/sim/gs_doc_tb.sv" "$root/rtl/gs_doc.sv" \
    -o gs_doc_tb > "$work/verilator.log" 2>&1 || {
        echo "verilator build failed:" >&2; tail -40 "$work/verilator.log" >&2; exit 1; }
"$work/obj/gs_doc_tb" | tee "$work/gs_doc.log" | grep -v '^\$finish' || true
grep -q '^PASS$' "$work/gs_doc.log"
