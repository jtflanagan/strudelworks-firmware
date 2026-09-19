#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# sim/audio_tb.sv under Verilator (~13 M clocks; iverilog takes many minutes,
# sim/run_audio_tb.sh).  The sound on the card: docs/AUDIO.md.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/audio_work"
mkdir -p "$work"
obj="$work/obj_vl"
verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module audio_tb \
    -I"$root/rtl/common" -I"$root/rtl/a2" -Mdir "$obj" \
    "$root/sim/audio_tb.sv" \
    "$root/rtl/common/apple_bus_write.sv" "$root/rtl/common/mockingboard.sv" "$root/rtl/common/via6522.v" \
    "$root/rtl/common/ay_pair.sv" "$root/rtl/common/YM2149.sv" "$root/rtl/common/ssi263.sv" "$root/rtl/common/slot_switches.sv" \
    "$root/rtl/common/speaker.sv" "$root/rtl/common/audio_sampler.sv" "$root/rtl/common/audio_tx.sv" "$root/rtl/common/sync_fifo.sv" \
    -o audio_vl > "$work/verilator.log" 2>&1 || {
        echo "verilator build failed:" >&2; tail -30 "$work/verilator.log" >&2; exit 1; }
"$obj/audio_vl" | tee "$work/audio_vl.log"
grep -q '^PASS$' "$work/audio_vl.log"
