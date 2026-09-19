`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// msg_master - a message source, as a Wishbone master on the message bus.
//
// The card's sources produce a message a word at a time on a valid/take
// stream - the reply, the notice, HD_DATA, the capture.  The message bus
// (msg_arb) wants a Wishbone master that holds CYC across the whole message,
// because that is what makes the message atomic.  This is the adapter: it
// raises CYC when a message is offered, streams the words as a pipelined
// write burst, and drops CYC only once the last word has been acked.
//
// It is the one place on the master side that reads the protocol, and only
// to know where its own message ends: the length is snooped from the header
// the same way ft601_msg_tx snoops it.  A source that speaks Wishbone itself
// needs none of this and goes straight onto the bus - and may then hold CYC
// across several messages if it wants them sent together.
//
// CYC is registered, never combinational from the stream or from STALL, so
// the arbiter's combinational grant cannot loop through it.  The cost is one
// cycle at the start of each message and one at the end, which against a
// link whose latency floor is the 100 us heartbeat is nothing.
//////////////////////////////////////////////////////////////////////////////////
module msg_master (
    input  wire        clk,
    input  wire        rst,

    // FROM the source: the next word of a message, held until taken.  The
    // first is the header.
    input  wire [31:0] word,
    input  wire        valid,
    output wire        take,

    // TO the bus.  ADR and SEL are constant: the slave is a stream.
    output logic       cyc,
    output wire        stb,
    output wire        we,
    output wire [31:0] adr,
    output wire [31:0] dat,
    output wire [3:0]  sel,
    input  wire        stall,
    input  wire        ack
);

    // Payload words still to send; header seen.
    logic [7:0] left    = 8'd0;
    logic       in_msg  = 1'b0;     // header taken, payload owed
    logic       sending = 1'b0;     // words still to issue this message
    logic [8:0] pending = 9'd0;     // beats accepted, not yet acked

    assign we  = 1'b1;
    assign adr = 32'd0;
    assign sel = 4'hF;
    assign dat = word;

    assign stb  = cyc && sending && valid;
    assign take = stb && !stall;

    wire last_word = take && (in_msg ? (left == 8'd1) : (word[7:0] == 8'd0));

    always_ff @(posedge clk) begin
        if (rst) begin
            cyc     <= 1'b0;
            left    <= 8'd0;
            in_msg  <= 1'b0;
            sending <= 1'b0;
            pending <= 9'd0;
        end else begin
            if (take && !ack)      pending <= pending + 9'd1;
            else if (ack && !take) pending <= pending - 9'd1;

            if (!cyc) begin
                // A message is offered: claim the bus.
                if (valid) begin
                    cyc     <= 1'b1;
                    sending <= 1'b1;
                    in_msg  <= 1'b0;
                end
            end else begin
                if (take) begin
                    if (!in_msg) begin
                        left   <= word[7:0];
                        in_msg <= (word[7:0] != 8'd0);
                    end else begin
                        left   <= left - 8'd1;
                        if (left == 8'd1) in_msg <= 1'b0;
                    end
                    if (last_word) sending <= 1'b0;
                end
                // Done issuing and every ack home: let the bus go.  `pending`
                // is the value from before this cycle's ack, hence the extra
                // term.
                if (!sending && (pending == 9'd0 || (ack && pending == 9'd1)))
                    cyc <= 1'b0;
            end
        end
    end

endmodule
