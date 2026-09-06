#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The virtual beam against a reference, under Verilator.  Seconds.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/sim/vbeam_work"; mkdir -p "$work"
verilator --binary --timing -j 4 -O1 -Wno-fatal --top-module vbeam_tb -I"$root/rtl" --Mdir "$work/obj_vl" \
    "$root/sim/vbeam_tb.sv" "$root/rtl/vbeam.sv" > "$work/build.log" 2>&1 || { tail -30 "$work/build.log"; exit 1; }
exec "$work/obj_vl/Vvbeam_tb"
