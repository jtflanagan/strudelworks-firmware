# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# FT601 output-enable placement, Pt V2 (xc7a100tfgg484) ONLY - hand-written,
# not generated, and site coordinates are this die's.
#
# rtl/ft601_fifo.sv keeps one output-enable flop per byte lane for the DATA
# pads (OE_data) and one per lane for the BE pad (OE_be), each driving its
# pads' OBUFT T inputs under constr/ft601.xdc's two-cycle multicycle.  Where
# the placer puts those flops decides the ft_clk_12 group's clock-to-out: on
# this board lanes 0 and 1 have their data pads on the LEFT edge (bank 16,
# IOB_X0Y51-72) and their BE pads on the RIGHT (bank 15, IOB_X1Y117-120, with
# lanes 2 and 3's everything, IOB_X1Y101-142).  Build mcb_nobrspec
# (2026-09-14) put all four of the old per-lane flops at SLICE_X88Y119, next
# to the right-hand pads, and lane 0's data enables crossed the die: 11 ns of
# net, -0.360 ns.  So: the left lanes' data enables live in the slices beside
# the left IOB column, everything else beside the right one.  Ranges checked
# on that build's checkpoint: 100 slices (12 used) and 184 (116 used).
create_pblock pb_ft_oe_left
add_cells_to_pblock [get_pblocks pb_ft_oe_left] [get_cells -hier -filter {NAME =~ *u_ft/OE_data_reg[0] || NAME =~ *u_ft/OE_data_reg[1]}]
resize_pblock [get_pblocks pb_ft_oe_left] -add {SLICE_X0Y50:SLICE_X3Y74}

create_pblock pb_ft_oe_right
add_cells_to_pblock [get_pblocks pb_ft_oe_right] [get_cells -hier -filter {NAME =~ *u_ft/OE_data_reg[2] || NAME =~ *u_ft/OE_data_reg[3] || NAME =~ *u_ft/OE_be_reg[*]}]
resize_pblock [get_pblocks pb_ft_oe_right] -add {SLICE_X86Y100:SLICE_X89Y145}
