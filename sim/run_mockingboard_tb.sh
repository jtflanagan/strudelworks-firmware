#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The Mockingboard behind the real bus driver, on an Apple-shaped phi0.  ~2 s.
#
# Drives apple_bus_write and mockingboard together - the claim/emit seam is
# where they can disagree - with the pin round trip modelled the way the board
# wires it.  See sim/mockingboard_tb.sv.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/sim/mockingboard_tb.out"
iverilog -g2012 -o "$out" \
    "$root/sim/mockingboard_tb.sv" \
    "$root/rtl/common/apple_bus_write.sv" \
    "$root/rtl/common/mockingboard.sv" \
    "$root/rtl/common/via6522.v" \
    "$root/rtl/common/ay_pair.sv" \
    "$root/rtl/common/YM2149.sv" \
    "$root/rtl/common/ssi263.sv" \
    "$root/rtl/common/slot_switches.sv"
exec vvp "$out"
