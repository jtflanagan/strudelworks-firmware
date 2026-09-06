#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# One SSI-263 speech chip's engine at the real sample rate: phoneme lengths
# under each DUR, the repeat, D7 and A/!R, power-down.  ~5 s.  See
# sim/ssi263_tb.sv; the chip behind the bus is in sim/mockingboard_tb.sv.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/sim/ssi263_tb.out"
iverilog -g2012 -o "$out" "$root/sim/ssi263_tb.sv" "$root/rtl/ssi263.sv"
exec vvp "$out"
