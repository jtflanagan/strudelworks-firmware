# Where the DDR3 controller and PHY landed in a routed checkpoint: the bounding
# box of its cells, and the clock regions they span - against the IO bank.
set dcp ""; set out ""
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [lindex $argv $i] { -dcp {incr i; set dcp [lindex $argv $i]} -out {incr i; set out [lindex $argv $i]} }
}
open_checkpoint $dcp
set f [open $out w]
foreach {name pat} {controller u_card/u_ddr3/u_ddr3/ddr3_controller_inst/* phy u_card/u_ddr3/u_ddr3/ddr3_phy_inst/* wrapper u_card/u_ddr3/*} {
    set cells [get_cells -hierarchical -filter "NAME =~ $pat && IS_PRIMITIVE"]
    set regions [dict create]
    set xs {}; set ys {}
    foreach c $cells {
        set s [get_property SITE $c]
        if {$s eq ""} continue
        set cr [get_property CLOCK_REGION $s]
        dict incr regions $cr
        set rx [get_property RPM_X $s]; set ry [get_property RPM_Y $s]
        lappend xs $rx; lappend ys $ry
    }
    puts $f "== $name: [llength $cells] cells"
    dict for {r n} $regions { puts $f "   $r: $n" }
}
puts $f "== DDR3 IO ports' banks"
set banks [dict create]
foreach p [get_ports ddr3_*] { dict incr banks [get_property IOBANK $p] }
dict for {b n} $banks { puts $f "   bank $b: $n pins" }
close $f
