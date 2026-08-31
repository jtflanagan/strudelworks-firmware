#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The sparse capture's filter: the keep rule, the SKIP words and their
# counts, the cap, disable and re-enable, and the filter chained into the
# real capture so the VBL_MARK cut lands between a SKIP and its event.  See
# sim/bus_event_filter_tb.sv and docs/SPARSE.md.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
iverilog -g2012 -o "$root/sim/bus_event_filter_tb.out" -s bus_event_filter_tb \
    "$root/sim/bus_event_filter_tb.sv" \
    "$root/rtl/bus_event_filter.sv" "$root/rtl/event_merge.sv" \
    "$root/rtl/bus_event_capture.sv" \
    "$root/rtl/sync_fifo.sv"
vvp -n "$root/sim/bus_event_filter_tb.out" | tee /dev/stderr | grep -q "^PASS$"
