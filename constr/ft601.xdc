# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
##############################################################################
# FT601 interface - the board-neutral half: clock, timing, IOB packing.
#
# The pins are NOT here.  They are generated per board into
# constr/<board>/ft601_pins.xdc from constr/pins/ft601.pins, because the Ft+
# sits on the same connector pins of the Au V2 and the Pt V2 while the FPGA
# balls behind them differ.  Everything in this file names ports, not balls,
# and so applies unchanged to either board.
##############################################################################
# ft_clk => 100000000Hz
create_clock -period 10.0 -name ft_clk_12 -waveform {0.000 5.0} [get_ports ft_clk]
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks ft_clk_12]
#set_clock_groups -asynchronous -group [get_clocks -include_generated_clock -of_objects [get_ports ft_clk]]

# # ft_clk => 100000000Hz
# create_clock -period 10.0 -name ft_clk_0 -waveform {0.000 5.000} [get_ports ft_clk]
# set_property PACKAGE_PIN F5 [get_ports {ft_clk}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_clk}]
# set_property PACKAGE_PIN F3 [get_ports {ft_rxf}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_rxf}]
# set_property PACKAGE_PIN F4 [get_ports {ft_txe}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_txe}]
# set_property PACKAGE_PIN B7 [get_ports {ft_data[0]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_data[0]}]
# set_property PACKAGE_PIN A7 [get_ports {ft_data[1]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_data[1]}]
# set_property PACKAGE_PIN B6 [get_ports {ft_data[2]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_data[2]}]
# set_property PACKAGE_PIN B5 [get_ports {ft_data[3]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_data[3]}]
# set_property PACKAGE_PIN C3 [get_ports {ft_data[4]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_data[4]}]
# set_property PACKAGE_PIN C2 [get_ports {ft_data[5]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_data[5]}]
# set_property PACKAGE_PIN R6 [get_ports {ft_data[6]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_data[6]}]
# set_property PACKAGE_PIN R7 [get_ports {ft_data[7]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_data[7]}]
# set_property PACKAGE_PIN C7 [get_ports {ft_data[8]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_data[8]}]
# set_property PACKAGE_PIN C6 [get_ports {ft_data[9]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_data[9]}]
# set_property PACKAGE_PIN R12 [get_ports {ft_data[10]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_data[10]}]
# set_property PACKAGE_PIN T12 [get_ports {ft_data[11]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_data[11]}]
# set_property PACKAGE_PIN T9 [get_ports {ft_data[12]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_data[12]}]
# set_property PACKAGE_PIN T10 [get_ports {ft_data[13]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_data[13]}]
# set_property PACKAGE_PIN B4 [get_ports {ft_data[14]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_data[14]}]
# set_property PACKAGE_PIN A3 [get_ports {ft_data[15]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_data[15]}]
# set_property PACKAGE_PIN G2 [get_ports {ft_be[0]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_be[0]}]
# set_property PACKAGE_PIN G1 [get_ports {ft_be[1]}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_be[1]}]
# set_property PACKAGE_PIN D3 [get_ports {ft_rd}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_rd}]
# set_property PACKAGE_PIN E3 [get_ports {ft_wr}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_wr}]
# set_property PACKAGE_PIN E5 [get_ports {ft_oe}]
# set_property IOSTANDARD LVCMOS33 [get_ports {ft_oe}]
# # set_clock_groups -group [get_clocks -include_generated_clocks clk_0] \
# #   -group [get_clocks -include_generated_clocks ft_clk_0] -asynchronous
# set_clock_groups -async -group [get_clocks -include_generated_clocks ft_clk_0]

