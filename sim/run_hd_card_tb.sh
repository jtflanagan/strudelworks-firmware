#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The hard disk's slot: the real core polling its EXECUTE port, a block
# DMA'd in and one DMA'd out, through the real driver, receiver and arbiter.
# ~5 s.  See sim/hd_card_tb.sv.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/sim/hd_card_tb.out"
iverilog -g2012 -I "$root/rtl" -o "$out" -s hd_card_tb \
    -P hd_card_tb.UCODE=\"$root/rtl/cpu65c02_ucode.hex\" \
    "$root/sim/hd_card_tb.sv" \
    "$root/rtl/cpu65c02.sv" \
    "$root/rtl/apple_bus_write.sv" \
    "$root/rtl/ft601_msg_rx.sv" \
    "$root/rtl/msg_arb.sv" \
    "$root/rtl/msg_master.sv" \
    "$root/rtl/slot_switches.sv" \
    "$root/rtl/hd_card.sv"
exec vvp -n "$out"
