#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The No-Slot Clock behind the sequencer's tightest op timing and the real
# message parser: sim/no_slot_clock_tb.sv.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/sim/no_slot_clock_tb.out"
iverilog -g2012 -I "$root/rtl/common" -I "$root/rtl/a2" -o "$out" -s no_slot_clock_tb \
    "$root/sim/no_slot_clock_tb.sv" \
    "$root/rtl/common/ft601_msg_rx.sv" \
    "$root/rtl/common/no_slot_clock.sv"
vvp -n "$out"
