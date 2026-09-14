#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Hierarchical utilisation from the last build's ROUTED checkpoint - build.sh
# does not write one, and the utilization_hier.rpt in the tree is a hand run
# from 2026-09-02 on the Au V2's smaller part.  See build/util_hier.tcl.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${WORKDIR:-/mnt/c/temp/strudelworks-build-gs-pt_v2}"
depth="${1:-}"; [ "${depth:-}" = "-depth" ] && depth="${2:-2}" || depth=2
dcp_win="$(echo "$WORKDIR" | sed 's|^/mnt/\(.\)|\U\1:|')/strudelworks.runs/impl_1/master_top_routed.dcp"
dcp_wsl="$WORKDIR/strudelworks.runs/impl_1/master_top_routed.dcp"
[ -f "$dcp_wsl" ] || { echo "no routed checkpoint at $dcp_wsl" >&2; exit 1; }
out_win="C:/temp/utilization_hier.rpt"
VIVADO="${VIVADO:-/mnt/c/AMDDesignTools/2026.1/Vivado/bin/vivado.bat}"
# A .bat is not directly executable from WSL - binfmt interop handles .exe only,
# so it has to go through cmd.exe /c, and every path handed to Vivado must be a
# Windows path (build/build.sh says the same thing at more length).
vivado_win="$(wslpath -w "$VIVADO")"
script_win="$(wslpath -w "$root/build/util_hier.tcl")"
cd /
cmd.exe /c "$vivado_win" -mode batch -nojournal -nolog -notrace \
    -source "$script_win" \
    -tclargs -dcp "$dcp_win" -out "$out_win" -depth "$depth" 2>&1 | tail -4
cd "$root"
cp /mnt/c/temp/utilization_hier.rpt "$root/build/results/utilization_hier.rpt"
echo "==> build/results/utilization_hier.rpt"
