#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 jtflanagan
# Verilator lint over this project's RTL.  Run before a Vivado build.
#
# Worth having because iverilog and Vivado disagree about what is legal, and the
# gap is where the bugs hide.  Case in point: an out-of-range part-select
# (sum_x10[16 +: 32] on a 40-bit value) elaborated fine under iverilog and was a
# hard ERROR in Vivado synthesis - after a ten-minute build.  Verilator catches
# that class in about a second.
#
# UberDDR3's own sources are not linted here; upstream has its own lint pass and
# its warnings are not ours to fix.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# UNUSEDSIGNAL/UNUSEDPARAM: debug outputs and config parameters that this build
# does not consume are intentional, not oversights.
COMMON=(--lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM)

fail=0
# LINT_LABEL renames a run in the output without renaming the top: master_top
# is linted twice, once per value of GS, and the two lines have to be tellable
# apart.
run() {
    local top="$1"; shift
    printf '%-16s ' "${LINT_LABEL:-$top}"
    if verilator "${COMMON[@]}" --top-module "$top" "$@" 2>/tmp/lint.$$; then
        echo "OK"
    else
        echo "FAIL"
        sed 's/^/    /' /tmp/lint.$$
        fail=1
    fi
    rm -f /tmp/lint.$$
}

run uart_tx       rtl/common/uart_tx.v
run uart_rx       rtl/common/uart_rx.v
run bin_to_bcd    rtl/common/bin_to_bcd.v
run report_tx     rtl/common/report_tx.sv rtl/common/bin_to_bcd.v
run latency_probe rtl/common/latency_probe.sv

