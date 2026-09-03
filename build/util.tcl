# Hierarchical utilization and the worst paths of a routed checkpoint.
#   vivado -mode batch -source build/util.tcl -tclargs -dcp X -outdir Y
set dcp ""; set outdir "."
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [lindex $argv $i] {
        -dcp    { incr i; set dcp [lindex $argv $i] }
        -outdir { incr i; set outdir [lindex $argv $i] }
    }
}
open_checkpoint $dcp
report_utilization -hierarchical -hierarchical_depth 2 -file [file join $outdir utilization_hier.rpt]
report_timing -max_paths 40 -nworst 1 -unique_pins -sort_by slack -file [file join $outdir timing_paths.rpt]
