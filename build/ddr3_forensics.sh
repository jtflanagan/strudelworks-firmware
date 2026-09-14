#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# DDR3 forensics on a routed checkpoint (build/ddr3_forensics.tcl): the PHY's
# clock leg, the clock-to-pad census, clock resources, placement, LUT combining.
#   build/ddr3_forensics.sh TAG [WORKDIR]     # WORKDIR default: the last --gs build
# Writes build/results/ddr3_forensics_TAG.txt.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tag="${1:?usage: ddr3_forensics.sh TAG [WORKDIR]}"
WORKDIR="${2:-${WORKDIR:-/mnt/c/temp/strudelworks-build-gs-pt_v2}}"
dcp_wsl="$WORKDIR/strudelworks.runs/impl_1/master_top_routed.dcp"
[ -f "$dcp_wsl" ] || { echo "no routed checkpoint at $dcp_wsl" >&2; exit 1; }
dcp_win="$(wslpath -w "$dcp_wsl")"
out_win="C:/temp/ddr3_forensics_$tag.txt"
VIVADO="${VIVADO:-/mnt/c/AMDDesignTools/2026.1/Vivado/bin/vivado.bat}"
vivado_win="$(wslpath -w "$VIVADO")"
script_win="$(wslpath -w "$root/build/ddr3_forensics.tcl")"
cd /
cmd.exe /c "$vivado_win" -mode batch -nojournal -nolog -notrace \
    -source "$script_win" -tclargs -dcp "$dcp_win" -out "$out_win" 2>&1 | grep -a -v '^$' | tail -5
cd "$root"
cp "/mnt/c/temp/ddr3_forensics_$tag.txt" "$root/build/results/ddr3_forensics_$tag.txt"
echo "==> build/results/ddr3_forensics_$tag.txt"
