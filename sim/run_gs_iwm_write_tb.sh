#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The IIgs IWM's 5.25" writes: stores under the head, the $FF a sync byte
# skips, the FD_DIRTY upload before the seek, and every event that sends a
# written track home (sim/gs_iwm_write_tb.sv, docs/IWM35.md).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/gs_iwm_write_work"
mkdir -p "$work"
verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module gs_iwm_write_tb \
    -I"$root/rtl/common" -I"$root/rtl/gs" \
    -Mdir "$work/obj" "$root/sim/gs_iwm_write_tb.sv" "$root/rtl/gs/gs_iwm.sv" \
    -o gs_iwm_write_tb > "$work/verilator.log" 2>&1 || {
        echo "verilator build failed:" >&2; tail -30 "$work/verilator.log" >&2; exit 1; }
"$work/obj/gs_iwm_write_tb" | tee "$work/gs_iwm_write.log" | grep -v '^\$finish' || true
grep -q '^PASS$' "$work/gs_iwm_write.log"
