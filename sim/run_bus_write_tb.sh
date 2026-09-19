#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# apple_bus_write against an Apple-shaped phi0.  ~1 s.
#
# The checks are drawn from the ways this is known to fail - two of them are
# aty's bugs written down as assertions - rather than from the module's own
# structure.  See sim/bus_write_tb.sv.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/sim/bus_write_tb.out"
iverilog -g2012 -o "$out" "$root/sim/bus_write_tb.sv" "$root/rtl/common/apple_bus_write.sv"
exec vvp "$out"
