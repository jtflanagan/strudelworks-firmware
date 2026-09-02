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
//////////////////////////////////////////////////////////////////////////////////
module event_merge #(
    parameter integer DEPTH = 16
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
    input  wire        vbl_level,
    input  wire        res_level,       // RES', as the event carries it

    // To the filter: never two on consecutive clocks, nor two clocks apart.
    output logic        out_valid,
    output logic [31:0] out_data,
    output logic        out_mark,
    output logic [15:0] out_mark_free,
    output logic        out_dummy,

    output logic [7:0]  overflows,

    // For producers that shed at the source (rtl/iline.sv, rtl/dline.sv's
    // reads): comfortably more free slots than one clock can consume, so a
    // word offered under this level can never be the one that overflows.
    output wire         fast_room,
    // For a producer that may NOT shed (rtl/dline.sv's posted writes): a
    // REGISTERED level with the margin its use needs.  The front registers
    // this once more, gates a write's retire on that copy, and the write's
    // word arrives the clock after the retire: three edges between the
    // sample and the word's push, each able to take one fast word and at
    // most one of them the bus's, four words in all, and the word's own
    // need is at most two.  Sampled at six, the word always fits.  The
    // readers' level above sits one higher so that in a saturated turbo
    // run - reads shedding, a pop every three clocks - the room hovers
    // where this stays true and a write never waits.
    output logic        fast_room_w
);

    localparam [3:0] T_FAST = 4'hC;
    localparam integer AW = $clog2(DEPTH);
    localparam integer W  = 32 + 1 + 16 + 1;    // data, mark, mark_free, dummy

    wire [31:0] fast_word = {T_FAST, fast_data, vbl_level, fast_sync, res_level, fast_rw, fast_addr};

    logic [W-1:0] q [0:DEPTH-1];
    logic [AW:0]  wp, rp;                       // one extra bit: full vs empty
    wire  [AW:0]  count = wp - rp;
    wire          empty = (wp == rp);
    wire  [AW:0]  room  = (AW+1)'(DEPTH) - count;

    // Two writers a clock at most: the bus's word first, then the fast op's.
    wire push_bus  = enable && bus_valid;
    wire push_fast = enable && fast_valid;
    wire [AW:0] need = push_bus ? (AW+1)'(2) : (AW+1)'(1);
    wire fast_fits = room >= need;
    assign fast_room = room >= (AW+1)'(7);
    always_ff @(posedge clk) fast_room_w <= (rst || !enable) ? 1'b1 : (room >= (AW+1)'(6));
    wire take_fast = push_fast && fast_fits;
    wire [AW-1:0] wp_fast = wp[AW-1:0] + (push_bus ? (AW)'(1) : (AW)'(0));
    wire [AW:0]   pushed  = (push_bus ? (AW+1)'(1) : (AW+1)'(0)) + (take_fast ? (AW+1)'(1) : (AW+1)'(0));

    logic [1:0] spacing;                        // clocks until the next pop may go

    always_ff @(posedge clk) begin
        out_valid <= 1'b0;
        if (rst || !enable) begin
            wp <= '0; rp <= '0;
            spacing <= 2'd0;
            if (rst) overflows <= 8'd0;
        end else begin
            // ---- push -----------------------------------------------------------
            if (push_bus)  q[wp[AW-1:0]] <= {bus_dummy, bus_mark_free, bus_mark, bus_data};
            if (take_fast) q[wp_fast]    <= {1'b0, 16'd0, 1'b0, fast_word};
            wp <= wp + pushed;
            if (push_fast && !fast_fits) overflows <= overflows + 8'd1;

            // ---- pop, one per three clocks ----------------------------------------
            if (spacing != 2'd0) spacing <= spacing - 2'd1;
            else if (!empty) begin
                {out_dummy, out_mark_free, out_mark, out_data} <= q[rp[AW-1:0]];
                out_valid <= 1'b1;
                rp <= rp + (AW+1)'(1);
                spacing <= 2'd2;
            end
        end
    end

endmodule
