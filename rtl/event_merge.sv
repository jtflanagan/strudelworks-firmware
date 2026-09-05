`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// event_merge - one stream out of two: the bus's cycles and the core's fast ops.
//
// rtl/apple_bus_read.sv produces one event per phi0 cycle, at its data tap,
// whether the cycle carried an op or was a DUMMY (rtl/apple_bus_write.sv).
// rtl/accel_seq.sv produces one per FAST op - an op the core took from the
// card and the bus never saw - on the clock the core took it, which can be
// any clock at all.  The host wants both in program order and the filter
// behind this (rtl/bus_event_filter.sv) wants them no closer than three
// clocks apart, because a SKIP and its event leave on consecutive clocks and
// an input inside that pair would be lost.
//
// So: one FIFO, filled in arrival order, drained one word per three clocks.
// Program order is arrival order.  A fast op that precedes a bus op in the
// program was taken before that op was even offered to the bus, and the bus
// op's event comes ~45 clocks after its present; the fast ops of the run
// before it have drained by then at a word per three clocks against a supply
// of at most a word per eight (the cache's decision takes that long).  When
// both arrive on one clock - a fast op taken on the clock a dummy's event
// is registered - the bus event goes first: it is the older cycle.
//
// The FIFO cannot fill in steady state (drain > supply); if it ever does the
// FAST word is dropped and counted, never the bus's - the host places its
// beam by the bus's words.  The count must read zero; ACCEL_STAT carries it.
// Nothing is enqueued while the capture is off, and what is queued when it
// goes off is dropped: nothing is owed.
//
// The fast word is {0xC, data, {vbl, sync, res, rw}, addr} - the event's
// layout under a tag of its own, so every reader that checks the tag it has
// always checked sees at once that this is an op and not a cycle.
//
// THE DOOR DECIDES (docs/VIRTUAL_TIME.md).  A fast op's word is kept or
// dropped HERE, before the queue, by the rule the filter used to apply after
// it: in sparse a read nobody wants - not a write, not a switch read of
// $C05x/$C08x, not carrying a mark, not on an edge of the blanking level,
// not flagged quiet - is dropped.  In the virtual base a dropped op is still
// a CORE CYCLE, and its count rides IN ORDER: every queued entry carries the
// number of dropped cycles since the entry before it (out_drop), and a
// count with no word to carry it goes out as a CARRIER entry of its own.
// So the cycles between two marks are exact, and a mark or an edge is never
// on a word that is not there.  The producers never shed: the fronts wait
// for room (rtl/iline.sv, rtl/dline.sv fall back to the dispatcher while
// fast_room is low), and a kept word that finds no room - a fault, counted
// in `overflows` - is dropped but still counted as a cycle.
//////////////////////////////////////////////////////////////////////////////////
module event_merge #(
    parameter integer DEPTH = 32
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,
    // The reader's event, with the mark and the dummy flag beside it.
    input  wire        bus_valid,
    input  wire [31:0] bus_data,
    input  wire        bus_mark,
    input  wire [15:0] bus_mark_free,
    input  wire        bus_dummy,
    // The sequencer's fast op, and the levels its word carries.
    input  wire        fast_valid,
    input  wire [15:0] fast_addr,
    input  wire        fast_rw,
    input  wire [7:0]  fast_data,
    input  wire        fast_sync,
    // The virtual beam's mark on a fast word (rtl/vbeam.sv): this op is line
    // 0, cycle 0 of a frame in the core's time.
    input  wire        fast_mark,
    input  wire [15:0] fast_mark_free,
    // A read that changes no switch (rtl/apple_mmu.sv q_swi_quiet): its
    // word is dropped whatever its address, its cycle counted.
    input  wire        fast_quiet,
    // A read the host must have whatever the address rule says: the hard
    // disk's EXECUTE and its completion, served on the card (docs/CXXX.md,
    // "The on-card slots"); master_top decides it from the card's state.
    input  wire        fast_force,
    input  wire        vbl_level,
    input  wire        res_level,       // RES', as the event carries it
    // The rules the door applies: sparse capture, and the virtual base.
    input  wire        sparse,
    input  wire        virt,
    // To the filter: never two on consecutive clocks, nor two clocks apart.
    output logic        out_valid,
    output logic [31:0] out_data,
    output logic        out_mark,
    output logic [15:0] out_mark_free,
    output logic        out_dummy,
    output logic [15:0] out_drop,       // core cycles dropped before this entry
    output logic        out_carrier,    // no word: the count alone
    output logic [7:0]  overflows,
    // For the fronts (rtl/iline.sv, rtl/dline.sv's reads): room to retire
    // into; below it they fall back to the dispatcher rather than shed.
    output wire         fast_room,
    // For a producer that may NOT wait (rtl/dline.sv's posted writes): a
    // REGISTERED level with the margin its use needs.  The front registers
    // this once more, gates a write's retire on that copy, and the write's
    // word arrives the clock after the retire: three edges between the
    // sample and the word's push, each able to take one fast word and at
    // most one of them the bus's, four words in all, and the word's own
    // need is at most two.  Sampled at six, the word always fits.
    output logic        fast_room_w
);
    localparam [3:0] T_FAST = 4'hC;
    localparam integer AW = $clog2(DEPTH);
    localparam integer W  = 1 + 16 + 1 + 16 + 1 + 32;   // carrier, drop, dummy, mark_free, mark, data
    wire [31:0] fast_word = {T_FAST, fast_data, vbl_level, fast_sync, res_level, fast_rw, fast_addr};

    // ---- the fast word's fate, at the door ---------------------------------------
    logic last_vbl = 1'b0;   // the level of the last word, kept or dropped
    wire fast_sw   = (fast_addr[15:8] == 8'hC0) && (fast_addr[7:4] == 4'h5 || fast_addr[7:4] == 4'h8);
    wire fast_edge = (vbl_level != last_vbl);
    wire fast_keep = fast_mark || fast_edge || fast_force ||
                     (!fast_quiet && (!sparse || !fast_rw || fast_sw));

    logic [W-1:0] q [0:DEPTH-1];
    logic [AW:0]  wp = '0, rp = '0;
    wire  [AW:0]  room  = (AW+1)'(DEPTH) - (wp - rp);
    wire          empty = (wp == rp);

    wire push_bus  = enable && bus_valid;
    wire want_fast = enable && fast_valid && fast_keep;
    wire [AW:0] need = push_bus ? (AW+1)'(2) : (AW+1)'(1);
    wire fast_fits = room >= need;
    wire push_fast = want_fast && fast_fits;
    wire drop_fast = enable && fast_valid && !push_fast;
    assign fast_room = room >= (AW+1)'(8);
    always_ff @(posedge clk) fast_room_w <= (rst || !enable) ? 1'b1 : (room >= (AW+1)'(6));

    // The in-order count of dropped core cycles since the last entry.  The
    // bus's word goes first on a collision and carries what came before it;
    // a kept fast word carries what is left; a dropped fast op adds one
    // behind whatever went out this clock.  A count with no word for it
    // goes out as a carrier before it can wrap.
    logic [15:0] pend = 16'd0;
    wire [15:0] pend_after_bus  = push_bus ? 16'd0 : pend;
    wire [15:0] pend_after_fast = push_fast ? 16'd0 : pend_after_bus;
    wire        count_drop      = drop_fast && virt;
    wire        carrier         = enable && !push_bus && !push_fast && (pend >= 16'hFFF0) && (room != '0);
    wire [15:0] pend_next       = carrier ? (count_drop ? 16'd1 : 16'd0)
                                : pend_after_fast + (count_drop ? 16'd1 : 16'd0);

    wire [AW-1:0] wp_bus  = wp[AW-1:0];
    wire [AW-1:0] wp_fast = wp[AW-1:0] + (push_bus ? (AW)'(1) : (AW)'(0));
    wire [AW:0]   pushed  = (push_bus ? (AW+1)'(1) : (AW+1)'(0)) + (push_fast ? (AW+1)'(1) : (AW+1)'(0)) +
                            (carrier ? (AW+1)'(1) : (AW+1)'(0));

    logic [1:0] spacing;                        // clocks until the next pop may go

    always_ff @(posedge clk) begin
        out_valid <= 1'b0;
        if (rst || !enable) begin
            wp <= '0; rp <= '0;
            spacing <= 2'd0;
            pend <= 16'd0;
            last_vbl <= 1'b0;
            if (rst) overflows <= 8'd0;
        end else begin
            // ---- push -----------------------------------------------------------
            if (push_bus)  q[wp_bus]  <= {1'b0, pend, bus_dummy, bus_mark_free, bus_mark, bus_data};
            if (push_fast) q[wp_fast] <= {1'b0, pend_after_bus, 1'b0, fast_mark_free, fast_mark, fast_word};
            if (carrier)   q[wp_bus]  <= {1'b1, pend, 1'b0, 16'd0, 1'b0, 32'd0};
            wp   <= wp + pushed;
            pend <= pend_next;
            if (want_fast && !fast_fits) overflows <= overflows + 8'd1;
            if (fast_valid)     last_vbl <= vbl_level;
            else if (bus_valid) last_vbl <= bus_data[19];

            // ---- pop, one per three clocks ----------------------------------------
            if (spacing != 2'd0) spacing <= spacing - 2'd1;
            else if (!empty) begin
                {out_carrier, out_drop, out_dummy, out_mark_free, out_mark, out_data} <= q[rp[AW-1:0]];
                out_valid <= 1'b1;
                rp <= rp + (AW+1)'(1);
                spacing <= 2'd2;
            end
        end
    end

endmodule
