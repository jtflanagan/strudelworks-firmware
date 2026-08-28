#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The TX ring and its Wishbone arbiter against a small, fast memory model that
# keeps the DDR3 controller's rules: in-order acks, a write landing only when
# acked, whole lines only, and no cyc drop with an ack outstanding.  Word-exact
# through wraps, a full ring, and a reset.  run_tx_ring_ddr3_tb.sh is the same
# ring against the real controller and the Micron model.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

iverilog -g2012 -o "$root/sim/tx_ring_tb.out" -s tx_ring_tb \
    "$root/sim/tx_ring_tb.sv" \
    "$root/rtl/tx_ring.sv" \
    "$root/rtl/msg_master.sv" \
    "$root/rtl/wb_arb.sv" \
    "$root/rtl/sync_fifo.sv"

exec vvp -n "$root/sim/tx_ring_tb.out"
