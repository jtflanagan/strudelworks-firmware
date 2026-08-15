#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 jtflanagan
# Out-of-context synthesis of one module, for resource estimation.
#
#   build/synth_ooc.sh                       # cpu65c02 at 100 MHz
#   build/synth_ooc.sh --period 6.0          # ask for 166 MHz instead
#   build/synth_ooc.sh --top foo --src rtl/foo.sv
#
# Same WSL plumbing as build/build.sh, and for the same two reasons: a .bat is
# not directly executable from WSL (binfmt_misc interop only handles .exe), and
# every path handed to a Windows Vivado has to be a Windows path.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

top="cpu65c02"
srcs=()
period="10.0"
extra=()

while [ $# -gt 0 ]; do
    case "$1" in
        --top)    shift; top="$1" ;;
        --src)    shift; srcs+=("$1") ;;
        --period) shift; period="$1" ;;
        *)        extra+=("$1") ;;
    esac
    shift
done
[ ${#srcs[@]} -gt 0 ] || srcs=("$root/rtl/$top.sv")

VIVADO="${VIVADO:-}"
if [ -z "$VIVADO" ]; then
  # The 2026.1 install is the live one.  C:\Xilinx is a derelict earlier
  # install that is still on disk and still looks plausible; it is listed last
  # so it is only ever a fallback, never the default.
  for cand in \
    /mnt/c/AMDDesignTools/2026.1/Vivado/bin/vivado.bat \
    /mnt/c/Xilinx/2025.1/Vivado/bin/vivado.bat \
    /mnt/c/Xilinx/Vivado/2024.2/bin/vivado.bat
  do
    [ -x "$cand" ] && VIVADO="$cand" && break
  done
fi
if [ -z "$VIVADO" ]; then
  echo "No Vivado found. Set VIVADO=/path/to/vivado.bat" >&2
  exit 1
fi
echo "using $VIVADO"

# Vivado's run directory has to be Windows-native: cmd.exe cannot hold a
# \\wsl.localhost\... UNC path as a working directory.  Reading sources over UNC
# is fine - only the run directory matters.
WORKDIR="${WORKDIR:-/mnt/c/temp/strudelworks-ooc}"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

args=(-top "$top" -period "$period" -outdir "$(wslpath -w "$WORKDIR")")
for s in "${srcs[@]}"; do
    args+=(-src "$(wslpath -w "$s")")
done

script_win="$(wslpath -w "$root/build/synth_ooc.tcl")"
log_win="$(wslpath -w "$root/build/vivado_ooc.log")"
vivado_win="$(wslpath -w "$VIVADO")"

cd /
cmd.exe /c "$vivado_win" -mode batch -nojournal -notrace \
    -log "$log_win" -journal "$(wslpath -w "$root/build/vivado_ooc.jou")" \
    -source "$script_win" -tclargs "${args[@]}" "${extra[@]}"

# The reports land on the Windows side; copy them back so they are next to the
# rest of the project's build artefacts.
results="$root/build/ooc"
mkdir -p "$results"
cp -f "$WORKDIR"/*.rpt "$results/" 2>/dev/null || true
echo "reports: $results"