# ft601_fifo is now pure logic - the FIFOs moved out to ft601_top, mirroring the
# reference, which keeps its clock-domain crossing outside the FT601 controller.
# So it lints standalone, with no stand-in for xpm_fifo_async needed.
# INITIALDLY is off because the reference initialises its output registers with
# non-blocking assignments inside an initial block, and this is a faithful port.
# For FPGA power-on values the distinction has no effect; Verilator is objecting
# to simulation semantics we do not rely on.  Diverging from the source to quiet
# a lint message is not worth it.
run ft601_fifo    rtl/common/ft601_fifo.sv -Wno-INITIALDLY
run ft601_msg_tx  rtl/common/ft601_msg_tx.sv
run ft601_msg_rx  rtl/common/ft601_msg_rx.sv
run link_watchdog rtl/common/link_watchdog.sv
run sync_fifo     rtl/common/sync_fifo.sv
run synth_bus_events rtl/common/synth_bus_events.sv
run bus_event_capture rtl/common/bus_event_capture.sv rtl/common/sync_fifo.sv
run bus_event_filter rtl/common/bus_event_filter.sv
# vbeam shares the scanner formula with vbl_lock and fb_sim.
run vbeam         -Irtl/common -Irtl/a2 rtl/common/vbeam.sv
run event_merge   rtl/common/event_merge.sv
run synchronizer  rtl/common/synchronizer.sv
run wb_regfile    rtl/common/wb_regfile.sv rtl/a2/fast_census.sv rtl/common/start_hold.sv
run reg_bridge    rtl/common/reg_bridge.sv
run reg_front     rtl/common/reg_front.sv
run telem_tx      -Irtl/common -Irtl/a2 rtl/common/telem_tx.sv rtl/common/sync_fifo.sv
run msg_arb       rtl/common/msg_arb.sv
run reply_stream  rtl/common/reply_stream.sv
run msg_master    rtl/common/msg_master.sv
run wb_arb        rtl/common/wb_arb.sv
run apple_mmu     rtl/a2/apple_mmu.sv
run rom_loader    rtl/a2/rom_loader.sv
# way_ram is the two-process true-dual-port RAM template at a way's geometry,
# like fd_bank; page_cache is linted at all three of the geometries
# sim/run_page_cache_tb.sh sweeps, because a way count that is not a power of
# two takes different paths through its replacement tree.
run way_ram       rtl/a2/way_ram.sv -Wno-MULTIDRIVEN
run page_cache    rtl/a2/page_cache.sv rtl/a2/way_ram.sv -Wno-MULTIDRIVEN
run page_cache    rtl/a2/page_cache.sv rtl/a2/way_ram.sv -Wno-MULTIDRIVEN -GSETS=64 -GWAYS=10
run page_cache    rtl/a2/page_cache.sv rtl/a2/way_ram.sv -Wno-MULTIDRIVEN -GSETS=64 -GWAYS=8
run page_cache    rtl/a2/page_cache.sv rtl/a2/way_ram.sv -Wno-MULTIDRIVEN -GSETS=64 -GWAYS=6   # the 65C02 card's
run page_client   rtl/common/page_client.sv
run tx_ring       rtl/common/tx_ring.sv rtl/common/sync_fifo.sv
run apple_bus_read rtl/common/apple_bus_read.sv rtl/common/synchronizer.sv
run apple_bus_write rtl/common/apple_bus_write.sv
run accel_seq     rtl/a2/accel_seq.sv
run fast_census   rtl/a2/fast_census.sv
run bank_census   rtl/gs/bank_census.sv
run l1i           rtl/a2/l1i.sv
run l1d           rtl/a2/l1d.sv
run tlb           rtl/a2/tlb.sv
# The 65816 card's L1: l1i and l1d over its own tlb (docs/CORE_REFACTOR_65816.md).
LINT_LABEL=gs_l1i run l1i rtl/gs/l1i.sv rtl/gs/iscan.sv
LINT_LABEL=gs_iscan run iscan rtl/gs/iscan.sv
LINT_LABEL=gs_l1d run l1d -Irtl/common -Irtl/gs rtl/gs/l1d.sv
LINT_LABEL=gs_tlb run tlb rtl/gs/tlb.sv
run boot_hold     rtl/common/boot_hold.sv
run kbd_inject    rtl/common/kbd_inject.sv
run kbd_notice    rtl/common/kbd_notice.sv
run speaker       rtl/common/speaker.sv
run audio_sampler rtl/common/audio_sampler.sv
run audio_tx      rtl/common/audio_tx.sv rtl/common/sync_fifo.sv
run pb_inject     rtl/common/pb_inject.sv
run game_port     rtl/common/game_port.sv
run slot_switches rtl/common/slot_switches.sv
run hd_card       rtl/common/hd_card.sv rtl/common/slot_switches.sv
run vidhd_card    rtl/a2/vidhd_card.sv rtl/common/slot_switches.sv
run printer_card  rtl/common/printer_card.sv rtl/common/slot_switches.sv
run mouse_card    rtl/common/mouse_card.sv rtl/common/slot_switches.sv
run no_slot_clock rtl/common/no_slot_clock.sv
run uthernet2_card rtl/common/uthernet2_card.sv rtl/common/fd_bank.sv -Wno-MULTIDRIVEN
# fd_bank is the two-process true-dual-port RAM template Vivado infers block
# RAM from (UG901); Verilator reads its two writers as a multi-driven array,
# which is the shape, not a bug.
run floppy_card   rtl/a2/floppy_card.sv rtl/common/fd_bank.sv rtl/common/slot_switches.sv \
                  -Wno-MULTIDRIVEN
# vbl_lock and fb_sim share the scanner formula, an `include beside the RTL.
run vbl_lock      -Irtl/common -Irtl/a2 rtl/common/vbl_lock.sv
run fb_sim        -Irtl/common -Irtl/a2 rtl/common/fb_sim.sv rtl/common/fd_bank.sv -Wno-MULTIDRIVEN
# via6522 is third-party (see its header) and linted only as a dependency of
# the mockingboard, with the style warnings its 2011 idiom trips suppressed
# rather than fixed - it ran real machines as-is, and diverging from the
# source to quiet a linter is how faithful ports stop being faithful.
# YM2149.sv is third-party too (a2fpga's, via aty) and carries width idioms
# Verilator dislikes; suppressed here, not edited there.
run ay_pair       rtl/common/ay_pair.sv rtl/common/YM2149.sv -Wno-CASEINCOMPLETE -Wno-PINCONNECTEMPTY -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND
run ssi263        rtl/common/ssi263.sv
run start_hold    rtl/common/start_hold.sv
run mockingboard  rtl/common/mockingboard.sv rtl/common/via6522.v rtl/common/slot_switches.sv rtl/common/ay_pair.sv rtl/common/YM2149.sv rtl/common/ssi263.sv -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
                  -Wno-CASEINCOMPLETE -Wno-PINCONNECTEMPTY
