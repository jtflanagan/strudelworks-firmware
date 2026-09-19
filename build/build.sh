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
# Usage: build/build.sh [--master|--gs|--snoop|--ft601|--diag] [--board <b>] [--synth-only] [extra tclargs...]
#   --synth-only: synthesise, report utilisation (build/results/synth_util*.rpt), no bitstream
#   --gs is --master with the GS parameter set: the same top level built as an
#   Apple IIgs, into its own work directory, landing as
#   build/results/master_top_gs.bit (docs/GS.md rung 4).
#   VIVADO=/mnt/c/AMDDesignTools/2026.1/Vivado/bin/vivado.bat build/build.sh
#   BOARD=au_v2 build/build.sh --master      # same as --board au_v2
#
# The board (au_v2 | pt_v2, tools/boards.py) picks the part and
# the per-board pin constraints in constr/<board>/.  Default pt_v2; the
# generators' --check below refuses to build if that default has drifted from
# tools/boards.py.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BOARD="${BOARD:-pt_v2}"
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --board|-board) shift; BOARD="$1" ;;
    --synth-only) args+=("-synth_only") ;;
    *) args+=("$1") ;;
  esac
  shift
done
set -- "${args[@]+"${args[@]}"}"
echo "board: $BOARD"

VIVADO="${VIVADO:-}"
if [ -z "$VIVADO" ]; then
  # The 2026.1 install is the live one, under C:\AMDDesignTools.  C:\Xilinx is a
  # derelict earlier install that is still on disk and still looks plausible; it
  # is listed last so it is only ever a fallback, never the default.  Same order
  # as build/synth_ooc.sh - the two must not disagree about which Vivado builds
  # this project, or an OOC timing number gets compared against a bitstream from
  # a different toolchain.
  for cand in \
    /mnt/c/AMDDesignTools/2026.1/Vivado/bin/vivado.bat \
    /mnt/c/Xilinx/2025.1/Vivado/bin/vivado.bat \
    /mnt/c/Xilinx/Vivado/2024.2/bin/vivado.bat
  do
    [ -x "$cand" ] && VIVADO="$cand" && break
  done
fi
if [ -z "$VIVADO" ]; then
  cat >&2 <<'EOF'
No Vivado found.  Looked for, in order:
  /mnt/c/AMDDesignTools/2026.1/Vivado/bin/vivado.bat   <- the current one
  /mnt/c/Xilinx/2025.1/Vivado/bin/vivado.bat
  /mnt/c/Xilinx/Vivado/2024.2/bin/vivado.bat

If it is installed somewhere else:  VIVADO=/path/to/vivado.bat build/build.sh
EOF
  exit 1
fi
echo "using $VIVADO"

if [ ! -d "$root/third_party/UberDDR3/rtl" ]; then
  echo "fetching UberDDR3..."
  "$root/third_party/fetch_uberddr3.sh"
fi

# Verify the generated constraints still agree with their sources before
# spending 15 minutes on a build against a stale pinout: the DDR3 XDC against
# the board's MIG project and Alchitry's pin table, the pin XDCs against the
# connector-named sources, and build.tcl's board table against tools/boards.py.
python3 "$root/tools/gen_ddr3_xdc.py" --check --board "$BOARD"
python3 "$root/tools/gen_pin_xdc.py" --check --board "$BOARD"

# Stamp the bitstream with when this build started, readable back over the link
# as registers 0 and 1.  Captured HERE rather than inside Vivado so that the two
# halves cannot disagree, and so a rebuild can be pinned to an old stamp with
# STAMP_DATE=20260823 STAMP_TIME=143900 build/build.sh.
# 10# forces base ten: HHMMSS carries a leading zero for most of the morning,
# and an unadorned 093000 is an octal literal to both bash and Tcl - 09 is not
# even a valid one, so it fails rather than silently being wrong. Which is the
# better failure, but not one to have at all.
STAMP_DATE="${STAMP_DATE:-$((10#$(date +%Y%m%d)))}"
STAMP_TIME="${STAMP_TIME:-$((10#$(date +%H%M%S)))}"
printf 'build stamp: %08d %06d\n' "$STAMP_DATE" "$STAMP_TIME"

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
  --master) WORKDIR="${WORKDIR}-master" ;;
  # The IIgs is the same top level with a different parameter, which is
  # exactly the case the note above is about: sharing one work directory with
  # --master would let a IIe project's state stand in for a IIgs build's, and
  # a stale bitstream that looks plausible is the worst of the failures here.
  --gs) WORKDIR="${WORKDIR}-gs" ;;
