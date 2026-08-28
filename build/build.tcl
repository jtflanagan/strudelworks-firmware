# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
##############################################################################
# Headless project-mode build for strudelworks.
#
#   vivado -mode batch -source build/build.tcl
#
# Optional -tclargs:
#   -jobs <n>      parallel synth/impl jobs (default 4)
#   -part <part>   override the target part
#   -open          leave the project open (GUI-less; for interactive tcl work)
#
# Everything is built from source.  There is no .xci in this project by design:
# no MIG, and clk_gen.v instantiates MMCME2_BASE directly instead of using
# clk_wiz.  That means a fresh clone plus third_party/fetch_uberddr3.sh is a
# complete, reproducible build with nothing to regenerate by hand.
##############################################################################

set root [file normalize [file join [file dirname [info script]] ..]]

set part      xc7a35tftg256-2
set jobs      4
set keep_open 0
set outdir    [file join $root build work]
set diag      0
set ft601     0
set snoop     0
set master    0
# YYYYMMDD and HHMMSS as two separate decimal integers. Two args rather than one
# quoted pair because this reaches Vivado through cmd.exe, which would split the
# space anyway. Supplied by build/build.sh so the stamp is when the BUILD
# started, not whenever Vivado happened to reach this line.
set stamp_date 0
set stamp_time 0

for {set i 0} {$i < $argc} {incr i} {
    switch -- [lindex $argv $i] {
        -jobs   { incr i; set jobs [lindex $argv $i] }
        -part   { incr i; set part [lindex $argv $i] }
        -outdir { incr i; set outdir [lindex $argv $i] }
        -open   { set keep_open 1 }
        -diag   -
        --diag  { set diag 1 }
        -ft601  -
        --ft601 { set ft601 1 }
        -snoop  -
        --snoop { set snoop 1 }
        -master -
        --master { set master 1 }
        -stamp-date { incr i; set stamp_date [lindex $argv $i] }
        -stamp-time { incr i; set stamp_time [lindex $argv $i] }
        default { puts "WARNING: ignoring unknown argument [lindex $argv $i]" }
    }
}

if {($diag + $ft601 + $snoop + $master) > 1} {
    puts "ERROR: -diag, -ft601, -snoop and -master select different top levels; pick one."
    exit 1
}

# One place decides the top level, so the source list, the constraint list and
# the bitstream name below cannot drift apart.
set topname [expr {$master ? {master_top} : ($snoop ? {snoop_top} : ($ft601 ? {ft601_top} : ($diag ? {diag_top} : {au_top})))}]

set uber [file join $root third_party UberDDR3]
if {![file isdirectory [file join $uber rtl]]} {
    puts "ERROR: $uber/rtl not found."
    puts "       Run third_party/fetch_uberddr3.sh first."
    exit 1
}

# NOTE: under WSL, -outdir must point at a Windows-native path, NOT the repo.
# Vivado launches synth/impl as sub-processes through cmd.exe, and cmd.exe cannot
# hold a \\wsl.localhost\... UNC path as a working directory - it prints "CMD does
# not support UNC paths as current directories" and the run fails immediately with
# no other diagnosis.  Reading SOURCES over UNC is fine; it is only the run
# directory that matters.  build/build.sh sets this automatically.
# Best-effort clean.  Vivado leaves .pb message databases behind that Windows
# sometimes still holds a handle on, and a hard `file delete` then aborts the
# whole build over a scratch file that create_project is about to overwrite
# anyway.  Tolerate it; the stale-log guard below is what actually protects
# correctness.
if {[catch {file delete -force $outdir} err]} {
    puts "NOTE: could not fully clean $outdir ($err) - continuing"
}
file mkdir $outdir

create_project -force strudelworks $outdir -part $part

# ---- sources -------------------------------------------------------------
# UberDDR3's own rtl/ first, then ours.  Only ddr3_top / ddr3_controller /
# ddr3_phy are needed: the axi/, ecc/, ecp5_phy/ and spd/ subdirectories are the
# AXI shim, ECC variants, the Lattice PHY and the DIMM SPD reader, none of which
# this design uses.  Adding ecp5_phy in particular would break synthesis.
add_files -norecurse [list \
    [file join $uber rtl ddr3_top.v] \
    [file join $uber rtl ddr3_controller.v] \
    [file join $uber rtl ddr3_phy.v] \
]

