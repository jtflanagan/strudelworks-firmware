#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The physical page cache (rtl/a2/page_cache.sv), its engine, the DDR3 client,
# the arbiter's priority slot and a streaming client sharing the port, against
# a Wishbone memory that acks like the DDR3 - and against a full model of the
# cache, so the replacement policy is checked exactly and not merely plausibly.
#
# THE GEOMETRY IS SWEPT: 128x8 (the shipping shape), 64x10 (a way count that
# is not a power of two, on purpose) and 64x8.  Pass one as an argument to run
# it alone: sim/run_page_cache_tb.sh 64x10
#
# Verilator, about a minute for all three.  See sim/page_cache_tb.sv and
# docs/MEMORY_REFACTOR.md Part 3.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/mem_work"; mkdir -p "$work"
command -v verilator > /dev/null || { echo "verilator not found" >&2; exit 1; }

if [ $# -gt 0 ]; then geoms=("$@"); else geoms=(128x8 64x10 64x8 64x6); fi

fail=0
for g in "${geoms[@]}"; do
    sets="${g%x*}"; ways="${g#*x}"
    obj="$work/obj_$g"
    verilator --binary --timing -j 4 -O1 -Wno-fatal --top-module page_cache_tb \
        -GSETS="$sets" -GWAYS="$ways" \
        -I"$root/rtl/common" -I"$root/rtl/a2" --Mdir "$obj" \
        "$root/sim/page_cache_tb.sv" \
        "$root/rtl/a2/page_cache.sv" \
        "$root/rtl/a2/way_ram.sv" \
        "$root/rtl/common/page_client.sv" \
        "$root/rtl/common/wb_arb.sv" \
        > "$work/build_$g.log" 2>&1 || { echo "== $g: BUILD FAILED"; tail -30 "$work/build_$g.log"; fail=1; continue; }
    echo "== geometry $sets x $ways"
    if "$obj/Vpage_cache_tb" | tee "$work/run_$g.log" | grep -vE '^ok: '; then :; fi
    grep -q '^PASS$' "$work/run_$g.log" || fail=1
done
[ "$fail" = 0 ] || { echo "FAIL"; exit 1; }
echo "PASS"
