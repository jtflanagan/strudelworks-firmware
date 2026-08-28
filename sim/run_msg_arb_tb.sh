#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Random traffic through msg_arb, checked word for word.  The property is the
# one docs/PROTOCOL.md rests on - no word of one source ever lands inside
# another's message - and reg_map_tb checks it in the cases that were found on
# hardware; this one looks for the cases that have not been.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

iverilog -g2012 -o "$root/sim/msg_arb_tb.out" -s msg_arb_tb \
    "$root/sim/msg_arb_tb.sv" \
    "$root/rtl/msg_arb.sv"

exec vvp -n "$root/sim/msg_arb_tb.out"
