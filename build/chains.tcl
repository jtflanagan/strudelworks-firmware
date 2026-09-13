# The deep logic chains of a routed checkpoint, cell by cell, without routing:
# the worst paths by LOGIC LEVELS outside the DDR3 controller, each printed as
# its sequence of cells (LUT/MUXF/CARRY) with the pins, so the chain can be
# read against the RTL and cut.  build/depth.sh's logic_depth.rpt names the
# endpoints; this names what is between them.
#   vivado -mode batch -source build/chains.tcl -tclargs -dcp X.dcp -out chains.txt [-n 40] [-min 15]
set dcp ""; set out ""; set n 40; set minlv 15; set match "*"
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [lindex $argv $i] {
        -dcp {incr i; set dcp [lindex $argv $i]} -out {incr i; set out [lindex $argv $i]}
        -n {incr i; set n [lindex $argv $i]} -min {incr i; set minlv [lindex $argv $i]}
        -match {incr i; set match [lindex $argv $i]}
    }
}
open_checkpoint $dcp
set paths [get_timing_paths -setup -nworst 1 -max_paths 100000 -filter "LOGIC_LEVELS >= $minlv"]
set keep {}
foreach p $paths {
    set sp [get_property STARTPOINT_PIN $p]
    set ep [get_property ENDPOINT_PIN $p]
    if {[string match *u_ddr3* $sp] || [string match *u_ddr3* $ep]} continue
    if {![string match "*$match*" $ep] && ![string match "*$match*" $sp]} continue
    lappend keep $p
}
# deepest first, then least slack
set keep [lsort -command {apply {{a b} {
    set la [get_property LOGIC_LEVELS $a]; set lb [get_property LOGIC_LEVELS $b]
    if {$la != $lb} { return [expr {$lb - $la}] }
    set sa [get_property SLACK $a]; set sb [get_property SLACK $b]
    return [expr {$sa < $sb ? -1 : ($sa > $sb ? 1 : 0)}]
}}} $keep]
set f [open $out w]
puts $f "[llength $keep] paths at >= $minlv logic levels outside the DDR3; the first $n, cell by cell"
set k 0
foreach p $keep {
    if {$k >= $n} break
    incr k
    puts $f "\n== $k: [get_property LOGIC_LEVELS $p] levels, slack [get_property SLACK $p], datapath [get_property DATAPATH_DELAY $p], logic [get_property DATAPATH_LOGIC_DELAY $p], net [get_property DATAPATH_NET_DELAY $p]"
    puts $f "   [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p]"
    foreach c [get_cells -of_objects $p -filter {IS_PRIMITIVE && PRIMITIVE_GROUP != FLOP_LATCH}] {
        puts $f "     [get_property REF_NAME $c]  $c"
    }
}
close $f
