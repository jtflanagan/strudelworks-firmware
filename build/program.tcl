# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 jtflanagan
##############################################################################
# Program the FPGA over JTAG using Vivado's Hardware Manager, WITHOUT opening
# the project.
#
#   vivado -mode batch -source build/program.tcl -tclargs <bitfile>
#
# The project lock that keeps breaking builds comes from having the PROJECT
# open, not from Vivado itself.  open_hw_manager touches no project, so this
# programs the board and leaves build/build.sh free to run.
#
# Used as the control against openFPGALoader: same bitstream, different loader.
##############################################################################

if {$argc < 1} {
    puts "usage: vivado -mode batch -source program.tcl -tclargs <bitfile>"
    exit 1
}
set bit [lindex $argv 0]
if {![file exists $bit]} {
    puts "ERROR: no such bitstream: $bit"
    exit 1
}

open_hw_manager
connect_hw_server -quiet
set targets [get_hw_targets -quiet]
if {[llength $targets] == 0} {
    puts "ERROR: no JTAG target. Is the board attached to WINDOWS?"
    puts "       If it is attached to WSL, detach first:  build/load.sh --detach"
    exit 1
}
current_hw_target [lindex $targets 0]
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
puts "device: [get_property PART $dev]"

set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "DONE property: [get_property REGISTER.IR.BIT5_DONE $dev]"

close_hw_target
disconnect_hw_server
close_hw_manager
puts "programmed: $bit"
