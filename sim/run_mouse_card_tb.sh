#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The mouse card behind the real driver and message parser: sim/mouse_card_tb.sv.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/sim/mouse_card_tb.out"
iverilog -g2012 -I "$root/rtl/common" -I "$root/rtl/a2" -o "$out" -s mouse_card_tb \
    "$root/sim/mouse_card_tb.sv" \
    "$root/rtl/common/apple_bus_write.sv" \
    "$root/rtl/common/ft601_msg_rx.sv" \
    "$root/rtl/common/slot_switches.sv" \
    "$root/rtl/common/mouse_card.sv"
# iverilog notes every constant part-select inside the always_comb ("sorry:
# constant selects ... all bits will be included"): a sensitivity remark, not
# a fault, and twenty of them a run - filtered.
vvp -n "$out" 2>&1 | grep -v "sorry: constant selects"
