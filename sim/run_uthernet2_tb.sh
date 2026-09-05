#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The Uthernet II behind the sequencer's tightest op timing and the real
# message parser: sim/uthernet2_tb.sv.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/sim/uthernet2_tb.out"
# iverilog notes every constant part-select inside an always_comb ("sorry:
# constant selects ... all bits will be included"): a sensitivity remark, not
# a fault - filtered, from the compile and the run alike.
iverilog -g2012 -I "$root/rtl" -o "$out" -s uthernet2_tb \
    "$root/sim/uthernet2_tb.sv" \
    "$root/rtl/ft601_msg_rx.sv" \
    "$root/rtl/fd_bank.sv" \
    "$root/rtl/uthernet2_card.sv" 2> >(grep -v "sorry: constant selects" >&2)
vvp -n "$out" 2>&1 | grep -v "sorry: constant selects"
