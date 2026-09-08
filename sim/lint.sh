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
run() {
    local top="$1"; shift
    printf '%-16s ' "$top"
    if verilator "${COMMON[@]}" --top-module "$top" "$@" 2>/tmp/lint.$$; then
        echo "OK"
    else
        echo "FAIL"
        sed 's/^/    /' /tmp/lint.$$
        fail=1
    fi
    rm -f /tmp/lint.$$
}

run uart_tx       rtl/uart_tx.v
run uart_rx       rtl/uart_rx.v
run bin_to_bcd    rtl/bin_to_bcd.v
run report_tx     rtl/report_tx.sv rtl/bin_to_bcd.v
run latency_probe rtl/latency_probe.sv

# ft601_fifo is now pure logic - the FIFOs moved out to ft601_top, mirroring the
# reference, which keeps its clock-domain crossing outside the FT601 controller.
# So it lints standalone, with no stand-in for xpm_fifo_async needed.
# INITIALDLY is off because the reference initialises its output registers with
# non-blocking assignments inside an initial block, and this is a faithful port.
# For FPGA power-on values the distinction has no effect; Verilator is objecting
# to simulation semantics we do not rely on.  Diverging from the source to quiet
# a lint message is not worth it.
run ft601_fifo    rtl/ft601_fifo.sv -Wno-INITIALDLY
run ft601_msg_tx  rtl/ft601_msg_tx.sv
run ft601_msg_rx  rtl/ft601_msg_rx.sv
run link_watchdog rtl/link_watchdog.sv
run sync_fifo     rtl/sync_fifo.sv
run synth_bus_events rtl/synth_bus_events.sv
run bus_event_capture rtl/bus_event_capture.sv rtl/sync_fifo.sv
run bus_event_filter rtl/bus_event_filter.sv
# vbeam shares the scanner formula with vbl_lock and fb_sim.
run vbeam         -Irtl rtl/vbeam.sv
run event_merge   rtl/event_merge.sv
run synchronizer  rtl/synchronizer.sv
run wb_regfile    rtl/wb_regfile.sv rtl/fast_census.sv
run reg_bridge    rtl/reg_bridge.sv
run msg_arb       rtl/msg_arb.sv
run reply_stream  rtl/reply_stream.sv
run msg_master    rtl/msg_master.sv
run wb_arb        rtl/wb_arb.sv
run apple_mmu     rtl/apple_mmu.sv
run rom_loader    rtl/rom_loader.sv
# way_ram is the two-process true-dual-port RAM template at a way's geometry,
# like fd_bank; page_cache is linted at all three of the geometries
# sim/run_page_cache_tb.sh sweeps, because a way count that is not a power of
# two takes different paths through its replacement tree.
run way_ram       rtl/way_ram.sv -Wno-MULTIDRIVEN
run page_cache    rtl/page_cache.sv rtl/way_ram.sv -Wno-MULTIDRIVEN
run page_cache    rtl/page_cache.sv rtl/way_ram.sv -Wno-MULTIDRIVEN -GSETS=64 -GWAYS=10
run page_cache    rtl/page_cache.sv rtl/way_ram.sv -Wno-MULTIDRIVEN -GSETS=64 -GWAYS=8
run page_client   rtl/page_client.sv
run tx_ring       rtl/tx_ring.sv rtl/sync_fifo.sv
run apple_bus_read rtl/apple_bus_read.sv rtl/synchronizer.sv
run apple_bus_write rtl/apple_bus_write.sv
run accel_seq     rtl/accel_seq.sv
run fast_census   rtl/fast_census.sv
run iline         rtl/iline.sv rtl/iscan.sv
run dline         rtl/dline.sv
run iscan         rtl/iscan.sv
run boot_hold     rtl/boot_hold.sv
run kbd_inject    rtl/kbd_inject.sv
run kbd_notice    rtl/kbd_notice.sv
run speaker       rtl/speaker.sv
run audio_sampler rtl/audio_sampler.sv
run audio_tx      rtl/audio_tx.sv rtl/sync_fifo.sv
run pb_inject     rtl/pb_inject.sv
run game_port     rtl/game_port.sv
run slot_switches rtl/slot_switches.sv
run hd_card       rtl/hd_card.sv rtl/slot_switches.sv
run vidhd_card    rtl/vidhd_card.sv rtl/slot_switches.sv
run printer_card  rtl/printer_card.sv rtl/slot_switches.sv
run mouse_card    rtl/mouse_card.sv rtl/slot_switches.sv
run no_slot_clock rtl/no_slot_clock.sv
run uthernet2_card rtl/uthernet2_card.sv rtl/fd_bank.sv -Wno-MULTIDRIVEN
# fd_bank is the two-process true-dual-port RAM template Vivado infers block
# RAM from (UG901); Verilator reads its two writers as a multi-driven array,
# which is the shape, not a bug.
run floppy_card   rtl/floppy_card.sv rtl/fd_bank.sv rtl/slot_switches.sv \
                  -Wno-MULTIDRIVEN
# vbl_lock and fb_sim share the scanner formula, an `include beside the RTL.
run vbl_lock      -Irtl rtl/vbl_lock.sv
run fb_sim        -Irtl rtl/fb_sim.sv rtl/fd_bank.sv -Wno-MULTIDRIVEN
# via6522 is third-party (see its header) and linted only as a dependency of
# the mockingboard, with the style warnings its 2011 idiom trips suppressed
# rather than fixed - it ran real machines as-is, and diverging from the
# source to quiet a linter is how faithful ports stop being faithful.
# YM2149.sv is third-party too (a2fpga's, via aty) and carries width idioms
# Verilator dislikes; suppressed here, not edited there.
run ay_pair       rtl/ay_pair.sv rtl/YM2149.sv -Wno-CASEINCOMPLETE -Wno-PINCONNECTEMPTY -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND
run ssi263        rtl/ssi263.sv
run mockingboard  rtl/mockingboard.sv rtl/via6522.v rtl/slot_switches.sv rtl/ay_pair.sv rtl/YM2149.sv rtl/ssi263.sv -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
                  -Wno-CASEINCOMPLETE -Wno-PINCONNECTEMPTY
# -Irtl: the microcode field definitions are a generated `include, and they live
# beside the RTL rather than in the simulator's working directory.
run cpu65c02      -Irtl rtl/cpu65c02.sv
# The exploratory 65816 (branch ucode_65816).  Same generated-include
# arrangement as the 65C02 core.
run cpu65816      -Irtl rtl/cpu65816.sv

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
