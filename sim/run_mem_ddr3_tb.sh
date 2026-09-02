#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The page client in the arbiter's priority slot against the real UberDDR3
# controller and the Micron DDR3 model, the TX ring streaming beside it: order,
# pipelined burst latency under pre-emption, and where the refreshes land.  Slow, like
# run_tx_ring_ddr3_tb.sh: a few minutes.  See sim/mem_ddr3_tb.sv.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
uber="$root/third_party/UberDDR3"
tb="$uber/testbench"

if [ ! -d "$uber/rtl" ]; then
  echo "UberDDR3 not fetched; running third_party/fetch_uberddr3.sh" >&2
  "$root/third_party/fetch_uberddr3.sh"
fi

out="$root/sim/mem_ddr3_tb.out"

iverilog -g2012 -o "$out" -s mem_ddr3_tb \
    -DSIM_MODEL -DNO_TEST_MODEL \
    -I "$tb" \
    "$root/sim/mem_ddr3_tb.sv" \
    "$root/rtl/tx_ring.sv" \
    "$root/rtl/page_client.sv" \
    "$root/rtl/msg_master.sv" \
    "$root/rtl/wb_arb.sv" \
    "$root/rtl/sync_fifo.sv" \
    "$tb/ddr3.sv" \
    "$tb/models/IDELAYCTRL_model.v" \
    "$tb/models/IDELAYE2_model.v" \
    "$tb/models/IOBUF_DCIEN_model.v" \
    "$tb/models/IOBUF_model.v" \
    "$tb/models/IOBUFDS_DCIEN_model.v" \
    "$tb/models/IOBUFDS_model.v" \
    "$tb/models/ISERDESE2_model.v" \
    "$tb/models/OBUFDS_model.v" \
    "$tb/models/ODELAYE2_model.v" \
    "$tb/models/OSERDESE2_model.v" \
    "$tb/models/OBUF_model.v" \
    "$uber/rtl/ddr3_top.v" \
    "$uber/rtl/ddr3_controller.v" \
    "$uber/rtl/ddr3_phy.v"

exec vvp -n "$out"
