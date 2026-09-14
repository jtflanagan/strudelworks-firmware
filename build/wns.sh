#!/usr/bin/env bash
# strudelworks-firmware
# SPDX-License-Identifier: GPL-2.0-or-later
#
# The timing verdict of the last build, on one line, and the logic-depth
# audit diffed against the committed baseline.  A build that misses timing
# still exits 0 and still writes a .bit (build.tcl prints a WARNING), so the
# number has to be READ, never inferred from an exit status - this is the one
# place it is read.
#
#   build/wns.sh                     # from build/results/timing_summary.rpt
#   build/wns.sh build/master_build_TAG.log   # from a build log's " setup WNS :" line
#   build/wns.sh --save-baseline     # rewrite build/depth_baseline.txt from logic_depth.rpt
#   build/wns.sh --tail=14           # the level from which a path counts as the deep tail
#
# Prints:
#   TIMING MET wns=+0.034 whs=+0.059 fail=0/53139 bit=build/results/master_top.bit (2026-09-06 12:00)
#   depth: max 21 (was 21), 1236 paths >= 10 (was 1236); tail >= 14: 62 (was 62); NEW DEEP TAIL: none
# Exit 0 timing met, 2 timing MISS, 1 no report to read.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
res="$root/build/results"
rpt="$res/timing_summary.rpt"
depth="$res/logic_depth.rpt"
baseline="$root/build/depth_baseline.txt"
log=""; save=0; tail_lvl=14
for a in "$@"; do
    case "$a" in
        --save-baseline) save=1 ;;
        --tail=*) tail_lvl="${a#--tail=}" ;;
        -h|--help) sed -n 5,20p "$0"; exit 0 ;;
        *) log="$a" ;;
    esac
done

wns=""; whs=""; fail=""; total=""; stamp=""
if [ -n "$log" ]; then
    [ -f "$log" ] || { echo "no log at $log" >&2; exit 1; }
    wns="$(grep -E '^ setup WNS : ' "$log" | tail -1 | awk '{print $4}')"
    whs="$(grep -E '^ hold  WHS : ' "$log" | tail -1 | awk '{print $4}')"
    stamp="$(grep -E '^build stamp: ' "$log" | tail -1 | sed 's/^build stamp: //')"
    err="$(grep -E '^ERROR: ' "$log" | head -1 || true)"
    if [ -z "$wns" ]; then
        echo "TIMING NONE - no ' setup WNS' line in $log${err:+; $err}"
        exit 1
    fi
    # The endpoint counts live only in the .rpt; use it if it is at least as
    # new as the log (the same build), else leave them out.
    if [ -f "$rpt" ]; then
        # The same build writes the .rpt seconds before the log's last line:
        # within ten minutes of each other, they are one build.
        d=$(( $(stat -c %Y "$log") - $(stat -c %Y "$rpt") ))
        if [ "${d#-}" -lt 600 ]; then
            read -r _ _ fail total _ < <(awk '/^ *WNS\(ns\)/{n=NR} n && NR==n+2{print $1, $2, $3, $4, $5; exit}' "$rpt")
        fi
    fi
else
    [ -f "$rpt" ] || { echo "no report at $rpt - run build/build.sh --master first" >&2; exit 1; }
    read -r wns _ fail total whs _ < <(awk '/^ *WNS\(ns\)/{n=NR} n && NR==n+2{print $1, $2, $3, $4, $5, $6; exit}' "$rpt")
fi
[ -n "$wns" ] || { echo "could not read WNS" >&2; exit 1; }

fmt() { awk -v v="$1" 'BEGIN{printf "%s%.3f", (v>=0?"+":""), v}'; }
verdict="MET"
if awk -v a="$wns" -v b="${whs:-0}" 'BEGIN{exit !(a<0 || b<0)}'; then verdict="MISS"; fi
# WHICH BITSTREAM THIS VERDICT IS ABOUT.  --gs builds the same top level as an
# Apple IIgs and lands as master_top_gs.bit (docs/GS.md rung 4), so a verdict
# read from a IIgs log must not quote the IIe bitstream's name and mtime - that
# is exactly the stale-results confusion build/build.sh takes such care over.
# The log says which it was.
bitname="master_top"
if [ -n "$log" ] && [ -f "$log" ] && grep -q 'machine: Apple IIgs' "$log"; then
    bitname="master_top_gs"
    gs_build=1
