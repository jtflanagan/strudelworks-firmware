#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The TX ring against the real UberDDR3 controller and the Micron DDR3 model.
# The same harness as run_latency_tb.sh; the model's own density (8 Gb) so the
# run is about the ring, not refresh timing.  Slow: calibration alone is a
# good fraction of a minute of wall clock.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
uber="$root/third_party/UberDDR3"
tb="$uber/testbench"

if [ ! -d "$uber/rtl" ]; then
  echo "UberDDR3 not fetched; running third_party/fetch_uberddr3.sh" >&2
  "$root/third_party/fetch_uberddr3.sh"
fi

out="$root/sim/tx_ring_ddr3_tb.out"

iverilog -g2012 -o "$out" -s tx_ring_ddr3_tb \
    -DSIM_MODEL -DNO_TEST_MODEL \
    -I "$tb" \
    "$root/sim/tx_ring_ddr3_tb.sv" \
    "$root/rtl/common/tx_ring.sv" \
    "$root/rtl/common/msg_master.sv" \
    "$root/rtl/common/wb_arb.sv" \
    "$root/rtl/common/sync_fifo.sv" \
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

# The Micron model keeps its DRAM contents in FILES (ddr3.sv, MAX_MEM), named
# after the instance and put in /tmp unless +model_data says otherwise - so two
# runs of this bench at once silently share one memory and corrupt each
# other's data (found 2026-09-17: every "fill bytes differ" was that).  Each
# run gets its own directory.
model_dir="$(mktemp -d "${TMPDIR:-/tmp}/ddr3_model.XXXXXX")"
trap 'rm -rf "$model_dir"' EXIT
vvp -n "$out" +model_data+"$model_dir"
