`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// kbd_notice - the KBD_EVENT notice: a press was resolved, said unasked.
//
// The host presses one key and waits for it to be resolved before the next
// (docs/KEYBOARD.md); this is how it is told, without polling.  kbd_inject
// pulses `changed` when a count moves or the lock sees a real key, and when
// the host has asked - KBD_CTRL's notify, the silent-until-asked rule - one
// two-word message goes out through the message bus:
//
//   header   {free, T_KBD_EVENT, len=1}
//            free[0] strobe, [1] seen, [2] touched, [3] lock,
//            free[15:8] the key of the press resolved last
//   payload  {replaced, flushed, taken, pressed}
//
// A LEVEL, NOT A PULSE - the CPU_HOLD notice's rule, kept for the same
// reason.  The words carry the state as it is when each goes out, not as it
// was when `changed` fired, and one pending flag is the whole queue: a
// change while a notice waits is folded into that notice, and a change
// while it is being sent raises another after it.  So the host always ends
// with the truth, and the card never holds more than one notice - which is
// all it needs to, because a host that presses one key at a time gets one
// resolution at a time.  A host that presses without waiting can see two
// presses resolved by one notice; the counts still add up.
//
// The payload can be newer than the header by a clock, if a count moves
// between the two takes.  Both are true at the moment they go out, and the
// notice that follows carries the header's view of it too.
//////////////////////////////////////////////////////////////////////////////////
module kbd_notice (
    input  wire        clk,
    input  wire        rst,

    input  wire        changed,        // one clock, from kbd_inject
    input  wire        notify,         // the host asked, from KBD_CTRL
    input  wire [3:0]  flags,          // {lock, touched, seen, strobe}
    input  wire [6:0]  resolved_key,
    input  wire [31:0] counts,         // {replaced, flushed, taken, pressed}

    // TO msg_master: the next word, held until taken.  The first is the
    // header.
    output wire [31:0] word,
    output wire        valid,
    input  wire        take
);

    localparam [7:0] T_KBD_EVENT = 8'h1C;

    logic pending = 1'b0;               // a notice is owed
    logic in_msg  = 1'b0;               // the header went, the payload is owed

    wire raise = changed && notify;

    always_ff @(posedge clk) begin
        if (rst) begin
            pending <= 1'b0;
            in_msg  <= 1'b0;
        end else begin
            if (raise) pending <= 1'b1;
            if (take) begin
                if (!in_msg) begin
                    in_msg <= 1'b1;
                    // The header is out: this notice is no longer owed,
                    // unless a change this very clock owes another.
                    if (!raise) pending <= 1'b0;
                end else begin
                    in_msg <= 1'b0;
                end
            end
        end
    end

    assign valid = in_msg || pending;
    assign word  = in_msg ? counts
                          : {1'b0, resolved_key, 4'd0, flags, T_KBD_EVENT, 8'd1};

endmodule
