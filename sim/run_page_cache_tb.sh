#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The page cache's two banks, its engine, the DDR3 client, the arbiter's
# priority slot and the ROM, against a Wishbone memory that acks like the
# DDR3 and a streaming client sharing the port.  ~30 s.  See
# sim/page_cache_tb.sv and docs/PAGE_CACHE.md.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/mem_work"
mkdir -p "$work"

rm -f "$work/page_cache_tb.out"
iverilog -g2012 -o "$work/page_cache_tb.out" -s page_cache_tb \
    "$root/sim/page_cache_tb.sv" "$root/rtl/page_cache.sv" "$root/rtl/bank_ram.sv" \
    "$root/rtl/apple_rom.sv" "$root/rtl/page_client.sv" "$root/rtl/wb_arb.sv" \
    2>&1 | grep -vE "sorry: constant selects|cannot be synthesized" || true
[ -f "$work/page_cache_tb.out" ] || { echo "compile failed" >&2; exit 1; }
vvp -N "$work/page_cache_tb.out" | tee "$work/page_cache_tb.log" | grep -vE "^\$finish|VCD"
grep -q '^PASS$' "$work/page_cache_tb.log" || exit 1
