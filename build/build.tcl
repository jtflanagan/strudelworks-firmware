# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
##############################################################################
# Headless project-mode build for strudelworks.
#
#   vivado -mode batch -source build/build.tcl
#
# Optional -tclargs:
#   -jobs <n>      parallel synth/impl jobs (default 4)
#   -board <b>     au_v2 | pt_v2 - picks the part and constr/<b>/
#   -part <part>   override the target part (the board's, normally)
#   -open          leave the project open (GUI-less; for interactive tcl work)
#
# Everything is built from source.  There is no .xci in this project by design:
# no MIG, and clk_gen.v instantiates MMCME2_BASE directly instead of using
# clk_wiz.  That means a fresh clone plus third_party/fetch_uberddr3.sh is a
# complete, reproducible build with nothing to regenerate by hand.
##############################################################################

set root [file normalize [file join [file dirname [info script]] ..]]

# ---- board ---------------------------------------------------------------
# One of tools/boards.py's entries.  The part and the pin constraints follow
# from it: constr/<board>/ holds the generated per-board XDCs (board pins,
# FT601 pins, Apple-bus pins, DDR3), constr/*.xdc the board-neutral timing.
# tools/gen_pin_xdc.py --check keeps this table and boards.py in agreement,
# and build/build.sh runs that before every build.
set board pt_v2
set board_part(au_v2) xc7a35tftg256-2
set board_part(pt_v2) xc7a100tfgg484-2

set part      ""
set gs50t     0
set l1istore  0
set jobs      4
set keep_open 0
set synth_only 0
set outdir    [file join $root build work]
set diag      0
set ft601     0
set snoop     0
set master    0
# -gs is -master with the GS parameter set: one top level, one parameter, and
# the plain build bit-identical at GS = 0 (docs/GS.md rung 4).  It gets its own
# source list additions, its own work directory (build/build.sh) and its own
# bitstream name, so a IIe bit and a IIgs bit can sit side by side in
# build/results and neither can be mistaken for the other.
set gs        0
# YYYYMMDD and HHMMSS as two separate decimal integers. Two args rather than one
# quoted pair because this reaches Vivado through cmd.exe, which would split the
# space anyway. Supplied by build/build.sh so the stamp is when the BUILD
# started, not whenever Vivado happened to reach this line.
set stamp_date 0
set stamp_time 0
# The placer's directive (UBERDDR3.md rung 4, the census that loads every build): the
# strategy's own when empty, else e.g. ExtraNetDelay_high / AltSpreadLogic_high /
# ExtraTimingOpt - a different placement of the same RTL, on purpose.
set place_directive ""
# CK_PHASE_SHIFT as a top-level generic (docs/UBERDDR3.md rung 2): the DDR3
# controller write-levels the CK pin by walking the MMCM's fine phase shift.
# The RTL's own default is 1 since 2026-09-18, so this is only passed when it
# is asked for either way - -1 means "not asked", and `-ck-phase 0` builds the
# old way.
set ck_phase -1

for {set i 0} {$i < $argc} {incr i} {
    switch -- [lindex $argv $i] {
        -jobs   { incr i; set jobs [lindex $argv $i] }
        -board  -
        --board { incr i; set board [lindex $argv $i] }
        -part   { incr i; set part [lindex $argv $i] }
        -gs50t  { set gs50t 1 }
        -l1i-store { set l1istore 1 }
        -outdir { incr i; set outdir [lindex $argv $i] }
        -synth_only { set synth_only 1 }
        -open   { set keep_open 1 }
        -diag   -
        --diag  { set diag 1 }
        -ft601  -
        --ft601 { set ft601 1 }
        -snoop  -
        --snoop { set snoop 1 }
        -master -
        --master { set master 1 }
        -gs     -
        --gs    { set master 1; set gs 1 }
        -stamp-date { incr i; set stamp_date [lindex $argv $i] }
        -stamp-time { incr i; set stamp_time [lindex $argv $i] }
        -place-directive { incr i; set place_directive [lindex $argv $i] }
        -ck-phase { incr i; set ck_phase [lindex $argv $i] }
        default { puts "WARNING: ignoring unknown argument [lindex $argv $i]" }
    }
}

if {($diag + $ft601 + $snoop + $master) > 1} {
    puts "ERROR: -diag, -ft601, -snoop and -master select different top levels; pick one."
    exit 1
}

