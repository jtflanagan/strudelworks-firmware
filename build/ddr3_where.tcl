# Where the DDR3 controller, PHY and its delay controller landed in a routed
# checkpoint, and which banks the DDR3 pins are on - the hunt for a bitstream
# that never calibrates (docs/GS.md "The retained set and the DDR3",
# docs/IWM35.md "On hardware").
#   vivado -mode batch -source build/ddr3_where.tcl -tclargs -dcp X.dcp -out where.txt
set dcp ""; set out ""
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [lindex $argv $i] { -dcp {incr i; set dcp [lindex $argv $i]} -out {incr i; set out [lindex $argv $i]} }
}
open_checkpoint $dcp
set f [open $out w]
foreach {name pat} {controller u_card/u_ddr3/u_ddr3/ddr3_controller_inst/* phy u_card/u_ddr3/u_ddr3/ddr3_phy_inst/* wrapper u_card/u_ddr3/*} {
    set cells [get_cells -hierarchical -filter "NAME =~ $pat && IS_PRIMITIVE"]
    set regions [dict create]
    foreach c $cells {
        set s [get_property SITE $c]
        if {$s eq ""} continue
        dict incr regions [get_property CLOCK_REGION $s]
    }
    puts $f "== $name: [llength $cells] cells"
    dict for {r n} $regions { puts $f "   $r: $n" }
}
puts $f "== delay controllers and delays"
foreach c [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ IO.*IDELAYCTRL* || PRIMITIVE_TYPE =~ IO.*IDELAYE2* || PRIMITIVE_TYPE =~ IO.*ODELAYE2*}] {
    set s [get_property SITE $c]
    puts $f "   [get_property PRIMITIVE_TYPE $c] $c site=$s region=[get_property CLOCK_REGION $s] group=[get_property IODELAY_GROUP $c]"
}
puts $f "== clocks"
foreach c [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ CLOCK.*}] {
    puts $f "   [get_property PRIMITIVE_TYPE $c] $c site=[get_property SITE $c]"
}
puts $f "== DDR3 IO ports' banks"
set banks [dict create]
foreach p [get_ports ddr3_*] { dict incr banks [get_property IOBANK $p] }
dict for {b n} $banks { puts $f "   bank $b: $n pins" }
close $f
