#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# Logic-depth audit of the LAST build, without rebuilding: opens the routed
# checkpoint still sitting in the Vivado work directory and writes
# build/results/logic_depth.rpt + design_analysis.rpt.
#
#   build/depth.sh                 # audit the last --master build
#   build/depth.sh 8               # report paths at >= 8 levels instead of 10
#   DCP=/mnt/c/...routed.dcp build/depth.sh   # audit a specific checkpoint
#
# build.tcl writes the same two reports at the end of every build (same procs,
# from depth_report.tcl), so this script is only needed to re-run the audit at
# a different threshold or on an old checkpoint.  The Vivado invocation
# plumbing (cmd.exe, wslpath, candidate list) mirrors build/build.sh - see the
# comments there for why each piece is the way it is.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
min_level="${1:-10}"

VIVADO="${VIVADO:-}"
if [ -z "$VIVADO" ]; then
  # Same candidate order as build/build.sh - the report must come from the same
  # toolchain that built the checkpoint.
  for cand in \
    /mnt/c/AMDDesignTools/2026.1/Vivado/bin/vivado.bat \
    /mnt/c/Xilinx/2025.1/Vivado/bin/vivado.bat \
    /mnt/c/Xilinx/Vivado/2024.2/bin/vivado.bat
  do
    [ -x "$cand" ] && VIVADO="$cand" && break
  done
fi
[ -n "$VIVADO" ] || { echo "No Vivado found - see build/build.sh" >&2; exit 1; }

DCP="${DCP:-/mnt/c/temp/strudelworks-build-master/strudelworks.runs/impl_1/master_top_routed.dcp}"
if [ ! -f "$DCP" ]; then
  echo "No routed checkpoint at $DCP - run build/build.sh --master first," >&2
  echo "or point at one with DCP=/mnt/c/... build/depth.sh" >&2
  exit 1
fi

results="$root/build/results"
mkdir -p "$results"

vivado_win="$(wslpath -w "$VIVADO")"
script_win="$(wslpath -w "$root/build/depth.tcl")"
dcp_win="$(wslpath -w "$DCP")"
out_win="$(wslpath -w "$results")"
log_win="$(wslpath -w "$root/build/vivado_depth.log")"

cd /
exec cmd.exe /c "$vivado_win" -mode batch -nojournal -notrace -log "$log_win" \
    -source "$script_win" \
    -tclargs -dcp "$dcp_win" -outdir "$out_win" -min-level "$min_level"
