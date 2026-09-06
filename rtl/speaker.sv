`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// speaker - the IIe's speaker flip-flop, on the card (docs/AUDIO.md).
//
// Every access to $C030-$C03F toggles it - a read or a write, the byte
// irrelevant, the way the motherboard's own 74LS74 hears the address alone.
// The accesses come by two doors, the same two words the host used to
// toggle its own bit on: a real bus cycle that carried one of the core's
// ops (`real_valid`, and not a dummy - a dummy cycle's address is the
// core's business, and the stream never showed it either) and a fast op the
// accelerated core took from the card (`fast_valid`, rtl/event_merge.sv's
// fast port).  Both in one clock cannot be one core's, but the XOR is
// right for it anyway.
//
// Held low while RES' is asserted: the host's rule (`in_reset_`), and the
// real chip's - the IOU's reset clears the speaker.
//////////////////////////////////////////////////////////////////////////////////
module speaker (
    input  wire        clk,
    input  wire        rst,
    input  wire        res_sync,       // synchronised RES', ACTIVE LOW

    input  wire        real_valid,     // a bus event word this clock...
    input  wire        real_dummy,     // ...that carried no op
    input  wire [15:0] real_addr,
    input  wire        fast_valid,     // a fast op this clock
    input  wire [15:0] fast_addr,

    output logic       level,          // the cone's position
    output logic       toggle          // one clock per toggle, for counting
);

    wire hit_bus  = real_valid && !real_dummy && (real_addr[15:4] == 12'hC03);
    wire hit_fast = fast_valid && (fast_addr[15:4] == 12'hC03);
    wire flip     = hit_bus ^ hit_fast;

    always_ff @(posedge clk) begin
        if (rst || !res_sync) begin
            level  <= 1'b0;
            toggle <= 1'b0;
        end else begin
            level  <= level ^ flip;
            toggle <= flip;
        end
    end

endmodule
