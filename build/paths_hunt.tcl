# The long-path hunt: the N worst setup paths of a routed checkpoint, one per
# endpoint, with their full cell chains - the census (build/depth.tcl) says
# which registers root the deep tail, this says which LUTs are on it.
#   vivado -mode batch -source build/paths_hunt.tcl -tclargs -dcp <routed.dcp> -out <file> [-n 40]
set dcp ""; set out ""; set n 40
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [lindex $argv $i] {
        -dcp {incr i; set dcp [lindex $argv $i]}
        -out {incr i; set out [lindex $argv $i]}
        -n   {incr i; set n   [lindex $argv $i]}
    }
}
if {$dcp eq "" || $out eq ""} { puts "ERROR: need -dcp <routed.dcp> -out <file>"; exit 1 }
open_checkpoint $dcp
report_timing -max_paths $n -nworst 1 -sort_by slack -unique_pins -file $out
