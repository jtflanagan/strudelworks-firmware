# One full timing path per failing group of the gs_r6fronts build (docs/GS.md rung 6).
set dcp ""; set out ""
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [lindex $argv $i] { -dcp {incr i; set dcp [lindex $argv $i]} -out {incr i; set out [lindex $argv $i]} }
}
open_checkpoint $dcp
set starts {
    {g_65816.u_cpu/pc_reg[2]}
    {u_rom/seen_reg[82]}
    {u_hd/pidx_reg[2]}
    {u_fd/drive_sel_reg}
    {u_u2/x_i_reg[4]}
    {g_fronts.u_dline/dq_sx_reg[4][1]}
    {g_fronts.u_dline/dq_st_reg[0][1]}
}
set first 1
foreach s $starts {
    if {$first} { report_timing -from [get_cells $s] -max_paths 1 -nworst 1 -file $out; set first 0 } \
    else        { report_timing -from [get_cells $s] -max_paths 1 -nworst 1 -file $out -append }
}
