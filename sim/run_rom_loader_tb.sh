#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The formal ROM load (docs/CLEAN_START.md CS2): rtl/a2/rom_loader.sv with
# REQUIRE_HOLD, its acks and sums, against a host model.  See sim/rom_loader_tb.sv.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/rom_loader_work"
mkdir -p "$work"
verilator --binary --timing -j 4 -O2 -Wno-fatal --top-module rom_loader_tb \
    -I"$root/rtl/common" -I"$root/rtl/a2" -Mdir "$work/obj" \
    "$root/sim/rom_loader_tb.sv" "$root/rtl/a2/rom_loader.sv" \
    -o rom_loader > "$work/verilator.log" 2>&1 || {
        echo "build failed:" >&2; tail -30 "$work/verilator.log" >&2; exit 1; }
exec "$work/obj/rom_loader" "$@"
