#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The Disk II's slot behind the real driver, receiver and arbiter, with a
# scripted CPU counting cycles and the tb playing the host.  ~10 s.  See
# sim/floppy_card_tb.sv.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/sim/floppy_card_tb.out"
iverilog -g2012 -I "$root/rtl" -o "$out" -s floppy_card_tb \
    "$root/sim/floppy_card_tb.sv" \
    "$root/rtl/apple_bus_write.sv" \
    "$root/rtl/ft601_msg_rx.sv" \
    "$root/rtl/msg_arb.sv" \
    "$root/rtl/msg_master.sv" \
    "$root/rtl/slot_switches.sv" \
    "$root/rtl/fd_bank.sv" \
    "$root/rtl/floppy_card.sv"
exec vvp -n "$out"
