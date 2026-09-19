#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Check the heartbeat rule against the case list in docs/PROTOCOL.md.
#
# The whole errata workaround comes down to one number - how many heartbeats come
# out for each way of stopping - and getting it wrong is expensive to see on
# hardware: too few and a speculative host read hangs until its timeout, too many
# and the link carries filler.  Both are invisible in a throughput figure.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

iverilog -g2012 -o "$root/sim/ft601_msg_tb.out" -s ft601_msg_tb \
    "$root/sim/ft601_msg_tb.sv" \
    "$root/rtl/common/ft601_msg_tx.sv" \
    "$root/rtl/common/ft601_fifo.sv"

exec vvp -n "$root/sim/ft601_msg_tb.out"