if {![info exists board_part($board)]} {
    puts "ERROR: unknown board '$board'; one of: [lsort [array names board_part]]"
    exit 1
}
if {$part eq ""} { set part $board_part($board) }
set cdir [file join $root constr $board]
if {![file isdirectory $cdir]} {
    puts "ERROR: $cdir missing - run python3 tools/gen_pin_xdc.py and tools/gen_ddr3_xdc.py"
    exit 1
}
puts "=========================================================="
puts " board : $board"
puts " part  : $part"
puts "=========================================================="

# One place decides the top level, so the source list, the constraint list and
# the bitstream name below cannot drift apart.
set card [expr {$gs ? {gs} : {a2}}]
set topname [expr {$master ? ($gs ? {gs_top} : {a2_top}) : ($snoop ? {snoop_top} : ($ft601 ? {ft601_top} : ($diag ? {diag_top} : {au_top})))}]
# What the bitstream is CALLED, which is the top's name except for the IIgs
# build - same top, different machine, and the two must not overwrite each
# other in build/results.
# The card's bitstream keeps its name whichever top builds it (CLAUDE.md,
# build/build.sh's post-check, build/load.sh): master_top.bit for the 65C02
# card, master_top_gs.bit for the 65816's.  (Rung 1 renamed the tops and left
# this reading the top's name: the a2 card's bit landed as a2_top.bit and the
# post-check called a finished build failed.)
set bitname [expr {$master ? ($gs ? {master_top_gs} : {master_top}) : $topname}]
if {$gs} { puts " machine: Apple IIgs (GS=1)" }

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
        [file join $root rtl common clk_gen.v] \
        [file join $root rtl common ft_clk_buf.v] \
        [file join $root rtl common ft601_fifo.sv] \
        [file join $root rtl common ft601_msg_tx.sv] \
        [file join $root rtl common ft601_msg_rx.sv] \
        [file join $root rtl common link_watchdog.sv] \
        [file join $root rtl common sync_fifo.sv] \
        [file join $root rtl common synth_bus_events.sv] \
        [file join $root rtl common synchronizer.sv] \
        [file join $root rtl common apple_bus_read.sv] \
        [file join $root rtl common bus_event_capture.sv] \
        [file join $root rtl common bus_event_filter.sv] \
        [file join $root rtl common wb_regfile.sv] \
        [file join $root rtl common start_hold.sv] \
        [file join $root rtl common reg_bridge.sv] \
        [file join $root rtl common reg_front.sv] \
        [file join $root rtl common telem_tx.sv] \
        [file join $root rtl common msg_arb.sv] \
        [file join $root rtl common reply_stream.sv] \
        [file join $root rtl common msg_master.sv] \
        [file join $root rtl common ddr3_wrapper.sv] \
        [file join $root rtl common wb_arb.sv] \
        [file join $root rtl common tx_ring.sv] \
        [file join $root rtl common page_client.sv] \
        [file join $root rtl common event_merge.sv] \
        [file join $root rtl common card_link.sv] \
    ]
    if {$master} {
        add_files -norecurse [list \
            [file join $root rtl common apple_bus_write.sv] \
            [file join $root rtl common boot_hold.sv] \
            [file join $root rtl common kbd_inject.sv] \
            [file join $root rtl common kbd_notice.sv] \
            [file join $root rtl common pb_inject.sv] \
            [file join $root rtl common game_port.sv] \
            [file join $root rtl common via6522.v] \
            [file join $root rtl common YM2149.sv] \
            [file join $root rtl common ay_pair.sv] \
            [file join $root rtl common ssi263.sv] \
            [file join $root rtl common slot_switches.sv] \
            [file join $root rtl common mockingboard.sv] \
            [file join $root rtl common speaker.sv] \
            [file join $root rtl common audio_sampler.sv] \
            [file join $root rtl common audio_tx.sv] \
            [file join $root rtl common hd_card.sv] \
            [file join $root rtl common fd_bank.sv] \
            [file join $root rtl a2 floppy_card.sv] \
            [file join $root rtl a2 vidhd_card.sv] \
            [file join $root rtl common printer_card.sv] \
            [file join $root rtl common mouse_card.sv] \
            [file join $root rtl common uthernet2_card.sv] \
            [file join $root rtl common no_slot_clock.sv] \
            [file join $root rtl common vbl_lock.sv] \
            [file join $root rtl common vbeam.sv] \
            [file join $root rtl common fb_sim.sv] \
        ]
        if {$gs} {
            # THE 65816 CARD (rtl/gs): its core and ROMs, the chipset's register
            # faces, its own copies of the sequencer, L1 and L2, and gs_top.
            # Read at elaboration by $readmemh, and resolved by Vivado against
            # the files in the fileset.
            add_files -norecurse [list \
                [file join $root rtl gs cpu65816.sv] \
                [file join $root rtl gs gs_io.sv] \
                [file join $root rtl gs gs_adb.sv] \
                [file join $root rtl gs gs_doc.sv] \
                [file join $root rtl gs gs_kbd_a2.sv] \
                [file join $root rtl gs gs_clock.sv] \
                [file join $root rtl gs gs_intc.sv] \
                [file join $root rtl gs gs_iwm.sv] \
                [file join $root rtl gs bank_census.sv] \
                [file join $root rtl gs cpu65816_ucode.hex] \
                [file join $root rtl gs cpu65816_ucode0.hex] \
                [file join $root rtl gs cpu65816_useq0.hex] \
                [file join $root rtl gs adb_keymap.hex] \
                [file join $root rtl gs adb_revmap.hex] \
                [file join $root rtl gs gs_top.sv] \
            ]
        } else {
            # THE 65C02 CARD (rtl/a2): its core, the IIe-only cards, its own
            # copies of the sequencer, L1 and L2, and a2_top.  cpu65c02 loads
            # its microcode with $readmemh at elaboration, so the path has to
            # be absolute: the simulator's - and the synthesiser's - working
            # directory is not the RTL's directory.
            add_files -norecurse [list \
                [file join $root rtl a2 cpu65c02.sv] \
                [file join $root rtl a2 floppy_card.sv] \
                [file join $root rtl a2 vidhd_card.sv] \
                [file join $root rtl a2 cpu65c02_ucode.hex] \
                [file join $root rtl a2 a2_top.sv] \
            ]
            set_property generic [list \
                UCODE_FILE=[file join $root rtl a2 cpu65c02_ucode.hex] \
            ] [current_fileset]
        }
        # The sequencer, L1 and L2: one copy per card (docs/REQ_65C02.md,
        # the two cards' cache decisions are independent).
        add_files -norecurse [list \
            [file join $root rtl $card accel_seq.sv] \
            [file join $root rtl $card fast_census.sv] \
            [file join $root rtl $card way_ram.sv] \
            [file join $root rtl $card apple_mmu.sv] \
            [file join $root rtl $card rom_loader.sv] \
        ]
        # L1: each card's own l1i + l1d over its own tlb (the a2 card's rungs
        # 4-5, docs/CORE_REFACTOR_65C02.md; the gs card's rungs 2-3,
        # docs/CORE_REFACTOR_65816.md).
        add_files -norecurse [list \
            [file join $root rtl $card l1i.sv] \
            [file join $root rtl $card l1d.sv] \
            [file join $root rtl $card tlb.sv] \
        ]
        # L2: the a2 card's set cache; the gs card's CAM (docs/CORE_REFACTOR_65816.md
        # "The CAM-L2") beside its branch scanner (rung 4).
        if {$card eq "gs"} {
            add_files -norecurse [list [file join $root rtl gs iscan.sv] [file join $root rtl gs page_cam.sv] [file join $root rtl gs l1i_store.sv] [file join $root rtl gs store_ram.sv]]
        } else {
            add_files -norecurse [list [file join $root rtl a2 page_cache.sv]]
        }
    } else {
        add_files -norecurse [list [file join $root rtl common snoop_top.sv]]
    }
} elseif {$ft601} {
    # FT601 link bring-up: no DDR3 and no Apple bus, so only the board pins and
    # the ft601 pair apply.  No .xci here either - the FT601 clock is used directly (ft_clk_buf.v) and v5.s
    # clk_wiz_0 and ft601_fifo.sv uses xpm_fifo_async in place of fifo_ft600.
    add_files -norecurse [list \
        [file join $root rtl common clk_gen.v] \
        [file join $root rtl common ft_clk_buf.v] \
        [file join $root rtl common ft601_fifo.sv] \
        [file join $root rtl common ft601_msg_tx.sv] \
        [file join $root rtl common uart_tx.v] \
        [file join $root rtl common uart_rx.v] \
        [file join $root rtl common ft601_top.sv] \
    ]
} elseif {$diag} {
    # Diagnostic build: no DDR3, so ddr3.xdc must be left out too - its ports do
    # not exist in diag_top and an XDC naming a missing port is only a warning,
    # which the unmatched-constraint guard below would (correctly) turn fatal.
    add_files -norecurse [list \
        [file join $root rtl common clk_gen.v] \
        [file join $root rtl common uart_tx.v] \
        [file join $root rtl common uart_rx.v] \
        [file join $root rtl common diag_top.sv] \
    ]
} else {
    add_files -norecurse [list \
        [file join $root rtl common clk_gen.v] \
        [file join $root rtl common ddr3_wrapper.sv] \
        [file join $root rtl common latency_probe.sv] \
        [file join $root rtl common uart_tx.v] \
        [file join $root rtl common uart_rx.v] \
        [file join $root rtl common bin_to_bcd.v] \
        [file join $root rtl common report_tx.sv] \
        [file join $root rtl common au_top.sv] \
    ]
}