# set_input_delay -clock [get_clocks ft_clk_0] -min -add_delay 0.000 [get_ports ft_rxf]
# set_input_delay -clock [get_clocks ft_clk_0] -max -add_delay 0.001 [get_ports ft_rxf]
# set_input_delay -clock [get_clocks ft_clk_0] -min -add_delay 0.000 [get_ports ft_txe]
# set_input_delay -clock [get_clocks ft_clk_0] -max -add_delay 0.001 [get_ports ft_txe]
# set_output_delay -clock [get_clocks ft_clk_0] -min -add_delay 0.000 [get_ports {ft_data[*]}]
# set_output_delay -clock [get_clocks ft_clk_0] -max -add_delay 0.001 [get_ports {ft_data[*]}]
# set_false_path -to [get_ports {ft_data[*]}]
# set_output_delay -clock [get_clocks ft_clk_0] -min -add_delay 0.000 [get_ports {ft_be[*]}]
# set_output_delay -clock [get_clocks ft_clk_0] -max -add_delay 0.001 [get_ports {ft_be[*]}]
# set_false_path -to [get_ports {ft_be[*]}]
# set_output_delay -clock [get_clocks ft_clk_0] -min -add_delay 0.000 [get_ports {ft_oe}]
# set_output_delay -clock [get_clocks ft_clk_0] -max -add_delay 0.001 [get_ports {ft_oe}]
# set_false_path -to [get_ports {ft_oe}]
# set_output_delay -clock [get_clocks ft_clk_0] -min -add_delay 0.000 [get_ports {ft_rd}]
# set_output_delay -clock [get_clocks ft_clk_0] -max -add_delay 0.001 [get_ports {ft_rd}]
# set_false_path -to [get_ports {ft_rd}]
# set_output_delay -clock [get_clocks ft_clk_0] -min -add_delay 0.000 [get_ports {ft_wr}]
# set_output_delay -clock [get_clocks ft_clk_0] -max -add_delay 0.001 [get_ports {ft_wr}]
# set_false_path -to [get_ports {ft_wr}]
##############################################################################
# FT601 interface timing.
#
# WHY THIS SECTION EXISTS.  Everything above only assigns pins.  Until this was
# added, Vivado reported "34 input ports with no input delay specified (HIGH)"
# and "40 ports with no output delay specified (HIGH)" - meaning the entire
# FT601 bus was placed with no check on when data actually reaches the chip.
#
# That is not a cosmetic omission.  With the interface unconstrained, whether the
# FT601 samples the new word or the previous one is decided by placement, so the
# link flips between byte-perfect and duplicating a third (or all) of its words
# depending on what else happens to be in the design.  Adding an unrelated UART
# receiver was enough to flip it, at completely unchanged throughput.  This is
# the mechanism behind the board's long history of unexplained flakiness.
#
# The commented-out block further up is a v5 artefact: auto-generated with
# placeholder 0.000/0.001 values and then defeated anyway by set_false_path on
# the same ports.  Do not re-enable it.
#
# VALUES ARE ESTIMATES AND MUST BE CONFIRMED against DS_FT600Q-FT601Q before
# this is trusted.  They are deliberately conservative: an approximately right
# constraint makes the tool optimise and report, which is strictly better than no
# constraint at all, but a wrong one closes timing against the wrong target.
#
#   FT601_TSU  data/control setup before the FT601's sampling edge
#   FT601_TH   hold after it
#
# Launch is on ft_clk_neg (180 deg), so nominally 5 ns is available.
##############################################################################

# This interface is SOURCE-SYNCHRONOUS in both directions: the FT601 drives
# CLKOUT alongside the signals, over the same board-to-board connector, so flight
# time is common-mode and cancels.  These numbers therefore model the chip's
# setup/hold window plus SKEW - not absolute propagation delay.  An earlier
# revision budgeted absolute flight time and over-constrained the inputs badly.
# DS_FT600Q-FT601Q Table 4.2, measured values - no longer estimates.
#   T3 Master Drive Data Set Up Time   1.0 ns min
#   T4 Master Drive Data Hold Time     4.8 ns min
#
# T4 goes to -min as a POSITIVE value, matching pcileech-fpga.  That is what
# actually enforces the chip's hold window: our data must not change until 4.8 ns
# after the sampling edge, and the IOB clock-to-out (~5 ns) is what satisfies it.
# Written as -min -4.8 the check is vacuous - it passes whatever the design does,
# which is how output hold went unverified here for several builds.
set FT601_TSU 1.0
set FT601_TH  4.8

set ft601_outs [get_ports {ft_data[*] ft_be[*] ft_wr ft_rd ft_oe}]
set_output_delay -clock [get_clocks ft_clk_12] -max  $FT601_TSU -add_delay $ft601_outs
set_output_delay -clock [get_clocks ft_clk_12] -min $FT601_TH -add_delay $ft601_outs

