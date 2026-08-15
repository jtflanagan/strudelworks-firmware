#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 jtflanagan
# Event capture and framing - the properties a dump depends on.
#
# The failure mode here is not a crash, it is a dump that looks fine and is
# missing events.  This decodes the outgoing block stream the same way the host
# does and asserts conservation: every event in comes out, once, in order, inside
# a well-formed frame - and a disable discards rather than leaking into the next
# capture.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

iverilog -g2012 -o "$root/sim/bus_snoop_tb.out" -s bus_snoop_tb \
    "$root/sim/bus_snoop_tb.sv" \
    "$root/rtl/bus_event_capture.sv" \
    "$root/rtl/sync_fifo.sv"

exec vvp -n "$root/sim/bus_snoop_tb.out"
