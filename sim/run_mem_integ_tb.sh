#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The whole memory path under the real core: the driver, the reader, the MMU
# shadow, the ROM, the page cache, the DDR3 client and the arbiter, running
# sim/mem_integ.s against a model of a 128K IIe with a language card - first
# tracking only, then serving every class under the running program.  ~1 min.
# See sim/mem_integ_tb.sv.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/mem_work"
mkdir -p "$work"

python3 "$root/sim/gen_microcode.py" --check

for t in ca65 ld65 xxd; do
    command -v "$t" > /dev/null || { echo "$t not found (apt install cc65 xxd)" >&2; exit 1; }
done
ca65 --cpu 65SC02 -l "$work/mem_integ.lst" -o "$work/mem_integ.o" "$root/sim/mem_integ.s"
ld65 -C "$root/sim/mem_integ.cfg" -o "$work/mem_integ.bin" "$work/mem_integ.o"
xxd -p -c1 "$work/mem_integ.bin" > "$work/mem_integ.hex"

rm -f "$work/mem_integ_tb.out"
if ! iverilog -g2012 -I "$root/rtl" -o "$work/mem_integ_tb.out" -s mem_integ_tb \
        -Pmem_integ_tb.UCODE="\"$root/rtl/cpu65c02_ucode.hex\"" \
        -Pmem_integ_tb.PROG="\"$work/mem_integ.hex\"" \
        "$root/sim/mem_integ_tb.sv" "$root/rtl/cpu65c02.sv" \
        "$root/rtl/synchronizer.sv" "$root/rtl/apple_bus_read.sv" "$root/rtl/apple_bus_write.sv" \
        "$root/rtl/apple_mmu.sv" "$root/rtl/apple_rom.sv" "$root/rtl/page_cache.sv" \
        "$root/rtl/bank_ram.sv" "$root/rtl/page_client.sv" "$root/rtl/wb_arb.sv" \
        > "$work/iverilog_integ.log" 2>&1; then
    grep -vE "sorry: constant selects|cannot be synthesized" "$work/iverilog_integ.log" >&2
    echo "compile failed" >&2
    exit 1
fi
vvp -N "$work/mem_integ_tb.out" | tee "$work/mem_integ_tb.log" | grep -v "^\$finish"
grep -q '^PASS$' "$work/mem_integ_tb.log"