fi
bit="$res/$bitname.bit"
bitinfo="none"
if [ -f "$bit" ]; then bitinfo="build/results/$bitname.bit ($(date -r "$bit" '+%Y-%m-%d %H:%M'))"; fi
line="TIMING $verdict wns=$(fmt "$wns")"
[ -n "$whs" ] && line+=" whs=$(fmt "$whs")"
[ -n "$fail" ] && line+=" fail=$fail/$total"
[ -n "$stamp" ] && line+=" stamp=$stamp"
line+=" bit=$bitinfo"
echo "$line"

# ---- the DDR3 clock legs, from the build's forensics -----------------------
# CK reaching its pad later than the commands eats the DRAM's command setup,
# and DQS-to-CK has a +-0.625 ns window; neither is timed by Vivado, both are
# placement, and a bitstream that never calibrates is diffed on these numbers
# (docs/UBERDDR3.md).  Printed only when the forensics are this build's.
fx="$res/ddr3_forensics.txt"
if [ -f "$fx" ] && [ -f "$rpt" ] && [ "$(( $(stat -c %Y "$fx") - $(stat -c %Y "$rpt") ))" -lt 1800 ] && [ "$(( $(stat -c %Y "$rpt") - $(stat -c %Y "$fx") ))" -lt 1800 ]; then
    grep -E '^ +(slow|fast) corner:' "$fx" | sed 's/^ */ddr3: /'
fi

# ---- the depth audit vs the baseline ---------------------------------------
if [ -f "$depth" ]; then
    # rows: LVLS SLACK DPATH CLOCK START -> END ; keep "LVLS START -> END"
    rows() { awk -v t="$1" '$1 ~ /^[0-9]+$/ && $6 == "->" && $1 >= t {print $1, $5, $6, $7}' "$depth"; }
    if [ "$save" = 1 ]; then
        { echo "# logic-depth baseline: LVLS START -> END for every path at >= $tail_lvl levels"
          echo "# rewritten by build/wns.sh --save-baseline; a new endpoint here is a NEW DEEP TAIL"
          rows "$tail_lvl"; } > "$baseline"
        echo "baseline: $(grep -vc '^#' "$baseline") rows at >= $tail_lvl levels written to build/depth_baseline.txt"
    fi
    max_new="$(awk '$1 ~ /^[0-9]+$/ && $6 == "->" {if ($1>m) m=$1} END{print m+0}' "$depth")"
    n_new="$(awk '$1 ~ /^[0-9]+$/ && $6 == "->"' "$depth" | wc -l)"
    t_new="$(rows "$tail_lvl" | wc -l)"
    # THE BASELINE IS THE IIe's.  A IIgs netlist has a different core, no
    # fronts and a chipset the IIe has never had, so diffing its census
    # against the IIe's baseline compares two designs and calls the
    # difference a regression.  The census is still PRINTED - the max depth
    # and the tail count are worth reading on their own - but nothing is
    # called new until the IIgs has a baseline of its own, which it gets when
    # the design settles rather than now (docs/GS.md rung 4).
    if [ "${gs_build:-0}" = 1 ]; then
        echo "depth: max $max_new, $n_new paths >= 10; tail >= $tail_lvl: $t_new  (IIgs build: no baseline of its own yet, so nothing is called new)"
    elif [ -f "$baseline" ]; then
        max_old="$(grep -v '^#' "$baseline" | awk '{if ($1>m) m=$1} END{print m+0}')"
        t_old="$(grep -vc '^#' "$baseline" || true)"
        new_tail="$(comm -13 <(grep -v '^#' "$baseline" | awk '{print $2, $3, $4}' | sort -u) \
                            <(rows "$tail_lvl" | awk '{print $2, $3, $4}' | sort -u) || true)"
        n_tail="$(printf '%s' "$new_tail" | grep -c . || true)"
        echo "depth: max $max_new (was $max_old), $n_new paths >= 10; tail >= $tail_lvl: $t_new (was $t_old); NEW DEEP TAIL: ${n_tail:-0}$( [ "${n_tail:-0}" -gt 0 ] && echo ' endpoint(s):' )"
        [ "${n_tail:-0}" -gt 0 ] && printf '%s\n' "$new_tail" | head -20 | sed 's/^/    /'
    else
        echo "depth: max $max_new, $n_new paths >= 10; tail >= $tail_lvl: $t_new; no baseline (build/wns.sh --save-baseline)"
    fi
fi
[ "$verdict" = "MET" ] && exit 0 || exit 2
