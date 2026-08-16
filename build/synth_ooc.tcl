# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 jtflanagan
##############################################################################
# Out-of-context synthesis of a single module, for resource estimation.
#
#   vivado -mode batch -source build/synth_ooc.tcl -tclargs \
#          -top cpu65c02 -src rtl/cpu65c02.sv -period 10.0
#
# Non-project mode on purpose.  This answers "how big is this block", not "does
# the board build", so there is no project, no bitstream and no board
# constraints - just the module, a clock, and the numbers.
#
# OUT OF CONTEXT means no I/O buffers are inserted.  That matters for honesty of
# the result: synthesised as a top level in the normal way, every port would get
# an IBUF/OBUF and the LUT count would be inflated by pad logic this block will
# never have, because it is going to be instantiated inside a larger top.  It
# also means the port count is not checked against any package, so a module with
# more ports than the device has pins still reports a sane area.
#
# The flow runs all the way to routed rather than stopping at synthesis.
# Post-synthesis utilisation is an estimate of an estimate: it counts LUTs before
# placement has had a chance to absorb them into carry chains and before
# opt_design removes what it can.  The post-route number is the one to quote.
##############################################################################

set root [file normalize [file join [file dirname [info script]] ..]]

set part    xc7a35tftg256-2
set top     ""
set srcs    {}
set period  10.0
set outdir  [file join $root build ooc]

for {set i 0} {$i < $argc} {incr i} {
    switch -- [lindex $argv $i] {
        -top    { incr i; set top    [lindex $argv $i] }
        -src    { incr i; lappend srcs [lindex $argv $i] }
        -part   { incr i; set part   [lindex $argv $i] }
        -period { incr i; set period [lindex $argv $i] }
        -outdir { incr i; set outdir [lindex $argv $i] }
        default { puts "WARNING: ignoring unknown argument [lindex $argv $i]" }
    }
}

if {$top eq "" || [llength $srcs] == 0} {
    puts "ERROR: need -top <module> and at least one -src <file>"
    exit 1
}

file mkdir $outdir

# A blank part list here is a LICENSING TIER problem, not a broken install - the
# tier decides which devices are visible, and an Alveo-only tier shows none of
# the 7-series.  Say so, because "could not get a valid part" otherwise reads as
# a corrupt device database and sends you reinstalling for no reason.
if {[llength [get_parts]] == 0} {
    puts "ERROR: Vivado reports zero available parts."
    puts "       This is a licence TIER problem, not a broken device install."
    exit 1
}
if {[llength [get_parts $part]] == 0} {
    puts "ERROR: part $part is not available in this Vivado install/tier."
    exit 1
}

# The include search path has to cover the RTL directory: the microcode field
# definitions are a generated `include that lives beside the source, not in
# Vivado's working directory.
set_property include_dirs [file join $root rtl] [current_fileset]

foreach f $srcs {
    if {![file exists $f]} { puts "ERROR: no such source: $f"; exit 1 }
    read_verilog -sv $f
}

synth_design -top $top -part $part -mode out_of_context

# The clock has to be declared AFTER synth_design in this flow - there is no
# design to attach it to before that.  Everything in this core is one clock
# domain, so one create_clock covers it.
create_clock -period $period -name clk [get_ports clk]

puts "=========================================================="
puts " POST-SYNTHESIS (estimate)"
puts "=========================================================="
report_utilization -file [file join $outdir ${top}_synth_util.rpt]
puts [report_utilization -return_string -slr]

opt_design
place_design
phys_opt_design
route_design

puts "=========================================================="
puts " POST-ROUTE - $top on $part, ${period} ns target"
puts "=========================================================="
report_utilization -file [file join $outdir ${top}_route_util.rpt]
report_timing_summary -file [file join $outdir ${top}_timing.rpt]

# The worst path alone is a poor guide to what to optimise.  If the top twenty
# paths are all the same shape, fixing that shape moves Fmax; if they are a
# scatter of unrelated endpoints, the design is balanced and only a structural
# change helps.  One is worth acting on and the other is not, and the summary
# report cannot tell them apart.
report_timing -max_paths 20 -sort_by slack -path_type summary \
    -file [file join $outdir ${top}_paths.rpt]

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]

puts ""
puts " setup WNS : $wns ns"
puts " hold  WHS : $whs ns"

# Fmax is only derivable from a MISSED constraint.  The router stops as soon as
# it meets the target, so a met run says "at least this fast" and nothing more -
# reporting 1/(period-WNS) there invents a precise-looking number that is really
# just the target back again.  To find the actual ceiling, re-run with -period
# tight enough to fail and read it off the violation.
#
# Do not over-tighten either: an unreachable target makes the placer thrash and
# come out WORSE.  Measured on this core - a 5.0 ns target yielded 8.92 ns
# achieved, while 8.0 ns yielded 8.48 ns.  Close in from above.
if {$wns < 0} {
    set fmax [expr {1000.0 / ($period - $wns)}]
    puts " achieved  : [format %.3f [expr {$period - $wns}]] ns => Fmax [format %.1f $fmax] MHz"
} else {
    puts " Fmax      : >= [format %.1f [expr {1000.0 / $period}]] MHz (target met;"
    puts "             re-run with a tighter -period to find the ceiling)"
}
puts ""

# Print the Slice Logic table straight from report_utilization rather than
# counting cells by hand.  A raw `get_cells` count is NOT the same number: two
# LUT5s that share a site are one Slice LUT, and the hand count reported ~20%
# more LUTs than the device actually spends.  Two contradictory numbers in one
# log is worse than no number at all, so only the tool's own figure is printed.
set util [report_utilization -return_string]
set show 0
foreach line [split $util "\n"] {
    if {[string match "1. Slice Logic*" $line]} { set show 1 }
    if {$show && [string match "1.1 Summary*" $line]} { set show 0 }
    if {$show} { puts $line }
}
puts ""
puts " (no BRAM, no DSP, no LUTRAM - the core is pure logic and flops)"
puts "=========================================================="
puts "reports in $outdir"
