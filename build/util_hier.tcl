# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# Hierarchical utilisation from a ROUTED CHECKPOINT.  build/results/utilization_hier.rpt
# is NOT written by build.sh - the copy in the tree was left by a hand run on
# 2026-09-02, for the Au V2's xc7a35t, and reading it for a Pt V2 build is
# reading the wrong board (2026-09-13).  This makes a current one:
#
#   build/util_hier.sh                     # the last build's checkpoint
#   build/util_hier.sh -depth 3            # deeper
set dcp ""; set out ""; set depth 2
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [lindex $argv $i] {
        -dcp   {incr i; set dcp   [lindex $argv $i]}
        -out   {incr i; set out   [lindex $argv $i]}
        -depth {incr i; set depth [lindex $argv $i]}
    }
}
open_checkpoint $dcp
report_utilization -hierarchical -hierarchical_depth $depth -file $out
puts "util_hier: wrote $out at depth $depth"
