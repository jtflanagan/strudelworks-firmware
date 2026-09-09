#!/usr/bin/env bash
# strudelworks-firmware
# SPDX-License-Identifier: GPL-2.0-or-later
#
# The card build, gated: the second-long checks first (the microcode ROM and
# Verilator lint, which catch what would otherwise fail after ten minutes),
# then build/build.sh --master with its output tee'd to a tagged log, then the
# timing verdict read from that log by build/wns.sh.
#
#   build/run_build.sh TAG [--gs] [--board pt_v2|au_v2]
#
# --gs builds the same top level as an Apple IIgs (docs/GS.md rung 4): the
# 65816's microcode joins the pre-flight, the bitstream lands as
# build/results/master_top_gs.bit, and the log is tagged gs_TAG so a IIgs
# build and a IIe build of the same name cannot overwrite one another.
#
# Log: build/master_build_TAG.log (gitignored; refused if it already exists).
# Exit 0 timing met, 2 timing MISS (a .bit was still written - do not load it
# as green), 1 a build error or a failed pre-flight.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tag="${1:-}"; shift || true
[ -n "$tag" ] || { echo "usage: build/run_build.sh TAG [--gs] [--board B]" >&2; exit 1; }
gs=0
args=()
for a in "$@"; do
    case "$a" in
        --gs) gs=1 ;;
        *) args+=("$a") ;;
    esac
done
set -- "${args[@]+"${args[@]}"}"
[ "$gs" = 1 ] && tag="gs_$tag"
log="$root/build/master_build_$tag.log"
[ -e "$log" ] && { echo "refused: $log exists - pick another TAG" >&2; exit 1; }

cd "$root"
echo "== pre-flight"
python3 sim/gen_microcode.py --check || { echo "pre-flight FAILED: microcode ROM stale (python3 sim/gen_microcode.py)"; exit 1; }
if [ "$gs" = 1 ]; then
    python3 sim/gen_microcode816.py --check || { echo "pre-flight FAILED: 65816 microcode ROM stale (python3 sim/gen_microcode816.py)"; exit 1; }
    python3 tools/gen_adb_keymap.py --check || { echo "pre-flight FAILED: ADB keymap stale (python3 tools/gen_adb_keymap.py)"; exit 1; }
    python3 tools/gen_adb_revmap.py --check || { echo "pre-flight FAILED: ADB reverse keymap stale (python3 tools/gen_adb_revmap.py)"; exit 1; }
fi
sim/lint.sh > "$root/build/lint_$tag.log" 2>&1 || { echo "pre-flight FAILED: lint (build/lint_$tag.log):"; grep -B1 -A6 FAIL "$root/build/lint_$tag.log" | head -40; exit 1; }
echo "lint: OK ($(grep -c ' OK$' "$root/build/lint_$tag.log") modules)"

flag="--master"; [ "$gs" = 1 ] && flag="--gs"
echo "== build/build.sh $flag $* -> $log"
build/build.sh "$flag" "$@" 2>&1 | tee "$log"
rc="${PIPESTATUS[0]}"
if [ "$rc" != 0 ]; then
    echo "== BUILD FAILED (exit $rc)"
    grep -E '^ERROR: |Cannot clear the Vivado work directory' "$log" | head -5
    exit 1
fi
echo "== verdict"
build/wns.sh "$log"
