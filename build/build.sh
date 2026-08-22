#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Run the Vivado build from WSL against the Windows-side Vivado install.
#
# There is no Linux Vivado in this WSL environment; the toolchain lives on the
# Windows host.  Two things this has to get right, both of which fail confusingly:
#
#   1. A .bat is NOT directly executable from WSL.  binfmt_misc interop only
#      handles .exe, so exec'ing vivado.bat runs it through /bin/sh, which then
#      reports "@echo: not found" and a cascade of similar noise.  It has to go
#      through cmd.exe /c.
#   2. Vivado is a Windows process, so every path handed to it must be a Windows
#      path.  Hence the wslpath conversions below.  Passing /home/... makes
#      Vivado report the script as missing.
#
# Usage: build/build.sh [extra tclargs...]
#   VIVADO=/mnt/c/Xilinx/2025.1/Vivado/bin/vivado.bat build/build.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VIVADO="${VIVADO:-}"
if [ -z "$VIVADO" ]; then
  for cand in \
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

if [ ! -d "$root/third_party/UberDDR3/rtl" ]; then
  echo "fetching UberDDR3..."
  "$root/third_party/fetch_uberddr3.sh"
fi

# Verify the generated DDR3 constraints still agree with the MIG reference before
# spending 15 minutes on a build against a stale pinout.
python3 "$root/tools/gen_ddr3_xdc.py" --check

# The Vivado project must live on a Windows-native filesystem - see the note in
# build.tcl.  Sources are still read from the repo over UNC, which works fine;
# only the run directory has to be somewhere cmd.exe can cd into.  Override with
# WORKDIR=/mnt/c/somewhere if C:\temp is not wanted.
# The Vivado GUI - including Hardware Manager, which is what you open to flash a
# bitstream - keeps handles on this project's files for as long as it has the
# project open.  Both `file delete -force` and `create_project -force` then fail
# ("Failed to remove the directory ... might be in use by some other process")
# and the build dies partway through.
#
# Detect it and say so, rather than quietly building somewhere else: if the GUI
# has the project open and this script builds into a different directory, the GUI
# keeps showing the OLD results and the discrepancy is very hard to spot.
#
# (Do not trust a `tasklist` check for this. A scan can come back clean simply
# because the GUI had not been opened yet at that moment - it was, later, to flash
# the board.  Testing the directory itself is the check that stays true.)
WORKDIR="${WORKDIR:-/mnt/c/temp/strudelworks-build}"
# Each top level gets its own work directory.  Sharing one means a -ft601 build
# silently reuses the previous au_top project state, which is exactly the kind of
# stale-results confusion the comment above is about.
case "${1:-}" in
  --diag)  WORKDIR="${WORKDIR}-diag"  ;;
  --ft601) WORKDIR="${WORKDIR}-ft601" ;;
  --snoop) WORKDIR="${WORKDIR}-snoop" ;;
esac
if [ -e "$WORKDIR" ] && ! rm -rf "$WORKDIR" 2>/dev/null; then
  cat >&2 <<EOF

Cannot clear the Vivado work directory:
  $WORKDIR

This almost always means Vivado has the project open on the Windows side -
Hardware Manager counts, so a session left open after flashing will do it.

  Fix: close the project in Vivado (File > Close Project) and re-run.
  Or:  build somewhere else with  WORKDIR=/mnt/c/temp/other build/build.sh
       - but note the GUI will then still be showing the old results.
EOF
  exit 1
fi
mkdir -p "$WORKDIR"

workdir_win="$(wslpath -w "$WORKDIR")"
echo "vivado project dir: $workdir_win  (artefacts copied back to build/results)"

script_win="$(wslpath -w "$root/build/build.tcl")"
log_win="$(wslpath -w "$root/build/vivado.log")"
jou_win="$(wslpath -w "$root/build/vivado.jou")"

vivado_win="$(wslpath -w "$VIVADO")"

# Pass each argument separately and let WSL's interop layer marshal the command
# line.  Wrapping the whole invocation in one quoted string instead gets the
# quotes escaped into literal \" characters, and cmd.exe then reports the .bat
# as "not recognized as an internal or external command".
#
# cd to / first: cmd.exe cannot hold a \\wsl.localhost\... UNC path as its
# working directory and prints a warning while silently falling back to the
# Windows directory.  Everything below is an absolute Windows path anyway, so
# giving it nothing to complain about is cleaner than ignoring the warning.
cd /
exec cmd.exe /c "$vivado_win" -mode batch -nojournal -notrace \
    -log "$log_win" -journal "$jou_win" \
    -source "$script_win" -tclargs -outdir "$workdir_win" "$@"
