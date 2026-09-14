#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The DDR3 census across builds: one line per build/results/ddr3_forensics_*.txt
# with the clock legs static timing never checks (docs/UBERDDR3.md), and the
# timing verdict of the build's log when it is there.  The hardware side of
# the census (the eye masks and the calibrated tap, read over the link) is
# entered by hand in docs/UBERDDR3.md next to these.
#   build/ddr3_census.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
printf '%-20s %-7s %-9s %-9s %-9s %-9s %s\n' build wns ck-cmd tDQSS dqs-dq ck_cell ck_site
for f in "$root"/build/results/ddr3_forensics_*.txt; do
    [ -f "$f" ] || continue
    tag="$(basename "$f" .txt)"; tag="${tag#ddr3_forensics_}"
    slow="$(grep -m1 'slow corner:' "$f" || true)"
    ckcmd="$(sed -n 's/.*CK leg - CMD leg = \([-+0-9.]*\) ns.*/\1/p' <<<"$slow")"
    tdqss="$(sed -n 's/.*tDQSS = \([-+0-9.]*\) ns.*/\1/p' <<<"$slow")"
    dqsdq="$(sed -n 's/.*DQS - DQ at the pad = \([-+0-9.]*\) ns.*/\1/p' <<<"$slow")"
    drv="$(grep -m1 'driver:' "$f" || true)"
    cell="$(sed -n 's/.*REF=\([^ ]*\).*/\1/p' <<<"$drv")"; site="$(sed -n 's/.*site=\([^ ]*\).*/\1/p' <<<"$drv")"
    wns="-"
    log="$root/build/master_build_$tag.log"
    [ -f "$log" ] && wns="$(grep -E '^ setup WNS : ' "$log" | tail -1 | awk '{print $4}')"
    printf '%-20s %-7s %-9s %-9s %-9s %-9s %s\n' "$tag" "$wns" "${ckcmd:-?}" "${tdqss:-?}" "${dqsdq:-?}" "${cell:-?}" "${site:-?}"
done
