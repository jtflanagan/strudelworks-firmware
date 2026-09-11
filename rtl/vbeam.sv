`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// vbeam - the beam position every consumer takes: the real scanner's counter
// when the core keeps the bus's time, a VIRTUAL counter stepped once per core
// cycle when it does not.  docs/VIRTUAL_TIME.md.
//
// A cycle-counting program syncs to the beam once and then counts its own
// cycles to place everything else in the frame.  Accelerated, its cycles are
// not the bus's, so the beam it must see - the floating bus, $C019, bit 19 of
// every stream word, the frame mark the host renders from - has to advance
// with ITS cycles.  This module is that beam:
//
//   virt low   every output is rtl/vbl_lock.sv's, passed through: the real
//              beam, the real mark.
//   virt high  seeded from the real counter on the clock virt rises, then
//              stepped by the core's cycles: a fast op's retire (fast_tick -
//              the tick the floppy and the Mockingboard keep time by) or a
//              real bus op of the core's own (bus_tick with neither the dummy
//              nor the override flag: a dummy is the bus idling while the
//              core runs fast, an override is the hold's or a DMA's, and
//              neither is a core cycle).  The frame is the lock's length.
//
// The position describes the cycle IN FLIGHT, as vbl_lock's does: a bus op's
// event is registered the clock before its data tick and reads the level
// then; a fast op's word is pushed on the clock of its tick and reads the
// level then; the step lands after.  A bus tick and a fast tick on one
// clock (the merge allows it) step twice, and the fast word's origin test
// looks past the bus op's step.
//
// The mark: the word at line 0, cycle 0 - a bus event (mark_bus, which
// rtl/card_link.sv pairs with the event as it pairs vbl_lock's) or a fast
// word (mark_fast, rtl/event_merge.sv's fast side).  mark_free carries the
// frame count, PAL, and in bit 1 the VIRTUAL flag the host switches its
// time base on.
//
// WALL: THE IIgs's BEAM RUNS AT THE BUS'S CADENCE (user decision 2026-09-11).
// A real IIgs accelerator cannot speed up the 1 MHz bus or the VGC hanging
// off it: the beam, the VBL, the scan-line interrupt and the toolbox's ticks
// arrive at wall speed whatever the CPU does, and a program that counts
// cycles against the beam simply finds it slower.  So with `wall` high the
// counter steps on EVERY bus cycle - dummy, override or the core's own, each
// of them one microsecond of the IIe's bus this card lives on - and never on
// a fast tick; the mark lands on a bus word only; and the VIRTUAL flag is
// LOW, because to the host this IS the bus's base: a dummy's cycle counts,
// a fast word's does not, and every frame is shown.  `virt` stays high with
// it, since there is no real scanner to pass through on that machine
// (rtl/master_top.sv, "the beam every consumer takes").
//////////////////////////////////////////////////////////////////////////////////
module vbeam (
    input  wire        clk,
    input  wire        rst,
    input  wire        virt,
    input  wire        wall,        // the counter runs on the bus's cadence (above)

    // The real counter (rtl/vbl_lock.sv), and its own mark.
    input  wire        real_locked,
    input  wire [8:0]  real_v,
    input  wire [6:0]  real_h,
    input  wire        pal,
    input  wire        notify,
    input  wire        real_mark,
    input  wire [15:0] real_mark_free,

    // The core's cycles.
    input  wire        bus_tick,
    input  wire        op_dummy,
    input  wire        op_ovr,
    input  wire        fast_tick,

    output wire        locked,
    output wire [8:0]  scan_v,
    output wire [6:0]  scan_h,
    output wire        vbl_level,
    output wire        mark_bus,
    output wire        mark_fast,
    output wire [15:0] mark_free
);
    `include "scan_addr.vh"

    logic [8:0] v = 9'd0;
    logic [6:0] h = 7'd0;
    logic       virt_q = 1'b0;
    logic [7:0] frames = 8'd0;

    wire [8:0] lines = pal ? SCAN_PAL_LINES : SCAN_NTSC_LINES;

    // One step of the counter.
    function automatic [15:0] step(input [8:0] cv, input [6:0] ch, input [8:0] nl);
        begin
            if (ch != 7'd64)            step = {cv, ch + 7'd1};
            else if (cv == nl - 9'd1)   step = {9'd0, 7'd0};
            else                        step = {cv + 9'd1, 7'd0};
        end
    endfunction

    wire tick_bus  = bus_tick && (wall || (!op_dummy && !op_ovr));
    wire tick_fast = fast_tick && !wall;
    wire [15:0] after_bus = tick_bus ? step(v, h, lines) : {v, h};
    wire [15:0] after_all = tick_fast ? step(after_bus[15:7], after_bus[6:0], lines) : after_bus;

    always_ff @(posedge clk) begin
        virt_q <= virt && !rst;
        if (rst) begin
            v <= 9'd0; h <= 7'd0; frames <= 8'd0;
        end else if (virt && !virt_q) begin
            // The transition: continue from where the real beam is.
            v <= real_v; h <= real_h;
        end else if (virt) begin
            {v, h} <= after_all;
            if (mark_bus || mark_fast) frames <= frames + 8'd1;
        end
    end

    wire at0_bus  = (v == 9'd0) && (h == 7'd0);
    wire at0_fast = (after_bus == 16'd0);

    assign locked    = real_locked;
    assign scan_v    = virt_q ? v : real_v;
    assign scan_h    = virt_q ? h : real_h;
    assign vbl_level = virt_q ? (real_locked && (v >= 9'd192)) : (real_locked && (real_v >= 9'd192));
    assign mark_bus  = virt_q ? (tick_bus  && real_locked && notify && at0_bus)  : real_mark;
    assign mark_fast = virt_q && tick_fast && real_locked && notify && at0_fast;
    assign mark_free = virt_q ? {frames, 6'd0, !wall, pal} : real_mark_free;

endmodule
