#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 jtflanagan
# Host->card frame parsing, and the watchdog built on top of it.
#
# The watchdog decides when the card blows away the link, so both of its failure
# modes are expensive: firing when it should not resets a working capture, and
# not firing when it should leaves a dead host holding a stalled link.  Neither
# is comfortable to provoke on hardware - the real timeout is a full second.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

iverilog -g2012 -o "$root/sim/ft601_msg_rx_tb.out" -s ft601_msg_rx_tb \
    "$root/sim/ft601_msg_rx_tb.sv" \
    "$root/rtl/ft601_msg_rx.sv" \
    "$root/rtl/link_watchdog.sv"

exec vvp -n "$root/sim/ft601_msg_rx_tb.out"
