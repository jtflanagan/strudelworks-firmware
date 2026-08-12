#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 jtflanagan
# Verilator lint over this project's RTL.  Run before a Vivado build.
#
# Worth having because iverilog and Vivado disagree about what is legal, and the
# gap is where the bugs hide.  Case in point: an out-of-range part-select
# (sum_x10[16 +: 32] on a 40-bit value) elaborated fine under iverilog and was a
# hard ERROR in Vivado synthesis - after a ten-minute build.  Verilator catches
# that class in about a second.
#
# UberDDR3's own sources are not linted here; upstream has its own lint pass and
# its warnings are not ours to fix.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# UNUSEDSIGNAL/UNUSEDPARAM: debug outputs and config parameters that this build
# does not consume are intentional, not oversights.
COMMON=(--lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM)

fail=0
run() {
    local top="$1"; shift
    printf '%-16s ' "$top"
    if verilator "${COMMON[@]}" --top-module "$top" "$@" 2>/tmp/lint.$$; then
        echo "OK"
    else
        echo "FAIL"
        sed 's/^/    /' /tmp/lint.$$
        fail=1
    fi
    rm -f /tmp/lint.$$
}

run uart_tx       rtl/uart_tx.v
run bin_to_bcd    rtl/bin_to_bcd.v
run report_tx     rtl/report_tx.sv rtl/bin_to_bcd.v
run latency_probe rtl/latency_probe.sv

# Not linted, deliberately:
#   clk_gen.v      - nothing but IBUF/BUFG/MMCME2_BASE instantiation.  Verilator
#                    cannot resolve Xilinx primitives without stubs, and there is
#                    no logic in the file for it to have an opinion about.  The
#                    MMCM configuration is checked by Vivado, which is the only
#                    tool that knows the VCO limits anyway.
#   ddr3_wrapper / au_top - structural, and both instantiate UberDDR3 or
#                    primitives.  Vivado elaboration covers them.

exit $fail
