# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# Standalone logic-depth audit against an existing routed checkpoint - the
# no-rebuild path to the same reports build.tcl now writes on every build.
#
#   vivado -mode batch -source build/depth.tcl -tclargs -dcp <routed.dcp> -outdir <dir>
#
# Driven by build/depth.sh, which knows where the last build's checkpoint lives.
# Timing of the two phases is printed separately because they answer different
# questions: the checkpoint open is the standalone overhead, the report time is
# what every build pays now that build.tcl calls the same procs inline.

set dcp       ""
set outdir    ""
set min_level 10

for {set i 0} {$i < $argc} {incr i} {
    switch -- [lindex $argv $i] {
        -dcp       { incr i; set dcp       [lindex $argv $i] }
        -outdir    { incr i; set outdir    [lindex $argv $i] }
        -min-level { incr i; set min_level [lindex $argv $i] }
        default    { puts "WARNING: ignoring unknown argument [lindex $argv $i]" }
    }
}
if {$dcp eq "" || $outdir eq ""} {
    puts "ERROR: need -dcp <routed.dcp> and -outdir <dir>"
    exit 1
}

source [file join [file dirname [info script]] depth_report.tcl]

set t0 [clock seconds]
open_checkpoint $dcp
set t1 [clock seconds]
write_depth_report   [file join $outdir logic_depth.rpt] $min_level
write_depth_histogram [file join $outdir design_analysis.rpt]
set t2 [clock seconds]

puts "=========================================================="
puts " checkpoint open : [expr {$t1 - $t0}] s"
puts " reports         : [expr {$t2 - $t1}] s   <- the per-build cost"
puts "=========================================================="
