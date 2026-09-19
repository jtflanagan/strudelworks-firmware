#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The Ensoniq fed the register stream a real machine sent it: does it play?
# sim/doc_work/docstream.hex is made from a live capture - see the bench.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/doc_work"
mkdir -p "$work"
verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module gs_doc_replay_tb \
    -I"$root/rtl/common" -I"$root/rtl/gs" -Mdir "$work/robj" \
    "$root/sim/gs_doc_replay_tb.sv" "$root/rtl/gs/gs_doc.sv" \
    -o gs_doc_replay_tb > "$work/verilator_replay.log" 2>&1 || {
        echo "verilator build failed:" >&2; tail -40 "$work/verilator_replay.log" >&2; exit 1; }
cd "$root" && "$work/robj/gs_doc_replay_tb" | tee "$work/gs_doc_replay.log"