if {$snoop || $master} {
    # The two Apple-facing builds.  Same file list but for the top: everything
    # that does not care which way the pins point is card_link, and only the top
    # differs - snoop_top declares the Apple pins INPUT and has no driver in it
    # at all, master_top declares them inout and puts a driver and a CPU behind
    # them.  A second copy of the link plumbing was the alternative, and a bug
    # fixed in one copy is a bug still shipped in the other.
    add_files -norecurse [list \
        [file join $root rtl clk_gen.v] \
        [file join $root rtl ft_clk_buf.v] \
        [file join $root rtl ft601_fifo.sv] \
        [file join $root rtl ft601_msg_tx.sv] \
        [file join $root rtl ft601_msg_rx.sv] \
        [file join $root rtl link_watchdog.sv] \
        [file join $root rtl sync_fifo.sv] \
        [file join $root rtl synth_bus_events.sv] \
        [file join $root rtl synchronizer.sv] \
        [file join $root rtl apple_bus_read.sv] \
        [file join $root rtl bus_event_capture.sv] \
        [file join $root rtl wb_regfile.sv] \
        [file join $root rtl reg_bridge.sv] \
        [file join $root rtl msg_arb.sv] \
        [file join $root rtl reply_stream.sv] \
        [file join $root rtl msg_master.sv] \
        [file join $root rtl ddr3_wrapper.sv] \
        [file join $root rtl wb_arb.sv] \
        [file join $root rtl tx_ring.sv] \
        [file join $root rtl uart_tx.v] \
        [file join $root rtl uart_rx.v] \
        [file join $root rtl card_link.sv] \
    ]
    if {$master} {
        add_files -norecurse [list \
            [file join $root rtl apple_bus_write.sv] \
            [file join $root rtl boot_hold.sv] \
            [file join $root rtl kbd_inject.sv] \
            [file join $root rtl pb_inject.sv] \
            [file join $root rtl cpu65c02.sv] \
            [file join $root rtl via6522.v] \
            [file join $root rtl slot_switches.sv] \
            [file join $root rtl mockingboard.sv] \
            [file join $root rtl hd_card.sv] \
            [file join $root rtl master_top.sv] \
        ]
        # cpu65c02 loads its microcode with $readmemh at elaboration, so the
        # path has to be absolute: the simulator's - and the synthesiser's -
        # working directory is not the RTL's directory.
        set_property generic [list \
            UCODE_FILE=[file join $root rtl cpu65c02_ucode.hex] \
        ] [current_fileset]
        add_files -norecurse [list [file join $root rtl cpu65c02_ucode.hex]]
    } else {
        add_files -norecurse [list [file join $root rtl snoop_top.sv]]
    }
} elseif {$ft601} {
    # FT601 link bring-up: no DDR3 and no Apple bus, so only alchitry_au.xdc and
    # ft601.xdc apply.  No .xci here either - the FT601 clock is used directly (ft_clk_buf.v) and v5.s
    # clk_wiz_0 and ft601_fifo.sv uses xpm_fifo_async in place of fifo_ft600.
    add_files -norecurse [list \
        [file join $root rtl clk_gen.v] \
        [file join $root rtl ft_clk_buf.v] \
        [file join $root rtl ft601_fifo.sv] \
        [file join $root rtl ft601_msg_tx.sv] \
        [file join $root rtl uart_tx.v] \
        [file join $root rtl uart_rx.v] \
        [file join $root rtl ft601_top.sv] \
    ]
} elseif {$diag} {
    # Diagnostic build: no DDR3, so ddr3.xdc must be left out too - its ports do
    # not exist in diag_top and an XDC naming a missing port is only a warning,
    # which the unmatched-constraint guard below would (correctly) turn fatal.
    add_files -norecurse [list \
        [file join $root rtl clk_gen.v] \
        [file join $root rtl uart_tx.v] \
        [file join $root rtl uart_rx.v] \
        [file join $root rtl diag_top.sv] \
    ]
} else {
    add_files -norecurse [list \
        [file join $root rtl clk_gen.v] \
        [file join $root rtl ddr3_wrapper.sv] \
        [file join $root rtl latency_probe.sv] \
        [file join $root rtl uart_tx.v] \
        [file join $root rtl uart_rx.v] \
        [file join $root rtl bin_to_bcd.v] \
        [file join $root rtl report_tx.sv] \
        [file join $root rtl au_top.sv] \
    ]
}

set_property file_type {Verilog}        [get_files *.v]
set_property file_type {SystemVerilog}  [get_files *.sv]
set_property top $topname [current_fileset]

# Build stamp -> top-level generics. Vivado's -generic takes decimal integers
# here; the RTL declares them as `integer` parameters and packs them into 32-bit
# registers. Zero means "not stamped", which is what an interactive build from
# the GUI produces, and the host reports it as such rather than as a date.
if {$stamp_date != 0 || $stamp_time != 0} {
    puts "build stamp: date=$stamp_date time=$stamp_time"
    set_property generic [list BUILD_DATE=$stamp_date BUILD_TIME=$stamp_time] \
                 [current_fileset]
}