set_property file_type {Verilog}        [get_files *.v]
set_property file_type {SystemVerilog}  [get_files *.sv]
# The `include headers (telem_map.vh, scan_addr.vh, gs_iopage.vh, the cores'
# microcode field definitions) are found beside the including file or on this
# path; since the tree split a card's file may include a common header.
if {$snoop || $master} {
    set_property include_dirs [list [file join $root rtl common] [file join $root rtl $card]] [current_fileset]
}
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
# THE MACHINE, as a top-level generic.  Set only when it is 1: an untouched
# plain build must present Vivado with exactly the source it always did, so
# that "bit-identical at GS = 0" is a statement about the toolchain's input
# and not only about the RTL's meaning.
if {$gs && $l1istore} {
    # The instruction store (rung 8, parked) instead of the two-line L1-I.
    set_property verilog_define [concat [get_property verilog_define [current_fileset]] [list L1I_STORE]] [current_fileset]
}
if {$gs && $gs50t} {
    # THE 50T CANDIDATE (docs/CORE_REFACTOR_65816.md): the CAM-L2 at 32 slots,
    # no Mockingboard, no slot mouse card, the register file at MINIMAL.
    puts " variant: the 50T candidate (32 slots, no MB, no mouse, MINIMAL regs)"
    # APPENDED to the fileset's generics: set_property replaces the list, and the
    # first build of this variant lost its build stamp that way (the host then
    # called the gateware unknown and never configured the hard disk's slot).
    set_property generic [concat [get_property generic [current_fileset]] \
        [list MEM_SETS=32 HAS_MB=0 HAS_MOUSE=0 MINIMAL_REGS=1]] [current_fileset]
}
if {$gs} {
    # GS is a localparam of gs_top since the tree split (2026-09-18): nothing to pass.
}
if {$ck_phase >= 0} {
    puts "CK_PHASE_SHIFT = $ck_phase ([expr {$ck_phase ? "the DDR3 write-levels its own CK" : "asked for OFF: CK on the commands' clock"}])"
    set_property generic [concat [get_property generic [current_fileset]] \
                                 [list CK_PHASE_SHIFT=$ck_phase]] [current_fileset]
}

