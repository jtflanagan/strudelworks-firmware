# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
#
# DDR3 forensics on a ROUTED CHECKPOINT: everything about the UberDDR3 PHY's
# placement and output timing that static timing never checks (docs/UBERDDR3.md).
#
#   vivado -mode batch -source build/ddr3_forensics.tcl -tclargs -dcp X.dcp -out F.txt
#
# Sections:
#   A  how the DDR3 clock pin (CK) is driven - UberDDR3 feeds the OBUFDS from
#      !i_ddr3_clk, a fabric inversion of a BUFG net, while every other output
#      leaves through an OSERDES in the OLOGIC.  Which cell, which site, and the
#      delay from the BUFG to the pad.
#   B  output skew census: clock-to-pad of CK, DQS, DQ, DM, address/command,
#      measured with an analysis-only set_output_delay (never in the build XDC),
#      and the clock insertion delay at each launching OSERDES's CLK pin.
#   C  clock resources: the BUFG sites, the MMCM, the IDELAYCTRL and IDELAYs.
#   D  where the controller and PHY landed, and the slack of every path that
#      touches them.
#   E  LUTs of the controller that were combined (LUTNM) with LUTs outside it.
# Standalone: -dcp X.dcp -out F.txt opens the checkpoint and runs the proc.
# Sourced from build/build.tcl with the implemented design already open: the
# proc alone, on the build's own argv (which carries no -dcp).
proc ddr3_forensics {out} {
global ddr3_forensics_fh
set ddr3_forensics_fh [open $out w]
proc say {s} { global ddr3_forensics_fh; puts $ddr3_forensics_fh $s; puts $s }

set phy  u_card/u_ddr3/u_ddr3/ddr3_phy_inst
set ctrl u_card/u_ddr3/u_ddr3/ddr3_controller_inst

# ---- A: the CK leg ------------------------------------------------------------
say "== A: the DDR3 clock pin"
set obuf [get_cells -hier -filter "NAME =~ $phy/OBUFDS_inst*"]
foreach c $obuf {
    set inpin [get_pins -of $c -filter {REF_PIN_NAME == I}]
    set net   [get_nets -of $inpin]
    set drv   [get_pins -leaf -of $net -filter {DIRECTION == OUT}]
    set dcell [get_cells -of $drv]
    say "   $c site=[get_property SITE $c]"
    say "   I <- net [get_property NAME $net] fanout=[get_property FLAT_PIN_COUNT $net]"
    say "   driver: $dcell  REF=[get_property REF_NAME $dcell]  site=[get_property SITE $dcell] bel=[get_property BEL $dcell] region=[get_property CLOCK_REGION [get_sites [get_property SITE $dcell]]]"
    # the cell behind the driver (a LUT1's input is the BUFG net)
    foreach ip [get_pins -of $dcell -filter {DIRECTION == IN}] {
        set n2 [get_nets -of $ip]
        if {$n2 ne ""} { say "     [get_property REF_PIN_NAME $ip] <- [get_property NAME $n2] (type [get_property TYPE $n2])" }
    }
}

# ---- B: output skew census ----------------------------------------------------
say ""
say "== B: clock-to-pad of every DDR3 output, launched from clk_ddr3_raw (analysis-only constraint)"
set outs [get_ports -filter {DIRECTION == OUT || DIRECTION == INOUT} ddr3_*]
set_output_delay -clock [get_clocks clk_ddr3_raw] 0 $outs
set_output_delay -clock [get_clocks clk_ddr3_raw] 0 -min $outs
set_output_delay -clock [get_clocks clk_ddr3_90_raw] 0 -add_delay $outs
set_output_delay -clock [get_clocks clk_ddr3_90_raw] 0 -min -add_delay $outs
# Per port: the arrival time at the pad, slow and fast corners, measured from the
# launching clock's ideal edge (the "net (fo=0) ... <port>" line of the report,
# which includes the clock insertion, the OLOGIC/LUT and the buffer).  DQS is
# asked for its data path (OQ), not the tri-state path the worst path picks.
proc pad_arrival {port dtype} {
    set pname [get_property NAME $port]
    # DQ and DQS are bidirectional: their worst path to the pad is the
    # tri-state enable, not the data; ask for the data path through OQ.
    set thru ""
    if {[string match ddr3_dqs* $pname]} { set thru [get_pins -quiet -hier -filter "NAME =~ *OSERDESE2_dqs/OQ"] }
    if {[string match {ddr3_dq[[]*} $pname]} { set thru [get_pins -quiet -hier -filter "NAME =~ *OSERDESE2_data/OQ"] }
    if {$thru ne ""} {
        set rpt [report_timing -to $port -through $thru -delay_type $dtype -nworst 1 -max_paths 1 -return_string]
    } else {
        set rpt [report_timing -to $port -delay_type $dtype -nworst 1 -max_paths 1 -return_string]
    }
    set arr ""; set start ""
    foreach line [split $rpt "\n"] {
        set w [regexp -all -inline {\S+} $line]
        if {[lindex $w 0] eq "Source:"} { set start [lindex $w 1] }
        if {[string match "*net (fo=*" $line] && [lindex $w end] eq $pname} { set arr [lindex $w end-1] }
    }
    return [list $arr $start]
}
say [format "   %-18s %9s %9s %8s   %s" port slow_ns fast_ns spread "launch"]
set groups {ddr3_ck_p ddr3_ck_n ddr3_dqs_p ddr3_dqs_n ddr3_dq ddr3_dm ddr3_addr ddr3_ba ddr3_ras_n ddr3_cas_n ddr3_we_n ddr3_cs_n ddr3_cke ddr3_odt ddr3_reset_n}
set census [dict create]
foreach g $groups {
    # a vector group is ddr3_x[*]; ddr3_dq* would sweep in ddr3_dqs_p/n
    set ports [get_ports -quiet "${g}\[*\]"]
    if {$ports eq ""} { set ports [get_ports -quiet $g] }
    if {$ports eq ""} continue
    set slows {}; set fasts {}; set start ""
    foreach port $ports {
        lassign [pad_arrival $port max] a st
        if {$a ne ""} { lappend slows $a; set start $st }
        lassign [pad_arrival $port min] a st
        if {$a ne ""} { lappend fasts $a }
    }
    if {[llength $slows] == 0} { say [format "   %-18s no timed path" $g]; continue }
    set slows [lsort -real $slows]; set fasts [lsort -real $fasts]
    dict set census $g [list [lindex $slows end] [lindex $fasts 0]]
    say [format "   %-18s %9.3f %9.3f %8.3f   %s (%d ports)" $g [lindex $slows end] [lindex $fasts 0] [expr {[lindex $slows end]-[lindex $slows 0]}] $start [llength $ports]]
}
# The skews that matter.  Arrivals are in the ideal-clock timebase: a value is
# when that pad moves for the clk_ddr3 edge that launched it (rising at 0 for
# the commands and CK, falling at 1.25 for DQS, the 90-degree edge at 0.625 for
# DQ).  CK is !clk, so its RISING edges at the pad are at ck +- 1.25.
#   command setup at the CK rise that samples it = (ck - cmd + 1.25) mod 2.5
#   (ideal 1.25, i.e. CK and the commands through equal delays)
#   tDQSS = DQS rise relative to the nearest CK rise, in (-1.25, 1.25]; JEDEC
#   allows +-0.25 tCK = +-0.625 ns
proc skews {label ck cmd dqs dq} {
    set setup [expr {fmod($ck - $cmd + 1.25 + 25.0, 2.5)}]
    set tdqss [expr {fmod($dqs - ($ck - 1.25) + 1.25 + 25.0, 2.5) - 1.25}]
    say [format "   %s: CK leg - CMD leg = %+.3f ns -> command setup %.3f / hold %.3f ns (ideal 1.250/1.250); tDQSS = %+.3f ns (window +-0.625); DQS - DQ at the pad = %+.3f ns (ideal +0.625)" \
        $label [expr {$ck-$cmd}] $setup [expr {2.5-$setup}] $tdqss [expr {$dqs-$dq}]]
}
if {[dict exists $census ddr3_ck_p] && [dict exists $census ddr3_addr] && [dict exists $census ddr3_dqs_p] && [dict exists $census ddr3_dq]} {
    say ""
    skews "slow corner" [lindex [dict get $census ddr3_ck_p] 0] [lindex [dict get $census ddr3_addr] 0] [lindex [dict get $census ddr3_dqs_p] 0] [lindex [dict get $census ddr3_dq] 0]
    skews "fast corner" [lindex [dict get $census ddr3_ck_p] 1] [lindex [dict get $census ddr3_addr] 1] [lindex [dict get $census ddr3_dqs_p] 1] [lindex [dict get $census ddr3_dq] 1]
}
say ""
say "   full reports for one pin of each kind:"
foreach p {ddr3_ck_p[0] ddr3_dqs_p[0] ddr3_dq[0] ddr3_dm[0] ddr3_addr[0] ddr3_ras_n} {
    set port [get_ports -quiet $p]
    if {$port eq ""} continue
    say "   ---- $p ----"
    set rpt [report_timing -to $port -delay_type max -nworst 1 -max_paths 1 -return_string]
    # keep the interesting lines only: source clock delay, data path, arrival
    foreach line [split $rpt "\n"] {
        if {[regexp {Source Clock Delay|Data Path Delay|Logic Levels|Source:|Destination:|Requirement|Slack|BUFG|OSERDESE2|LUT|OBUF|clock pessimism|net \(fo} $line]} { say "     [string trim $line]" }
    }
}
say ""
say "   clock insertion (Source Clock Delay) at the OSERDES CLK pins, one cell per kind:"
foreach {kind pat} {DQS *OSERDESE2_dqs DQ *OSERDESE2_data DM *OSERDESE2_dm CMD *OSERDESE2_cmd} {
    set cells [lsort [get_cells -hier -quiet -filter "NAME =~ $phy/$pat && PRIMITIVE_TYPE =~ IO.*OSERDES*"]]
    foreach c [lrange $cells 0 0] {
        set clkpin [get_pins -of $c -filter {REF_PIN_NAME == CLK}]
        set divpin [get_pins -of $c -filter {REF_PIN_NAME == CLKDIV}]
        say "   $kind $c site=[get_property SITE $c] CLK<-[get_nets -of $clkpin] inv=[get_property IS_CLK_INVERTED $c] CLKDIV<-[get_nets -of $divpin]"
        set p [get_timing_paths -quiet -to [get_pins -of $c -filter {REF_PIN_NAME == D1}] -nworst 1]
        if {$p ne ""} { say "      D1 path: slack [get_property SLACK $p] from [get_property STARTPOINT_PIN $p]" }
    }
}

# ---- C: clock resources -------------------------------------------------------
say ""
say "== C: clock resources"
foreach c [get_cells -hier -filter {PRIMITIVE_GROUP == CLOCK || REF_NAME =~ BUFG* || REF_NAME =~ MMCM*}] {
    say "   [get_property PRIMITIVE_TYPE $c] $c site=[get_property SITE $c] O->[get_nets -quiet -of [get_pins -quiet -of $c -filter {REF_PIN_NAME == O || REF_PIN_NAME == CLKOUT0}]]"
}
foreach c [get_cells -hier -filter {PRIMITIVE_TYPE =~ IO.*IDELAYCTRL* || PRIMITIVE_TYPE =~ IO.*IDELAYE2* || PRIMITIVE_TYPE =~ IO.*ODELAYE2*}] {
    set s [get_property SITE $c]
    say "   [get_property PRIMITIVE_TYPE $c] $c site=$s region=[get_property CLOCK_REGION [get_sites $s]] group=[get_property IODELAY_GROUP $c]"
}
say "   DDR3 IO banks:"
set banks [dict create]
foreach p [get_ports ddr3_*] { dict incr banks [get_property IOBANK $p] }
dict for {b n} $banks { say "     bank $b: $n pins" }

# ---- D: where the controller and PHY landed --------------------------------
say ""
say "== D: placement of the controller and PHY"
foreach {name pat} [list controller $ctrl/* phy $phy/* wrapper u_card/u_ddr3/*] {
    set cells [get_cells -hierarchical -filter "NAME =~ $pat && IS_PRIMITIVE"]
    set regions [dict create]
    foreach c $cells {
        set s [get_property SITE $c]
        if {$s eq ""} continue
        dict incr regions [get_property CLOCK_REGION [get_sites $s]]
    }
    say "   $name: [llength $cells] cells"
    dict for {r n} $regions { say "     $r: $n" }
}
say "   slack histogram of the 300 worst setup paths that start or end in u_ddr3:"
set dcells [get_cells -hierarchical -filter "NAME =~ u_card/u_ddr3/* && IS_PRIMITIVE"]
set paths [get_timing_paths -quiet -from $dcells -max_paths 150 -nworst 1 -unique_pins]
set paths2 [get_timing_paths -quiet -to $dcells -max_paths 150 -nworst 1 -unique_pins]
set hist [dict create]
foreach p [concat $paths $paths2] {
    set s [get_property SLACK $p]
    set b [expr {int(floor($s*2))/2.0}]
    dict incr hist $b
}
foreach b [lsort -real [dict keys $hist]] { say [format "     slack >= %5.1f ns: %d" $b [dict get $hist $b]] }
say "   the 8 worst of them:"
foreach p [lrange [lsort -command {apply {{a b} {expr {[get_property SLACK $a] < [get_property SLACK $b] ? -1 : 1}}}} [concat $paths $paths2]] 0 7] {
    say [format "     %6.3f  %2d lv  %s -> %s" [get_property SLACK $p] [get_property LOGIC_LEVELS $p] [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
}

# ---- E: LUT combining across the u_ddr3 boundary ---------------------------
say ""
say "== E: u_ddr3 LUTs sharing a LUTNM pair with a LUT outside u_ddr3"
set n_pair 0; set n_cross 0
foreach c [get_cells -hierarchical -filter "NAME =~ u_card/u_ddr3/* && IS_PRIMITIVE && PRIMITIVE_TYPE =~ CLB.LUT.*"] {
    foreach prop {HLUTNM SOFT_HLUTNM} {
        set g [get_property -quiet $prop $c]
        if {$g eq ""} continue
        incr n_pair
        foreach o [get_cells -hierarchical -quiet -filter "$prop == $g && NAME != $c"] {
            if {![string match u_card/u_ddr3/* $o]} { incr n_cross; if {$n_cross <= 10} { say "   $c <-> $o" } }
        }
    }
}
say "   paired u_ddr3 LUTs: $n_pair, paired across the boundary: $n_cross"
close $ddr3_forensics_fh
puts "ddr3_forensics: wrote $out"
}

if {[info exists argv] && [lsearch -exact $argv -dcp] >= 0} {
    set dcp ""; set out ""
    for {set i 0} {$i < [llength $argv]} {incr i} {
        switch -- [lindex $argv $i] { -dcp {incr i; set dcp [lindex $argv $i]} -out {incr i; set out [lindex $argv $i]} }
    }
    if {$dcp eq "" || $out eq ""} { puts "ERROR: need -dcp <routed.dcp> -out <file>"; exit 1 }
    open_checkpoint $dcp
    ddr3_forensics $out
}