# ---- constraints ---------------------------------------------------------
# An XDC naming a port that does not exist is an error, not a warning, so each
# constraint file goes only to the tops that declare its ports: ft601.xdc to the
# builds with ft_* ports, apple_bus.xdc to the two Apple-facing ones, and
# apple_bus_master.xdc to the one that actually drives them.
if {$snoop || $master} {
    # ddr3.xdc too: the outgoing stream crosses the DDR3 in both (rtl/tx_ring.sv).
    add_files -fileset constrs_1 -norecurse [list \
        [file join $root constr alchitry_au.xdc] \
        [file join $root constr ft601.xdc] \
        [file join $root constr apple_bus.xdc] \
        [file join $root constr ddr3.xdc] \
    ]
    # The output direction exists only in the build that drives.  An XDC naming
    # a path that cannot exist is an error, not a warning, so a set_false_path
    # -to an input port would fail the snooper's build outright.
    if {$master} {
        add_files -fileset constrs_1 -norecurse [list \
            [file join $root constr apple_bus_master.xdc] \
        ]
    }
} elseif {$ft601} {
    add_files -fileset constrs_1 -norecurse [list \
        [file join $root constr alchitry_au.xdc] \
        [file join $root constr ft601.xdc] \
    ]
} elseif {$diag} {
    add_files -fileset constrs_1 -norecurse [list \
        [file join $root constr alchitry_au.xdc] \
    ]
} else {
    add_files -fileset constrs_1 -norecurse [list \
        [file join $root constr alchitry_au.xdc] \
        [file join $root constr ddr3.xdc] \
    ]
}

# ---- run -----------------------------------------------------------------
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]

# Remove the previous run log before launching.  If the clean above was only
# partial, a stale runme.log would make the unmatched-constraint scan below
# report last build's findings - or, worse, stay silent about this one's.
set synth_log_pre [file join $outdir strudelworks.runs synth_1 runme.log]
catch {file delete -force $synth_log_pre}

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: synthesis failed - see [file join $outdir strudelworks.runs synth_1 runme.log]"
    exit 1
}

# A constraint that matches no port is only a WARNING to Vivado, buried in a log
# nobody reads, and the affected pin is then placed wherever the placer likes.
# That is how ddr3_ck_p/ck_n/cke/cs_n/odt were briefly unconstrained: MIG names
# them as 1-bit vectors (ddr3_ck_p[0]) and the top level declared them scalar.
# On hardware that is not a subtle degradation, it is a dead board.  So promote
# it to a hard failure here.
set synth_log [file join $outdir strudelworks.runs synth_1 runme.log]
if {![file exists $synth_log]} {
    puts "ERROR: $synth_log missing - cannot verify constraints matched."
    exit 1
}
if {1} {
    set fh [open $synth_log r]
    set log_text [read $fh]
    close $fh
    set unmatched [lsort -unique [regexp -all -inline {No ports matched '[^']+'} $log_text]]
    if {[llength $unmatched] > 0} {
        puts "=========================================================="
        puts "ERROR: [llength $unmatched] constraint(s) matched no port."
        foreach u $unmatched { puts "  $u" }
        puts ""
        puts "Those pins are UNCONSTRAINED and will be placed arbitrarily."
        puts "Usual cause: a port declared scalar that the XDC names as \[0\],"
        puts "or vice versa.  Fix the RTL port width to match constr/*.xdc."
        puts "=========================================================="
        exit 1
    }
}

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: implementation failed - see [file join $outdir strudelworks.runs impl_1 runme.log]"
    exit 1
}

open_run impl_1

# ---- report --------------------------------------------------------------
# Timing is the thing that decides whether 400 MHz DDR3 is viable here, so print
# it rather than leaving it in a report file nobody opens.
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "=========================================================="
puts " setup WNS : $wns ns"
puts " hold  WHS : $whs ns"
puts "=========================================================="
report_timing_summary -file [file join $outdir timing_summary.rpt]
report_utilization    -file [file join $outdir utilization.rpt]

# Copy the artefacts back into the repo, since $outdir is normally a scratch
# directory on the Windows side that nothing else will look in.
set results [file join $root build results]
file mkdir $results
set bit [file join $outdir strudelworks.runs impl_1 $topname.bit]
if {[file exists $bit]} {
    file copy -force $bit [file join $results $topname.bit]
    puts "bitstream: [file join $results $topname.bit]"
}
foreach r {timing_summary.rpt utilization.rpt} {
    if {[file exists [file join $outdir $r]]} {
        file copy -force [file join $outdir $r] [file join $results $r]
    }
}

if {$wns < 0 || $whs < 0} {
    puts "WARNING: timing NOT met.  See docs/DERISK.md - the documented fallback"
    puts "         is DDR3-667 via the clk_gen.v parameter override."
}

if {!$keep_open} { close_project }
