#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The VidHD's slot ROM behind the real driver and receiver, with a scripted
# CPU and the tb playing the host.  ~1 s.  See sim/vidhd_card_tb.sv.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/sim/vidhd_card_tb.out"
iverilog -g2012 -I "$root/rtl/common" -I "$root/rtl/a2" -o "$out" -s vidhd_card_tb \
    "$root/sim/vidhd_card_tb.sv" \
    "$root/rtl/common/apple_bus_write.sv" \
    "$root/rtl/common/ft601_msg_rx.sv" \
    "$root/rtl/common/slot_switches.sv" \
    "$root/rtl/a2/vidhd_card.sv"
exec vvp -n "$out"