# ---- constraints ---------------------------------------------------------
# An XDC naming a port that does not exist is an error, not a warning, so each
# constraint file goes only to the tops that declare its ports: the ft601 pair
# to the builds with ft_* ports, the apple_bus pair to the two Apple-facing
# ones, and apple_bus_master.xdc to the one that actually drives them.
#
# Each interface is two files: constr/<board>/*_pins.xdc, generated per board
# from the connector-named sources in constr/pins/ (PACKAGE_PIN + IOSTANDARD,
# nothing else), and constr/*.xdc, the board-neutral timing, false paths and
# IOB packing.  The board's own pins (clock, reset, LEDs, UART) and the
# bitstream properties are constr/<board>/board.xdc.
if {$snoop || $master} {
    # ddr3.xdc too: the outgoing stream crosses the DDR3 in both (rtl/tx_ring.sv).
    add_files -fileset constrs_1 -norecurse [list \
        [file join $cdir board.xdc] \
        [file join $cdir ft601_pins.xdc] \
        [file join $root constr ft601.xdc] \
        [file join $cdir apple_bus_pins.xdc] \
        [file join $root constr apple_bus.xdc] \
        [file join $cdir ddr3.xdc] \
    ]
    # The output direction exists only in the build that drives.  An XDC naming
    # a path that cannot exist is an error, not a warning, so a set_false_path
    # -to an input port would fail the snooper's build outright.
    if {$master} {
        add_files -fileset constrs_1 -norecurse [list \
            [file join $root constr apple_bus_master.xdc] \
        ]
    }
    # The FT601 output-enable flops pinned beside their pads: a hand-written,
    # per-board placement file (site coordinates are the die's), present only
    # for boards that need it (constr/pt_v2/ft601_place.xdc says why).
    if {[file exists [file join $cdir ft601_place.xdc]]} {
        add_files -fileset constrs_1 -norecurse [file join $cdir ft601_place.xdc]
    }
    # The DDR3 controller and PHY kept in the two clock regions beside their IO
    # bank, for the same reason and in the same form: per-board, present only
    # where it is needed (constr/pt_v2/ddr3_place.xdc says why).
    if {[file exists [file join $cdir ddr3_place.xdc]]} {
        add_files -fileset constrs_1 -norecurse [file join $cdir ddr3_place.xdc]
    }
} elseif {$ft601} {
    add_files -fileset constrs_1 -norecurse [list \
        [file join $cdir board.xdc] \
        [file join $cdir ft601_pins.xdc] \
        [file join $root constr ft601.xdc] \
    ]
} elseif {$diag} {
    add_files -fileset constrs_1 -norecurse [list \
        [file join $cdir board.xdc] \
    ]
} else {
    add_files -fileset constrs_1 -norecurse [list \
        [file join $cdir board.xdc] \
        [file join $cdir ddr3.xdc] \
    ]
}