esac
# And per board, for the same reason: a pt_v2 project must not inherit an
# au_v2 project's state.
WORKDIR="${WORKDIR}-${BOARD}"
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

# WHICH BITSTREAM THIS RUN OWES, by the same rule build/build.tcl names it
# with (its $topname / $bitname) - the check below is against the artefact
# itself, so the two have to agree.  --gs implies --master there, which is why
# it is not folded in with the others.
case "${1:-}" in
  --gs)     bitname=master_top_gs ;;
  --master) bitname=master_top ;;
  --snoop)  bitname=snoop_top ;;
  --ft601)  bitname=ft601_top ;;
  --diag)   bitname=diag_top ;;
  *)        bitname=au_top ;;
esac
bit="$root/build/results/$bitname.bit"
# The mark a fresh bitstream has to beat.  Not the file's ABSENCE: a failed run
# leaves the previous one sitting there, and that is the whole trap - it is
# there, it is the right size, and it is the design from before the change.
before=0
[ -e "$bit" ] && before=$(stat -c %Y "$bit")
started=$(date +%s)

# THIS WAS AN `exec`, AND A BUILD THAT PRODUCED NOTHING REPORTED SUCCESS.
# Vivado's exit status does not survive the trip out through vivado.bat and
# cmd.exe's interop marshalling: a synthesis ERROR - a module missing from the
# fileset, say - printed its message, exited Vivado, and handed this script a
# 0.  Nothing that crosses that boundary can be trusted to carry a status, so
# the status is not what is trusted here: THE ARTEFACT IS.
#
# NOT THE SAME THING AS A TIMING MISS, and this must not be read as one.  A
# miss is a warning to build.tcl on purpose: it still writes a .bit, which is
# often exactly what you want to look at, and the rule stays what CLAUDE.md
# says - read WNS with build/wns.sh, never the exit status, and a miss is
# never green.  What is caught below is the other case: no new bitstream at
# all.
cd /
cmd.exe /c "$vivado_win" -mode batch -nojournal -notrace \
    -log "$log_win" -journal "$jou_win" \
    -source "$script_win" -tclargs -outdir "$workdir_win" -board "$BOARD" \
    -stamp-date "$STAMP_DATE" -stamp-time "$STAMP_TIME" "$@"
status=$?
cd "$root"

after=0
[ -e "$bit" ] && after=$(stat -c %Y "$bit")
if [ "$after" -ge "$started" ] && [ "$after" != "$before" ]; then
    [ "$status" -eq 0 ] || echo "note: vivado exited $status but wrote $bitname.bit" >&2
    exit 0
fi

# No new bitstream.  Say which of the two cases it is - the stale file still
# sitting in build/results is the one worth naming out loud - and quote
# Vivado's own errors, because the log is 400 KB and the three lines that
# matter are somewhere in the middle of it.
echo >&2
# A synthesis-only run owes no bitstream (build/results/synth_util*.rpt is its product).
if printf "%s\n" "${args[@]+"${args[@]}"}" | grep -qx -- "-synth_only"; then exit 0; fi
if [ "$after" != 0 ]; then
    echo "BUILD FAILED: $bitname.bit was NOT rebuilt." >&2
    echo "  The file in build/results is the PREVIOUS run's," >&2
    echo "  dated $(date -d "@$after" '+%Y-%m-%d %H:%M:%S').  It is not this design." >&2
else
    echo "BUILD FAILED: no $bitname.bit was produced." >&2
fi
echo "  vivado exit status: $status;  full log: build/vivado.log" >&2
if [ -s "$root/build/vivado.log" ]; then
    echo >&2
    grep -aE '^ERROR:' "$root/build/vivado.log" | head -10 | sed 's/^/  /' >&2
fi
exit 1
