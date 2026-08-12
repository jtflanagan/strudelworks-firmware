#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 jtflanagan
# Print UberDDR3's derived DDR3 timing for the strudelworks configuration.
#
# ddr3_controller.v has an unconditional `initial $display` block that reports
# every computed localparam - CL, CWL, the command slots, and all the
# inter-command delays.  sim/params_dump.sv instantiates it with our parameters
# and nothing else, so this is the cheapest possible way to see exactly what
# timing a parameter change produces.  Run it after touching any parameter in
# rtl/ddr3_wrapper.sv or rtl/clk_gen.v.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -d "$root/third_party/UberDDR3/rtl" ]; then
  "$root/third_party/fetch_uberddr3.sh"
fi

out="$root/sim/params_dump.out"
iverilog -g2012 -DNO_TEST_MODEL -o "$out" -s params_dump \
    "$root/sim/params_dump.sv" \
    "$root/third_party/UberDDR3/rtl/ddr3_controller.v" 2>/dev/null

vvp -n "$out" | sed -n '/CONTROLLER PARAMETERS/,/End of DDR3 TOP PARAMETERS/p'
