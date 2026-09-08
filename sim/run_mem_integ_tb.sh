#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The whole memory path under the real core: the driver, the reader, the MMU
# shadow, the ROM loader, the page cache, the DDR3 client and the arbiter,
# running sim/mem_integ.s against a model of a 128K IIe with a language card -
# first tracking only, then serving every class under the running program.
# Verilator, about a minute.  See sim/mem_integ_tb.sv.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/mem_work"
mkdir -p "$work"

python3 "$root/sim/gen_microcode.py" --check

for t in ca65 ld65 xxd; do
    command -v "$t" > /dev/null || { echo "$t not found (apt install cc65 xxd)" >&2; exit 1; }
done
command -v verilator > /dev/null || { echo "verilator not found" >&2; exit 1; }
ca65 --cpu 65SC02 -l "$work/mem_integ.lst" -o "$work/mem_integ.o" "$root/sim/mem_integ.s"
ld65 -C "$root/sim/mem_integ.cfg" -o "$work/mem_integ.bin" "$work/mem_integ.o"
xxd -p -c1 "$work/mem_integ.bin" > "$work/mem_integ.hex"

verilator --binary --timing -j 4 -O1 -Wno-fatal --top-module mem_integ_tb \
    -I"$root/rtl" --Mdir "$work/obj_integ" \
    -GUCODE="\"$root/rtl/cpu65c02_ucode.hex\"" \
    -GPROG="\"$work/mem_integ.hex\"" \
    "$root/sim/mem_integ_tb.sv" "$root/rtl/cpu65c02.sv" \
    "$root/rtl/synchronizer.sv" "$root/rtl/apple_bus_read.sv" "$root/rtl/apple_bus_write.sv" \
    "$root/rtl/apple_mmu.sv" "$root/rtl/rom_loader.sv" "$root/rtl/page_cache.sv" \
    "$root/rtl/way_ram.sv" "$root/rtl/page_client.sv" "$root/rtl/wb_arb.sv" \
    > "$work/verilator_integ.log" 2>&1 || { tail -40 "$work/verilator_integ.log"; echo "compile failed" >&2; exit 1; }

"$work/obj_integ/Vmem_integ_tb" | tee "$work/mem_integ_tb.log" | grep -v "^\$finish"
grep -q '^PASS$' "$work/mem_integ_tb.log"
