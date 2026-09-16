# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# The DDR3 controller and PHY kept in the two clock regions beside their IO
# bank, Pt V2 (xc7a100tfgg484) ONLY - hand-written, not generated.
#
# WHY.  docs/UBERDDR3.md's census ("the same RTL, build after build") found the
# DDR3 numbers - the clock legs, both eyes, the tap, the DQS index - identical
# across four placements, and concluded that calibration no longer depends on
# where the placer puts the fabric.  That held for four builds and then stopped:
# on 2026-09-16 a GS build that MET timing at +0.003, whose section-A/B
# forensics were IDENTICAL to the builds that calibrate (CK - CMD +0.052 ns,
# tDQSS +0.016 ns, the same OLOGIC sites for CK, CMD, DQS and DQ), never
# reached D=1 on the card.  It stuck at K=00 with M=0E - CHECK_STARTING_DATA,
# the read-back of the alignment pattern - and self-restarted past the counter's
# ceiling (X=FF) within a second of configuration, on three loads and across a
# power cycle of the board.  Two builds known to calibrate, gs_cs16 and
# gs_ddr3_var3, were loaded between and came up D=1 K=17 M=17 X=00, so the
# board, the DRAM and the cable are not the variable.
#
# The one physical difference is in section D.  Both calibrating builds put the
# whole wrapper in X0Y2 + X0Y3 (gs_cs16: 4797 + 1781 of 6586 cells, the PHY 146
# + 51) beside IO bank 15, whose 48 pins carry the whole interface.  The failing
# build - 60.6% LUTs, 82.4% slice occupancy - had been pushed a region further
# out: 261 wrapper cells in X0Y1, 229 of them the controller's, and one cell of
# the PHY itself.  Static timing cannot see the cost of that, because the 48
# DQ/DQS pins carry no input-delay constraint by design (the PHY centres its own
# read window on IDELAY taps), which is the same blind spot DERISK.md names.
#
# So the island is pinned rather than left to the placer's pressure relief.  The
# range is what the calibrating builds chose for themselves, not a tighter one:
# this constrains WHERE the wrapper may go, and does not pack it.
create_pblock pb_ddr3
add_cells_to_pblock [get_pblocks pb_ddr3] [get_cells -hier -filter {NAME =~ *u_card/u_ddr3}]
resize_pblock [get_pblocks pb_ddr3] -add {CLOCKREGION_X0Y2:CLOCKREGION_X0Y3}