# -Irtl/common -Irtl/a2: the microcode field definitions are a generated `include, and they live
# beside the RTL rather than in the simulator's working directory.
run cpu65c02      -Irtl/common -Irtl/a2 rtl/a2/cpu65c02.sv
# The exploratory 65816 (branch ucode_65816).  Same generated-include
# arrangement as the 65C02 core.
run cpu65816      -Irtl/common -Irtl/gs rtl/gs/cpu65816.sv

# ---- the two tops ---------------------------------------------------------
# The tops used to be on the "not linted" list below, because they
# instantiate Xilinx primitives, an XPM macro and UberDDR3's top and
# Verilator cannot resolve any of them - which left a mistyped connection or
# an undriven wire in the top level to be found by Vivado, after a fifteen-
# minute elaboration.  sim/stubs/prims.v gives the linter the port names and
# nothing else, so it can walk the whole design in a second.  The stubs are
# never in a synthesis source list; if one disagrees with the real primitive,
# Vivado still says so.
#
# TWO CARDS, TWO TREES (2026-09-18, docs/CORE_REFACTOR_65C02.md rung 1):
# rtl/a2/a2_top.sv over rtl/common + rtl/a2, rtl/gs/gs_top.sv over rtl/common
# + rtl/gs.  Each card carries its own copy of the sequencer, L1 and L2 under
# the same module names, so a lint never sees both trees at once.  The
# suppressions are the ones the modules underneath already carry in this
# file: ft601_fifo's INITIALDLY, card_link's SYNCASYNCNET, the third-party
# width idioms.
# (set -e is on: a glob with no match makes ls fail, so the card lists are
# built with the shell's own nullglob, never a failing ls.)
COMMONRTL=$(ls rtl/common/*.sv rtl/common/*.v | grep -v 'snoop_top\|au_top\|diag_top\|ft601_top')
shopt -s nullglob
for card in a2 gs; do
    CARDRTL=""
    for f in rtl/$card/*.sv rtl/$card/*.v; do
        case "$f" in *"${card}_top.sv") ;; *) CARDRTL="$CARDRTL $f" ;; esac
    done
    LINT_LABEL="${card}_top" \
    run ${card}_top \
        rtl/$card/${card}_top.sv $COMMONRTL $CARDRTL sim/stubs/prims.v \
        -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE -Wno-PINCONNECTEMPTY \
        -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINMISSING \
        -Wno-INITIALDLY -Wno-SYNCASYNCNET -Irtl/common -Irtl/$card
done

# Not linted, deliberately:
#   clk_gen.v      - nothing but IBUF/BUFG/MMCME2_BASE instantiation.  Verilator
#                    cannot resolve Xilinx primitives without stubs, and there is
#                    no logic in the file for it to have an opinion about.  The
#                    MMCM configuration is checked by Vivado, which is the only
#                    tool that knows the VCO limits anyway.
#   ddr3_wrapper / au_top - structural, and both instantiate UberDDR3 or
#                    primitives.  Vivado elaboration covers them.
#   ft_clk_buf.v   - IBUF and BUFG, nothing else.
#   ft601_top.sv   - structural; instantiates clk_gen, ft_clk_buf and the XPM
#                    FIFOs, none of which Verilator can resolve.  The logic worth
#                    linting in that build is in ft601_fifo, linted above.

exit $fail
