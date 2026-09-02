# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# Logic-depth audit, shared between build.tcl (every build, on the design it
# just routed) and depth.tcl (standalone, on the last build's checkpoint).
# One proc in one file so the two flows cannot drift apart.
#
# The point of this report is the paths report_timing_summary HIDES: a deep
# path that happened to place well has good slack and never makes the worst-100
# list, but it is still one unlucky placement away from being the next WNS
# fight.  Depth is decided at synthesis, so it is auditable - and refactorable -
# before it ever becomes a timing problem.

proc write_depth_report {rptfile {min_level 10}} {
    # One path per endpoint, enumerated far past the design's endpoint count:
    # get_timing_paths walks worst-first BY SLACK, so a small -max_paths would
    # drop exactly the comfortable-but-deep paths this report exists to catch.
    set paths [get_timing_paths -setup -nworst 1 -max_paths 100000 \
                   -filter "LOGIC_LEVELS >= $min_level"]

    set rows {}
    foreach p $paths {
        lappend rows [list \
            [get_property LOGIC_LEVELS $p] \
            [get_property SLACK $p] \
            [get_property DATAPATH_DELAY $p] \
            [get_property ENDPOINT_CLOCK $p] \
            [get_property STARTPOINT_PIN $p] \
            [get_property ENDPOINT_PIN $p]]
    }

    set fp [open $rptfile w]
    puts $fp "Logic depth audit: every path at >= $min_level logic levels, deepest first,"
    puts $fp "one path per endpoint, regardless of slack."
    puts $fp ""
    puts $fp "LVLS counts every combinational cell between the flops - LUTs, but also"
    puts $fp "MUXF7/8 and CARRY4.  Read it next to DPATH (ns): a deep carry chain is"
    puts $fp "~40 ps per level and fine; a deep LUT chain is ~0.6-0.9 ns per level and"
    puts $fp "is the refactor candidate."
    puts $fp ""
    puts $fp [format "%4s %8s %7s  %-13s %s" LVLS SLACK DPATH CLOCK "STARTPOINT -> ENDPOINT"]
    foreach r [lsort -integer -decreasing -index 0 $rows] {
        lassign $r lvl slack dpath clk sp ep
        puts $fp [format "%4d %8.3f %7.3f  %-13s %s -> %s" $lvl $slack $dpath $clk $sp $ep]
    }
    puts $fp ""
    puts $fp "[llength $rows] paths at >= $min_level levels."
    close $fp
    puts "logic depth: [llength $rows] paths at >= $min_level levels -> $rptfile"
}

proc write_depth_histogram {rptfile} {
    # The companion histogram: logic-level distribution per endpoint clock.
    # -logic_level_dist_paths widens the sample beyond the default worst-1000
    # so the bins cover the design, not just the slack losers.  Older Vivados
    # cap the value; fall back to the default rather than losing the report.
    if {[catch {report_design_analysis -logic_level_distribution \
                    -logic_level_dist_paths 20000 -file $rptfile} err]} {
        puts "NOTE: wide histogram failed ($err) - falling back to default width"
        report_design_analysis -logic_level_distribution -file $rptfile
    }
}
