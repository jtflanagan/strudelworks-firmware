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
// The fast word is the event's 64-bit record under a tag of its own (0xC)
// and class 1, so every reader that checks the tag it has always checked
// sees at once that this is an op and not a cycle; a dummy cycle's record
// leaves here with class 2, so a dummy the filter keeps (an edge) says what
// it is.  Layout: docs/PROTOCOL.md "The event record".
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
    input  wire [63:0] bus_data,
    input  wire        bus_mark,
    input  wire [15:0] bus_mark_free,
    input  wire        bus_dummy,
    // The sequencer's fast op, and the levels its word carries.
    input  wire        fast_valid,
    input  wire [15:0] fast_addr,
    input  wire [7:0]  fast_bank,      // the 65816's bank; 0 on the IIe
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
    // THE RISC-V ENGINE'S WRITE RECORD (tag 0xB, docs/REQ_RVVM.md "The
    // engine-write record"): a write the core never made, which the host's
    // mirror applies in order - an op, never a cycle.  It takes the fast
    // word's place at the staging input on a clock no fast word is kept, and
    // it waits for room rather than shed: the engine holds its next store
    // until eng_take.  A top without the engine ties eng_valid low.
    input  wire        eng_valid,
    input  wire [63:0] eng_rec,
    output wire        eng_take,
    input  wire        vbl_level,
    input  wire        res_level,       // RES', as the event carries it
    // The rules the door applies: sparse capture, and the virtual base.
    input  wire        sparse,
    input  wire        virt,
    // To the filter: never two on consecutive clocks, nor two clocks apart.
    output logic        out_valid,
    output logic [63:0] out_data,
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
    localparam integer W  = 1 + 16 + 1 + 16 + 1 + 64;   // carrier, drop, dummy, mark_free, mark, data
    localparam [3:0] CLS_FAST = 4'd1, CLS_DUMMY = 4'd2;
    // THE BANK RIDES THE RECORD, and until rung 4b it did not.  Word 0's
    // [27:20] is the 65816's bank byte (docs/PROTOCOL.md, "The event
    // record"), and this was a hardwired 8'd0 - correct on a IIe, where the
    // bank is always zero and the comment in master_top said as much, and
    // WRONG on a IIgs, where 98.7% of ops are fast ops and any one of them
    // may name a bank.  accel_seq computed it, master_top declared it, and
    // nothing carried it here: the host was told every fast op happened in
    // bank $00, so a write to auxiliary memory, to a Mega II bank or to any
    // bank above the first landed in bank $00 of the mirror and nowhere
    // near where the machine had put it.
    //
    // NO ORACLE COULD SEE IT.  The mirror replay (tools/gs_mirror_test.sh)
    // takes the BENCH's op stream, which sim/boot_gs_tb.sv writes directly in
    // the host's record shape - it never passes through this module - so the
    // replay's banks were right and the hardware's were zero.
    wire [63:0] fast_word = {fast_data, CLS_FAST, 4'd0, 16'd0,
                             T_FAST, fast_bank, vbl_level, fast_sync, res_level, fast_rw, fast_addr};
    // The bus's record, its class marked when the cycle carried no op.
    wire [63:0] bus_word  = {bus_data[63:56], bus_dummy ? CLS_DUMMY : bus_data[55:52], bus_data[51:0]};

    // ---- the fast word's fate, at the door ---------------------------------------
    logic last_vbl = 1'b0;   // the level of the last word, kept or dropped
    // A read carrying state the host needs: the toggles $C05x, the language
    // card $C08x - and the speaker $C03x, where the read IS the click.
    wire fast_sw   = (fast_addr[15:8] == 8'hC0) &&
                     (fast_addr[7:4] == 4'h5 || fast_addr[7:4] == 4'h8 || fast_addr[7:4] == 4'h3);
    wire fast_edge = (vbl_level != last_vbl);
    // FULL CAPTURE IS FULL, and it was not.  `!sparse` used to sit INSIDE the
    // `!fast_quiet` conjunction, so a quiet op - one apple_mmu believes
    // changes no switch (q_swi_quiet) - was dropped from the stream even when
    // the host had asked for every cycle.  Two things are wrong with that.
    // The lesser: a full capture that silently omits ops is not one, and
    // rtl/bus_event_filter.sv has always had `!sparse` as a TOP-LEVEL term
    // for the bus's side, so the two halves of the same stream disagreed
    // about what "full" means.  The greater: "quiet" is the CARD's opinion
    // that the op changes nothing, and it is only safe while the card's
    // switch state and the host's already agree - once they have diverged,
    // suppressing the op suppresses the very event that would have corrected
    // the host, and the divergence STICKS instead of healing on the next
    // touch.  So `!sparse` comes out to the top: in full capture nothing is
    // ever dropped, and a divergence is visible in the trace that finds it.
    wire fast_keep = fast_mark || fast_edge || fast_force || !sparse ||
                     (!fast_quiet && (!fast_rw || fast_sw));

    // ---- the queue -----------------------------------------------------------------
    // A LUTRAM with ONE write port, behind a two-wide staging stage.  The
    // queue used to be an array written at two places in one clock (the
    // bus's entry and a fast op's, on a collision), which no RAM primitive
    // does - so it was flops with a 32:1 mux behind every bit: 4000 LUTs at
    // 67 bits an entry, 6000 at the record's 99.  Now every entry lands in
    // the staging stage first (two may, on a collision clock), and the
    // stage drains one per clock into the RAM.  Two per clock arrive only
    // when the bus's event and a fast op coincide, once per bus cycle at
    // most, and the stage drains a clock later: its occupancy never exceeds
    // two, and SW is four so that a burst of fast ops on the clocks right
    // after cannot touch it either.  Order is arrival order still - the
    // stage is a FIFO - and the pop reads the RAM asynchronously as before.
    localparam integer SW = 4;
    localparam integer SAW = $clog2(SW);
    (* ram_style = "distributed" *) logic [W-1:0] ram [0:DEPTH-1];
    logic [W-1:0] stg [0:SW-1];
    logic [SAW:0] sh = '0, st = '0;         // staging head (drains) and tail (fills)
    logic [AW:0]  wp = '0, wr = '0, rp = '0; // accepted, landed in the RAM, popped
    wire  [AW:0]  room  = (AW+1)'(DEPTH) - (wp - rp);
    wire  [SAW:0] stg_used = st - sh;
    wire  [SAW:0] stg_room = (SAW+1)'(SW) - stg_used;
    wire          empty = (wr == rp);

    wire push_bus  = enable && bus_valid;
    wire want_fast = enable && fast_valid && fast_keep;
    wire [AW:0] need = push_bus ? (AW+1)'(2) : (AW+1)'(1);
    wire fast_fits = (room >= need) && (stg_room >= (SAW+1)'(need));
    wire push_fast = want_fast && fast_fits;
    wire push_eng  = enable && eng_valid && !want_fast && fast_fits;
    assign eng_take = eng_valid && (!enable || push_eng);   // capture off: nothing is owed
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
    wire [15:0] pend_after_fast = (push_fast || push_eng) ? 16'd0 : pend_after_bus;
    wire        count_drop      = drop_fast && virt;
    wire        carrier         = enable && !push_bus && !push_fast && !push_eng && (pend >= 16'hFFF0) && (room != '0) && (stg_room != '0);
    wire [15:0] pend_next       = carrier ? (count_drop ? 16'd1 : 16'd0)
                                : pend_after_fast + (count_drop ? 16'd1 : 16'd0);

    wire [SAW-1:0] st_bus  = st[SAW-1:0];
    wire [SAW-1:0] st_fast = st[SAW-1:0] + (push_bus ? (SAW)'(1) : (SAW)'(0));
    wire [AW:0]    pushed  = (push_bus ? (AW+1)'(1) : (AW+1)'(0)) + ((push_fast || push_eng) ? (AW+1)'(1) : (AW+1)'(0)) +
                             (carrier ? (AW+1)'(1) : (AW+1)'(0));
    // The stage drains one entry per clock into the RAM's one write port.
    wire drain = (stg_used != '0);

    logic [1:0] spacing;                        // clocks until the next pop may go

    always_ff @(posedge clk) begin
        out_valid <= 1'b0;
        if (rst || !enable) begin
            wp <= '0; wr <= '0; rp <= '0;
            sh <= '0; st <= '0;
            spacing <= 2'd0;
            pend <= 16'd0;
            last_vbl <= 1'b0;
            if (rst) overflows <= 8'd0;
        end else begin
            // ---- push, into the stage --------------------------------------------
            if (push_bus)  stg[st_bus]  <= {1'b0, pend, bus_dummy, bus_mark_free, bus_mark, bus_word};
            if (push_fast) stg[st_fast] <= {1'b0, pend_after_bus, 1'b0, fast_mark_free, fast_mark, fast_word};
            if (push_eng)  stg[st_fast] <= {1'b0, pend_after_bus, 1'b0, 16'd0, 1'b0, eng_rec};
            if (carrier)   stg[st_bus]  <= {1'b1, pend, 1'b0, 16'd0, 1'b0, 64'd0};
            st   <= st + (SAW+1)'(pushed);
            wp   <= wp + pushed;
            pend <= pend_next;
            if (want_fast && !fast_fits) overflows <= overflows + 8'd1;
            if (fast_valid)     last_vbl <= vbl_level;
            else if (bus_valid) last_vbl <= bus_data[19];

            // ---- the stage into the RAM, one per clock ----------------------------
            if (drain) begin
                ram[wr[AW-1:0]] <= stg[sh[SAW-1:0]];
                wr <= wr + (AW+1)'(1);
                sh <= sh + (SAW+1)'(1);
            end

            // ---- pop, one per three clocks ----------------------------------------
            if (spacing != 2'd0) spacing <= spacing - 2'd1;
            else if (!empty) begin
                {out_carrier, out_drop, out_dummy, out_mark_free, out_mark, out_data} <= ram[rp[AW-1:0]];
                out_valid <= 1'b1;
                rp <= rp + (AW+1)'(1);
                spacing <= 2'd2;
            end
        end
    end

endmodule
