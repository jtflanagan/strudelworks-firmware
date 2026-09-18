#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# The DDR3 census that LOADS every build (docs/UBERDDR3.md rung 4): for each
# placer directive, build the master tree with it, keep the bit under its tag,
# load it into the card, read the UART line, and append one line to
# build/results/ddr3_census_hw.txt: the tag, the timing verdict, the report's
# forensics numbers, and what the card said - D (calibrated), K/M/X, D1..D3
# (DDR3_DBG1..3, PROTOCOL.md), the write-level feedback decoded.  A build that
# does not calibrate is the finding; the loop goes on so the sample grows.
#
#   build/ddr3_census_run.sh ExtraNetDelay_high AltSpreadLogic_high ExtraTimingOpt
#   PREFIX=cen2 build/ddr3_census_run.sh ...     # tags PREFIX_<directive, lower case>
#
# swhost must be stopped (build/load_card.sh refuses otherwise).  The card is
# left holding the LAST build; start swhost on a calibrating one afterwards.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="${PREFIX:-cen}"
out="$root/build/results/ddr3_census_hw.txt"
[ -f "$out" ] || printf '%-24s %-9s %-8s %-8s %-9s  %s\n' build wns tDQSS dqs-dq depth 'card: D K M X D1 D2 D3 (WL feedback)' > "$out"
for d in "$@"; do
    tag="${prefix}_$(tr 'A-Z' 'a-z' <<<"$d")"
    echo "== $tag: build/run_build.sh $tag --board pt_v2 -place-directive $d"
    "$root/build/run_build.sh" "$tag" --board pt_v2 -place-directive "$d" > /dev/null 2>&1
    log="$root/build/master_build_$tag.log"
    # The verdict is what build/wns.sh says of the results just written (run_build.sh
    # prints it to its stdout, not into the log); the log has Vivado's own numbers.
    verdict="$(cd "$root" && build/wns.sh 2>/dev/null | grep -m1 -o 'TIMING MET wns=[-+0-9.]*\|TIMING MISS wns=[-+0-9.]*' || echo 'NO VERDICT')"
    wns="$(sed 's/.*wns=//' <<<"$verdict")"; [ "$verdict" = "NO VERDICT" ] && wns="none"
    depth="$(grep -m1 -A3 'End Point Clock' "$root/build/results/design_analysis.rpt" 2>/dev/null | grep clk_ctrl_raw | awk -F'|' '{n=0; for(i=4;i<=NF;i++) if($i+0>0) n=i-4; print n}')"
    fx="$root/build/results/ddr3_forensics_$tag.txt"
    slow="$(grep -m1 'slow corner:' "$fx" 2>/dev/null || true)"
    tdqss="$(sed -n 's/.*tDQSS = \([-+0-9.]*\) ns.*/\1/p' <<<"$slow")"
    dqsdq="$(sed -n 's/.*DQS - DQ at the pad = \([-+0-9.]*\) ns.*/\1/p' <<<"$slow")"
    bit="$root/build/results/master_top.bit"
    cp -f "$bit" "$root/build/results/master_top_$tag.bit"
    card="not loaded"
    if grep -q 'TIMING MET' <<<"$verdict"; then
        if "$root/build/load_card.sh" "$bit" > "$root/build/results/load_$tag.log" 2>&1; then
            sleep 4
            line="$("$root/build/report.sh" -n 2 2>/dev/null | grep -m1 'K=' || true)"
            if [ -n "$line" ]; then
                d2="$(sed -n 's/.* D2=\([0-9A-F]*\).*/\1/p' <<<"$line")"
                wl="?"
                if [ -n "$d2" ]; then
                    v=$((16#$d2)); done_=$(( (v>>31)&1 )); l1=$(( (v>>30)&1 )); l0=$(( (v>>29)&1 ))
                    wl="WL sampled=$done_ lane0=$l0 lane1=$l1 ($( [ $l0 = 1 ] && echo late || echo early)/$( [ $l1 = 1 ] && echo late || echo early))"
                fi
                card="$(sed 's/^.* D=/D=/' <<<"$line" | tr -d '\r') $wl"
            else
                card="UART silent"
            fi
        else
            card="LOAD FAILED (build/results/load_$tag.log)"
        fi
    else
        card="$verdict - not loaded"
    fi
    printf '%-24s %-9s %-8s %-8s %-9s  %s\n' "$tag" "$wns" "${tdqss:-?}" "${dqsdq:-?}" "${depth:-?}" "$card" | tee -a "$out"
done
