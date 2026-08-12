# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 jtflanagan
##############################################################################
# Alchitry Au board pins - xc7a35t-ftg256-2
#
# Carried over verbatim from AppleTini v5
# (v5/verilog/v5_1_3/v5_1_3.srcs/constrs_1/new/alchitry.xdc).
# These are on-SOM pins, so they survive the carrier-board redesign untouched.
##############################################################################

# 100 MHz on-board oscillator.  Everything - controller, DDR3 PHY, IDELAYCTRL
# reference and the Apple-bus domain - is derived from this by rtl/clk_gen.v.
set_property PACKAGE_PIN N14 [get_ports clk_pin]
set_property IOSTANDARD LVCMOS33 [get_ports clk_pin]
create_clock -period 10.000 -name clk_100 -waveform {0.000 5.000} [get_ports clk_pin]

# Board RESET button, active low.
set_property PACKAGE_PIN P6 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]
set_false_path -from [get_ports rst_n]

# 8 on-board LEDs.
set_property PACKAGE_PIN K13 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]
set_property PACKAGE_PIN K12 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]
set_property PACKAGE_PIN L14 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[2]}]
set_property PACKAGE_PIN L13 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[3]}]
set_property PACKAGE_PIN M15 [get_ports {led[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[4]}]
set_property PACKAGE_PIN M14 [get_ports {led[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[5]}]
set_property PACKAGE_PIN M12 [get_ports {led[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[6]}]
set_property PACKAGE_PIN P14 [get_ports {led[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[7]}]
set_false_path -to [get_ports {led[*]}]

# USB-serial bridge on the Au (the FTDI on the Au itself, not the Ft+ FT601).
set_property PACKAGE_PIN P15 [get_ports usb_rx]
set_property IOSTANDARD LVCMOS33 [get_ports usb_rx]
set_property PACKAGE_PIN P16 [get_ports usb_tx]
set_property IOSTANDARD LVCMOS33 [get_ports usb_tx]
set_false_path -from [get_ports usb_rx]
set_false_path -to [get_ports usb_tx]

##############################################################################
# Bitstream / configuration
#
# The Au boots from a QSPI flash via its on-board microcontroller.  These were
# commented out in the v5 alchitry.xdc; they are enabled here because a
# standalone Vivado flow (no Alchitry Labs wrapper) has to set them itself.
##############################################################################
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR NO [current_design]
