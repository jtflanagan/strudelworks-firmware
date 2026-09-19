#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The register path end to end: a host message in, a Wishbone cycle, a reply out.
#
# Worth running before every build that touches the message layer.  The failure
# this catches - a reply landing inside a BUS_EVENTS payload - does not announce
# itself on hardware: the link has no sync word and cannot resynchronise, so the
# stream stays plausible and wrong and looks like a decode bug much further on.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

iverilog -g2012 -o "$root/sim/reg_map_tb.out" -s reg_map_tb \
    "$root/sim/reg_map_tb.sv" \
    "$root/rtl/common/ft601_msg_rx.sv" \
    "$root/rtl/common/reg_bridge.sv" \
    "$root/rtl/common/wb_regfile.sv" \
    "$root/rtl/common/start_hold.sv" \
    "$root/rtl/a2/fast_census.sv" \
    "$root/rtl/common/msg_arb.sv" \
    "$root/rtl/common/msg_master.sv" \
    "$root/rtl/common/kbd_notice.sv" \
    "$root/rtl/common/reply_stream.sv"

exec vvp -n "$root/sim/reg_map_tb.out"
