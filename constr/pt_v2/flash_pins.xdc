# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# The configuration flash's pins after configuration (docs/BOOT_LOADER.md), Pt V2
# (xc7a100tfgg484).  The card tops (a2_top, gs_top) have these ports; card_link's flash
# block (rtl/common/flash_ctrl.sv) drives them.
#
# The flash is a Microchip SST26VF032B on bank 14's multi-function pins; once the
# FPGA is configured they are ordinary user I/O.  CCLK (L12, bank 0) is not here:
# it is reached only through STARTUPE2's USRCCLKO.  Pins from Alchitry Labs V2's
# PtV2TopPin.kt (SPI_SS T19, SPI_D0..D3 P22 R22 P21 R21), the same source as
# ref/alchitry_pt_v2_pins.tsv.  Bank 14 is at 3.3 V (CONFIG_VOLTAGE 3.3, board.xdc).

set_property PACKAGE_PIN T19 [get_ports flash_cs_n]
set_property PACKAGE_PIN P22 [get_ports flash_mosi]
set_property PACKAGE_PIN R22 [get_ports flash_miso]
set_property PACKAGE_PIN P21 [get_ports flash_wp_n]
set_property PACKAGE_PIN R21 [get_ports flash_hold_n]
set_property IOSTANDARD LVCMOS33 [get_ports {flash_cs_n flash_mosi flash_miso flash_wp_n flash_hold_n}]

# The SPI runs at clk/4 (25 MHz) and flash_exec samples MISO at the end of SCK's
# high phase, a half period (20 ns) either side of the flash's edges.  SCK itself
# leaves through STARTUPE2, which the tools do not time to a pin, so these ports
# are not timed against it either: the margin is by construction, not by analysis.
set_false_path -to   [get_ports {flash_cs_n flash_mosi flash_wp_n flash_hold_n}]
set_false_path -from [get_ports flash_miso]
