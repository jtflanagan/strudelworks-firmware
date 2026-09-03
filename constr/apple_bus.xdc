# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
##############################################################################
# Apple bus - the board-neutral half: the false paths.
#
# The pins are generated per board into constr/<board>/apple_bus_pins.xdc
# from constr/pins/apple_bus.pins (see constr/ft601.xdc for why).
##############################################################################

#set_input_delay -clock [get_clocks clk_0] -min -add_delay 0.000 [get_ports apple_phi0_pin]
#set_input_delay -clock [get_clocks clk_0] -max -add_delay 0.001 [get_ports apple_phi0_pin]
# ---------------------------------------------------------------------------
# The Apple bus is ASYNCHRONOUS to clk_ctrl.  Every one of these pins enters
# through the 3-deep synchroniser in rtl/synchronizer.sv (2 ASYNC_REG stages
# plus an output register), so there is no phase relationship for static timing
# to check and no input delay that would mean anything.
#
# This is NOT the mistake DERISK.md records against the FT601.  There, a
# genuinely source-synchronous interface was left unconstrained with placeholder
# delays and false paths, so Vivado never checked when data reached the chip and
# placement silently decided whether the right word was sampled.  That interface
# has a clock and a timing relationship; this one does not.  Declaring a truly
# asynchronous input as a false path is correct.  Doing it to a synchronous one
# cost this project a milestone.
set_false_path -from [get_ports {apple_data_pin[*]}]
set_false_path -from [get_ports {apple_addr_pin[*]}]
set_false_path -from [get_ports {apple_rw_pin}]
set_false_path -from [get_ports {apple_phi0_pin}]
set_false_path -from [get_ports {apple_m2sel_pin}]
set_false_path -from [get_ports {apple_m2b0_pin}]
set_false_path -from [get_ports {apple_inh_pin}]
set_false_path -from [get_ports {apple_res_pin}]
set_false_path -from [get_ports {apple_irq_pin}]
set_false_path -from [get_ports {apple_rdy_pin}]
set_false_path -from [get_ports {apple_dma_pin}]
set_false_path -from [get_ports {tini_5v_pin}]

# Level-shifter controls.  tini_oe follows the 5 V rail in both builds; the two
# direction pins are tied to "towards the FPGA" in the snooper and follow the
# drive enables in the master.  Either way they are asynchronous to the Apple,
# for the reason above.
set_false_path -to [get_ports {apple_res_pin}]
set_false_path -to [get_ports {tini_oe_pin}]
set_false_path -to [get_ports {tini_addr_dir_pin}]
set_false_path -to [get_ports {tini_data_dir_pin}]
