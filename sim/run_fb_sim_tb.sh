#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# The floating bus, simulated: the side copy of the display pages, the
# scanner's byte predicted in every video mode, compared with the machine's
# own floating bus on every read, and served to the core in its place -
# through the real reader, driver, core, hold, lock and MMU shadow against an
# Apple with Sather's scanner counters.  A few minutes.  See
# sim/fb_sim_tb.sv and docs/FLOATING_BUS.md.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/sim/fb_sim_tb.out"
iverilog -g2012 -I "$root/rtl" -o "$out" -s fb_sim_tb \
    -P fb_sim_tb.UCODE=\"$root/rtl/cpu65c02_ucode.hex\" \
    "$root/sim/fb_sim_tb.sv" \
    "$root/rtl/synchronizer.sv" \
    "$root/rtl/apple_bus_read.sv" \
    "$root/rtl/apple_bus_write.sv" \
    "$root/rtl/cpu65c02.sv" \
    "$root/rtl/boot_hold.sv" \
    "$root/rtl/vbl_lock.sv" \
    "$root/rtl/apple_mmu.sv" \
    \
    "$root/rtl/fb_sim.sv"
exec vvp -n "$out"