# Inputs from the chip: clock-to-out of the FT601 relative to the same clock.
# Likewise for the chip's own clock-to-out: skew relative to the clock that
# accompanies the data, not flight time across the connector.
# Table 4.2 for the other direction:
#   T1 Slave Drive Data Set Up Time    3.0 ns min
#   T2 Slave Drive Data Hold Time      3.5 ns min
#
# The chip's data is valid from T1 before our capture edge until T2 after it, so
# it straddles the edge and was therefore launched by the PREVIOUS one.  Say that
# directly, with positive delays measured from that previous edge:
#
#   -max = period - T1 = 7.0   latest the data can settle
#   -min = period - T2 = 6.5   earliest it can start changing
#
# Both measured from the previous edge.  These are pcileech-fpga's exact numbers
# (-min 6.5 / -max 7.0), which is a useful corroboration of the datasheet reading.
#
# Written the other way round - negative delays relative to the capture edge,
# -max -3.0 / -min -6.5 - the arithmetic is equivalent but the hold check is not:
# it launches from the SAME edge and reads -6.5 as data arriving 6.5 ns early,
# reporting -5.729 ns on ft_txe and ft_rxf.  Those were phantom violations on a
# link that was byte-perfect, and a report that cries wolf is nearly as harmful
# as one that stays silent.
set FT601_T1 3.0
set FT601_T2 3.5
set FT601_PERIOD 10.0

set ft601_ins [get_ports {ft_rxf ft_txe}]
set_input_delay -clock [get_clocks ft_clk_12] -max [expr {$FT601_PERIOD - $FT601_T1}] -add_delay $ft601_ins
set_input_delay -clock [get_clocks ft_clk_12] -min [expr {$FT601_PERIOD - $FT601_T2}] -add_delay $ft601_ins

# Pack the FT601 interface registers into the IOBs.
#
# For ft_txe / ft_rxf this is the point of the input registers added in
# ft601_fifo.sv: an IOB flop sits at the pad, so the chip's clock-to-out and the
# board delay are absorbed by a setup check with large margin, instead of being
# prepended to a combinational path through the state machine.  Without the
# packing the flop can be placed in the fabric and most of the benefit is lost.
#
# ft_data is a tristate driven combinationally from the FIFO output, so there is
# no register for Vivado to pull in here and this does nothing for it yet.
# Registering the outbound bus in the IOB - data plus the OBUFT enable, which
# must be packed together or they skew apart - is the remaining half of the fix.
# IOB packing and the tristate multicycle, matching the reference cell-for-cell
# (PCIeSquirrel/src/pcileech_squirrel.xdc):
#
#   IOB TRUE on FT601_OE_N_reg, FT601_RD_N_reg, FT601_WR_N_reg,
#              FT601_DATA_OUT_reg[0][*]
#   set_multicycle_path 2 -from OE_data_reg[*]/C, OE_be_reg[*]/C -to the data and be ports (one enable
#   flop per byte lane for the data pads and one for the BE pad; pinned by the board's ft601_place.xdc)
#
# The head of the output queue is what drives the pins, so only slot 0 is packed.
# The tristate enable is deliberately NOT packed - an IOB's output and tristate
# flops share a control set and cannot both be satisfied, and forcing it makes
# placement infeasible.  The multicycle is what takes it off the critical path,
# and it is sound because OE changes once per burst while the data changes every
# cycle.
#
# There is no IOB property on ft_txe / ft_rxf: the controller reads those pins
# combinationally, as the reference does, so there are no input registers to pack.
set_property IOB TRUE [get_cells -hier -filter {NAME =~ *u_ft/DATA_OUT_reg[0][*]}]
set_property IOB TRUE [get_cells -hier -filter {NAME =~ *u_ft/ft_oe_reg}]
set_property IOB TRUE [get_cells -hier -filter {NAME =~ *u_ft/ft_rd_reg}]
set_property IOB TRUE [get_cells -hier -filter {NAME =~ *u_ft/ft_wr_reg}]

set_property SLEW FAST [get_ports {ft_data[*] ft_be[*] ft_wr ft_rd ft_oe}]

set_multicycle_path 2 -from [get_pins -hier -filter {NAME =~ *u_ft/OE_data_reg[*]/C}] -to [get_ports {ft_data[*]}]
set_multicycle_path 2 -from [get_pins -hier -filter {NAME =~ *u_ft/OE_be_reg[*]/C}] -to [get_ports {ft_be[*]}]
