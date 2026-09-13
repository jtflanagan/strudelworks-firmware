# Full timing detail (per-hop fanout, net and cell delay) for the worst path to
# each endpoint pattern given: the routing view of a chain build/chains.tcl
# listed.  vivado -mode batch -source build/chains_detail.tcl -tclargs -dcp X -out F -to PAT1 -to PAT2 ...
set dcp ""; set out ""; set pats {}
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [lindex $argv $i] { -dcp {incr i; set dcp [lindex $argv $i]} -out {incr i; set out [lindex $argv $i]} -to {incr i; lappend pats [lindex $argv $i]} }
}
open_checkpoint $dcp
set f [open $out w]
foreach pat $pats {
    set p [get_timing_paths -setup -max_paths 1 -nworst 1 -to [get_pins -hier -filter "NAME =~ *$pat*"]]
    puts $f "\n######## worst path to $pat"
    puts $f [report_timing -of_objects $p -return_string]
}
close $f
