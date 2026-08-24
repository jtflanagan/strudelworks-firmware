# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# The master build only.  apple_bus.xdc constrains these pins as INPUTS, which
# is all the snooper needs; this adds the other direction for the build that
# drives them.
#
# WHY FALSE PATHS AND NOT OUTPUT DELAYS, and why that is not the FT601 mistake
# again.  The Apple bus is asynchronous to clk_ctrl: there is no clock shared
# with the machine, so there is no phase relationship static timing could check
# and no set_output_delay that would mean anything.  What actually places these
# signals correctly is the tap pipeline in rtl/apple_bus_write.sv, which counts
# fabric cycles from a phi0 edge - timing that only a simulation or a capture
# can check, never the timing engine.
#
# The FT601 mistake was the opposite case: a genuinely source-synchronous
# interface left unconstrained with placeholder delays, so Vivado never checked
# when data reached the chip and placement silently decided whether the right
# word was sampled.  That interface has a clock.  This one does not.
#
# What DOES have to hold here is that the driven pins settle inside one fabric
# cycle so the tap counts mean what they say.  That is an ordinary
# register-to-pin path and Vivado meets it comfortably at 100 MHz; the false
# path is about the relationship to the Apple, not about the pin delay.
set_false_path -to [get_ports {apple_data_pin[*]}]
set_false_path -to [get_ports {apple_addr_pin[*]}]
set_false_path -to [get_ports {apple_rw_pin}]
set_false_path -to [get_ports {apple_dma_pin}]
