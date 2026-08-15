#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 jtflanagan
# Does the FT601 controller move data from a cold start?
#
# Run this after ANY change to rtl/ft601_fifo.sv.  It exists because removing the
# reference's 0x66665555 preload deadlocked TX outright - the refill request
# window was only reachable from above, so an empty queue never loaded and the
# FSM never left S_IDLE.  That cost a build, a flash and a bench run to find.
# This finds it in under a second.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

iverilog -g2012 -o "$root/sim/ft601_fifo_tb.out" -s ft601_fifo_tb \
    "$root/sim/ft601_fifo_tb.sv" \
    "$root/rtl/ft601_fifo.sv"

exec vvp -n "$root/sim/ft601_fifo_tb.out"
