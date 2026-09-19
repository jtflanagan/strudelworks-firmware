#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Check the UART report formatting and framing without a build or a board.
#
# Decodes the serial line the way a real UART would - mid-bit sampling at the
# real 115200 divisor - and diffs the result against the expected 180-byte
# report.  Run this after touching report_tx.sv, uart_tx.v or bin_to_bcd.v; a
# misplaced digit is far cheaper to find here than on the bench.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

iverilog -g2012 -o "$root/sim/report_tb.out" -s report_tb \
    "$root/sim/report_tb.sv" \
    "$root/rtl/common/report_tx.sv" \
    "$root/rtl/common/uart_tx.v" \
    "$root/rtl/common/bin_to_bcd.v"

exec vvp -n "$root/sim/report_tb.out"
