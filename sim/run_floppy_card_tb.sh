#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The Disk II's slot behind the real driver, receiver and arbiter, with a
# scripted CPU counting cycles and the tb playing the host.  ~10 s.  See
# sim/floppy_card_tb.sv.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/sim/floppy_card_tb.out"
iverilog -g2012 -I "$root/rtl/common" -I "$root/rtl/a2" -o "$out" -s floppy_card_tb \
    "$root/sim/floppy_card_tb.sv" \
    "$root/rtl/common/apple_bus_write.sv" \
    "$root/rtl/common/ft601_msg_rx.sv" \
    "$root/rtl/common/msg_arb.sv" \
    "$root/rtl/common/msg_master.sv" \
    "$root/rtl/common/slot_switches.sv" \
    "$root/rtl/common/fd_bank.sv" \
    "$root/rtl/a2/floppy_card.sv"
exec vvp -n "$out"