# ---- run -----------------------------------------------------------------
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
if {$place_directive ne ""} {
    set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE $place_directive [get_runs impl_1]
    puts "place_design directive: $place_directive"
}

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

# SYNTHESIS ONLY (docs/CORE_REFACTOR_65C02.md rung 2): the footprint is the
# question and no bitstream is wanted, so report the synthesised utilisation,
# flat and by module, and stop.  build/build.sh --master --synth-only.
if {$synth_only} {
    open_run synth_1
    set results_dir [file join $root build results]
    report_utilization -file [file join $results_dir synth_util.rpt]
    report_utilization -hierarchical -hierarchical_depth 2 -file [file join $results_dir synth_util_hier.rpt]
    puts "SYNTH ONLY: [file join $results_dir synth_util.rpt] and synth_util_hier.rpt written; no implementation, no bitstream"
    exit 0
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

# Logic-depth audit: the deep-but-currently-comfortable paths that the timing
# summary hides until placement gets unlucky.  ~11 s on the 35T, measured -
# cheap enough to keep current on every build.  Same procs as the standalone
# build/depth.sh, from depth_report.tcl.
source [file join $root build depth_report.tcl]
write_depth_report    [file join $outdir logic_depth.rpt]
write_depth_histogram [file join $outdir design_analysis.rpt]

# DDR3 forensics: the PHY's clock leg, the clock-to-pad census, the clock
# resources and where the controller landed - the things static timing never
# checks and a bitstream that never calibrates has to be diffed on
# (docs/UBERDDR3.md).  Same proc as the standalone build/ddr3_forensics.sh.
source [file join $root build ddr3_forensics.tcl]
if {[catch {ddr3_forensics [file join $outdir ddr3_forensics.txt]} why]} {
    puts "WARNING: ddr3_forensics failed: $why"
}

# Copy the artefacts back into the repo, since $outdir is normally a scratch
# directory on the Windows side that nothing else will look in.
set results [file join $root build results]
file mkdir $results
set bit [file join $outdir strudelworks.runs impl_1 $topname.bit]
if {[file exists $bit]} {
    file copy -force $bit [file join $results $bitname.bit]
    puts "bitstream: [file join $results $bitname.bit]"
    # Which board the bitstream is for, beside it.  build/load.sh reads this to
    # pick the loader's part, and to refuse to push an Au bitstream at a Pt.
    set fh [open [file join $results $bitname.board] w]
    puts $fh $board
    close $fh
}
foreach r {timing_summary.rpt utilization.rpt logic_depth.rpt design_analysis.rpt ddr3_forensics.txt} {
    if {[file exists [file join $outdir $r]]} {
        file copy -force [file join $outdir $r] [file join $results $r]
    }
}
# The routed checkpoint too (26 MB, gitignored with the rest of build/results):
# the bitstreams that met timing and never calibrated the DDR3 had theirs
# overwritten by the next build before anyone could open them.  build/run_build.sh
# keeps a tagged copy.
set dcp [file join $outdir strudelworks.runs impl_1 ${topname}_routed.dcp]
if {[file exists $dcp]} {
    file copy -force $dcp [file join $results ${bitname}_routed.dcp]
    puts "checkpoint: [file join $results ${bitname}_routed.dcp]"
}

if {$wns < 0 || $whs < 0} {
    puts "WARNING: timing NOT met.  See docs/DERISK.md - the documented fallback"
    puts "         is DDR3-667 via the clk_gen.v parameter override."
}

if {!$keep_open} { close_project }
