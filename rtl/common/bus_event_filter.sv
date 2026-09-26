`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// bus_event_filter - send the host the cycles it needs, and count the rest.
//
// The reader produces one event per phi0 cycle and the host has always been
// sent every one of them: four bytes a cycle, four megabytes a second.  Most
// of those cycles are reads, and a read of RAM or ROM tells the host nothing
// it does not already know - its mirror of memory follows the writes, its
// display follows the writes and the soft switches, its sound follows the
// I/O page.  So a second mode, SPARSE, selected by BUS_ENABLE free[2] and
// latched for the capture like the source select: the host gets
//
//   - every access, read or write, to $C000-$CFFF: the switches, the
//     keyboard, the speaker, the slots, the language card's double-read
//     prewrite - everything that acts on a read acts on one in this page;
//   - every write, wherever it lands;
//   - the two cycles of each frame where the video scanner's blanking
//     level (bit 19, rtl/vbl_lock.sv) changes: line 192, cycle 0 and line
//     0, cycle 0, which the host places its beam by, read or not;
//   - every cycle where RES' (bit 17) changes: the host's consumers treat
//     reset as a level carried on events, and its sound clocks stop during
//     one;
//   - the first cycle after the capture is enabled, so the host has a
//     baseline for both levels before it sees a count.
//
// Nothing else.  THE CYCLES NOT SENT ARE COUNTED, because the host draws
// the picture cycle by cycle from the beam's position (docs/VBL.md) and
// runs its sample clock on cycles: before each kept event a SKIP word goes
// out saying how many cycles passed since the word before it -
//
//   {4'hD, count[27:0]}      count >= 1     (word 0; word 1 is zero)
//
// - a tag the event record never carries (it is 0xF), so the host tells the
// two apart by the nibble it already checks.  Every entry here is the
// 64-bit record of docs/PROTOCOL.md; the capture puts its two words on the
// wire.  A count that reaches CAP goes
// out on its own, event or not: a program sitting in a loop that neither
// writes nor touches I/O still moves the host's clocks a millisecond at a
// time, and the count never nears its 28 bits.  A pending count when the
// capture is disabled is dropped: the capture ended, and nothing is owed.
//
// TIMING.  Events arrive one clock wide and some ninety clocks apart, and
// rtl/bus_event_capture.sv takes one word per clock, so a SKIP goes out on
// the clock the kept event arrives and the event itself the clock after,
// from a one-deep hold - two writes on consecutive clocks, which the
// FIFO takes.  Events must therefore be at least THREE clocks apart; a
// testbench that packs them closer is wrong, not this module.  The mark
// (rtl/vbl_lock.sv's line 0, cycle 0) travels with its event and never
// with a SKIP, so the capture's cut lands between the SKIP and the marked
// event: on the wire, SKIP, then VBL_MARK, then the event.
//
// In FULL mode every event is kept and the count stays zero, so this is a
// register in the path and nothing more: one clock of latency, both modes,
// and the pass-through exercised by every capture there has ever been.
//
// ...UNTIL THE CORE IS ACCELERATED (rtl/accel_seq.sv, docs/ACCELERATION.md),
// when two more kinds of word arrive through rtl/event_merge.sv:
//
//   - a DUMMY cycle: a bus cycle that carried no op, the parked read of
//     $0000.  It is a cycle, so it moves the host's clocks; it is nobody's
//     op, so the host has no use for its word.  It goes into the count - in
//     BOTH modes, so a full capture of an accelerated machine has SKIPs in
//     it - UNLESS it is one of the cycles the keep rule exists for: the
//     first after enable, the marked cycle, a cycle where the blanking level
//     or RES' changes.  Under acceleration most cycles are dummies and the
//     whole of a RES'-low window is, so an edge that fell on a dummy and
//     was counted away would leave the host's beam slipping every frame and
//     its mirror never seeing a reset.  Such a dummy is kept as the event
//     it is: a read of $0000 is harmless to every consumer the host has.
//   - a FAST op, tagged 0xC: an op the core took from the card, never a
//     cycle.  Kept by the rule a cycle's event would be (every one in full,
//     writes in sparse - a fast op is a read of RAM, LC or ROM, the
//     motherboard's $C1xx-$CFxx ROM included, never a switch), NEVER counted, and
//     NEVER consulted for the edge rule: a fast op taken between one cycle's
//     tick and the next carries the next cycle's level, and an edge seen on
//     it would not be seen again on the cycle's own event - the one the
//     host places its beam by.
//////////////////////////////////////////////////////////////////////////////////

module bus_event_filter #(
    // Cycles an unsent run may reach before a SKIP goes out on its own.
    // 1024 is ~1 ms of bus: forty-odd audio samples, and one word per
    // capture flush period in a silent loop.
    parameter integer CAP = 1024
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,        // the capture is on (BUS_ENABLE free[0])
    input  wire        sparse,        // send the few, count the rest

    input  wire [63:0] in_data,
    input  wire        in_valid,
    input  wire        in_mark,
    input  wire [15:0] in_mark_free,
    input  wire        in_dummy,       // this cycle carried no op (see the header)
    // The virtual base (docs/VIRTUAL_TIME.md): the core's cycles are the
    // cycles.  A fast word that reaches here is kept - the merge's door
    // decided it (rtl/event_merge.sv) - and is a cycle; a dummy is not
    // (dropped, counted by nothing).  in_drop is the merge's in-order
    // count of dropped core cycles before this entry, and a carrier entry
    // is that count alone.
    input  wire        virt,
    input  wire [15:0] in_drop,
    input  wire        in_carrier,

    output logic [63:0] out_data,
    output logic        out_valid,
    output logic        out_mark,
    output logic [15:0] out_mark_free
);

    localparam [3:0] T_SKIP = 4'hD;
    localparam [3:0] T_FAST = 4'hC;
    localparam [3:0] T_ENG  = 4'hB;

    wire in_fast = (in_data[31:28] == T_FAST);
    // The RISC-V engine's write record (rtl/event_merge.sv): always kept, never
    // a cycle, never consulted for an edge (its bits 19:16 are byte enables).
    wire in_eng  = (in_data[31:28] == T_ENG);
    wire in_word = in_valid && !in_carrier;
    wire in_vbl = in_data[19];
    wire in_res = in_data[17];
    wire in_rw  = in_data[16];
    wire in_io  = (in_data[15:12] == 4'hC);

    logic        prev_vbl = 1'b0;
    logic        prev_res = 1'b1;       // RES' idle is high
    logic        first    = 1'b1;
    logic [27:0] cnt      = '0;

    // The kept event waiting behind its SKIP.
    logic        hold_valid = 1'b0;
    logic [63:0] hold_data  = '0;
    logic        hold_mark  = 1'b0;
    logic [15:0] hold_free  = '0;

    wire on_edge = first || in_mark || (in_vbl != prev_vbl) || (in_res != prev_res);
    // A fast word here was kept at the merge's door (a write, a switch
    // read, a mark, an edge - never a dropped read).
    wire keep = (in_fast || in_eng) ? 1'b1 :
                in_dummy ? (!virt && on_edge) :
                           (!sparse || on_edge || in_io || !in_rw);
    // What is a cycle: the bus's in the real base (a fast op neither counts
    // nor moves the edge rule), the core's in the virtual (a dummy neither).
    wire cycle = in_word && !in_eng && (virt ? !in_dummy : !in_fast);
    // The pending count: the cycles not yet sent, with this clock's own
    // contributions folded in - a shed core cycle (the virtual base only)
    // and a cycle whose word is not kept.  One arithmetic for every path.
    wire        this_unkept = in_word && cycle && !keep && !hold_valid;
    wire [28:0] pend = {1'b0, cnt} + (in_valid ? {13'd0, in_drop} : 29'd0) + (this_unkept ? 29'd1 : 29'd0);

    always_ff @(posedge clk) begin
        out_valid <= 1'b0;
        out_mark  <= 1'b0;
        if (rst || !enable) begin
            cnt        <= '0;
            first      <= 1'b1;
            prev_vbl   <= 1'b0;
            prev_res   <= 1'b1;
            hold_valid <= 1'b0;
        end else if (hold_valid) begin
            // The clock after a SKIP: the event it counted up to.  (The merge
            // spaces its words three clocks apart, so nothing arrives here.)
            out_data      <= hold_data;
            out_valid     <= 1'b1;
            out_mark      <= hold_mark;
            out_mark_free <= hold_free;
            hold_valid    <= 1'b0;
            cnt           <= pend[27:0];
        end else if (in_word && keep) begin
            if (cycle) begin
                prev_vbl <= in_vbl;
                prev_res <= in_res;
                first    <= 1'b0;
            end
            if (pend != 29'd0) begin
                out_data   <= {32'd0, T_SKIP, pend[27:0]};
                out_valid  <= 1'b1;
                hold_data  <= in_data;
                hold_mark  <= in_mark;
                hold_free  <= in_mark_free;
                hold_valid <= 1'b1;
                cnt        <= '0;
            end else begin
                out_data      <= in_data;
                out_valid     <= 1'b1;
                out_mark      <= in_mark;
                out_mark_free <= in_mark_free;
            end
        end else begin
            // No word kept this clock: a cycle not sent, a fast read nobody
            // wants, a dummy in the virtual base, or nothing at all - the
            // count grows by what this clock added, and flushes at CAP.
            if (cycle) begin
                prev_vbl <= in_vbl;
                prev_res <= in_res;
                first    <= 1'b0;
            end
            if (pend >= 29'(CAP)) begin
                out_data  <= {32'd0, T_SKIP, 28'(CAP)};
                out_valid <= 1'b1;
                cnt       <= 28'(pend - 29'(CAP));
            end else begin
                cnt <= pend[27:0];
            end
        end
    end

endmodule
