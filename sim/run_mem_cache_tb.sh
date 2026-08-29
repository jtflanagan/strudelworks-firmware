#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The memory cache, its DDR3 client, the arbiter's priority slot and the ROM,
# against a Wishbone memory that acks like the DDR3 and a streaming client
# sharing the port.  Run at the default 512 sets and again at 64, so the
# parameter is exercised.  ~20 s.  See sim/mem_cache_tb.sv.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/mem_work"
mkdir -p "$work"

for sets in 512 64; do
    rm -f "$work/mem_cache_tb.out"
    iverilog -g2012 -o "$work/mem_cache_tb.out" -s mem_cache_tb \
        -Pmem_cache_tb.SETS=$sets \
        "$root/sim/mem_cache_tb.sv" "$root/rtl/mem_cache.sv" "$root/rtl/cache_way_ram.sv" \
        "$root/rtl/apple_rom.sv" "$root/rtl/mem_client.sv" "$root/rtl/wb_arb.sv" \
        2>&1 | grep -vE "sorry: constant selects|cannot be synthesized" || true
    [ -f "$work/mem_cache_tb.out" ] || { echo "compile failed" >&2; exit 1; }
    echo "== SETS=$sets"
    vvp -N "$work/mem_cache_tb.out" | tee "$work/mem_cache_tb_$sets.log" | grep -vE "^\$finish|VCD"
    grep -q '^PASS$' "$work/mem_cache_tb_$sets.log" || exit 1
done
