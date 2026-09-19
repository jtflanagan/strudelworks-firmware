#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The Ensoniq's road out of the card: audio_sampler's DOC box, which nothing
# tested until the card played silence (docs/AUDIO.md, docs/GS.md rung 7).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/audio_work"
mkdir -p "$work"
verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module audio_doc_tb \
    -I"$root/rtl/common" -I"$root/rtl/a2" -Mdir "$work/dobj" \
    "$root/sim/audio_doc_tb.sv" "$root/rtl/common/audio_sampler.sv" \
    -o audio_doc_tb > "$work/verilator_doc.log" 2>&1 || {
        echo "verilator build failed:" >&2; tail -40 "$work/verilator_doc.log" >&2; exit 1; }
"$work/dobj/audio_doc_tb" | tee "$work/audio_doc.log"
grep -q '^PASS$' "$work/audio_doc.log"
