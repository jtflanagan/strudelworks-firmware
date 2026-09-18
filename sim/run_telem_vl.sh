#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The telemetry sender end to end (docs/TELEMETRY.md): the real bridge, front,
# register file, sender, message masters and arbiter; a bouncing RES' line; a
# capture and a host's bridge running across the sweeps.  See sim/telem_tb.sv.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/telem_work"
mkdir -p "$work"
verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module telem_tb \
    -I"$root/rtl" -Mdir "$work/obj" \
    "$root/sim/telem_tb.sv" \
    "$root/rtl/ft601_msg_rx.sv" "$root/rtl/reg_bridge.sv" "$root/rtl/reg_front.sv" \
    "$root/rtl/wb_regfile.sv" "$root/rtl/start_hold.sv" "$root/rtl/fast_census.sv" \
    "$root/rtl/telem_tx.sv" "$root/rtl/sync_fifo.sv" \
    "$root/rtl/msg_arb.sv" "$root/rtl/msg_master.sv" "$root/rtl/reply_stream.sv" \
    -o telem > "$work/verilator.log" 2>&1 || {
        echo "build failed:" >&2; tail -30 "$work/verilator.log" >&2; exit 1; }
exec "$work/obj/telem" "$@"
