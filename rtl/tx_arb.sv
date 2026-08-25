`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// tx_arb - lets a register reply into the outgoing stream without breaking it.
//
// WHY THIS EXISTS.  bus_event_capture owns the path into the TX FIFO and emits
// whole messages: a header, then the payload blocks the header's `len` promised.
// A register reply cannot simply be pushed when it is ready, because "when it is
// ready" is usually the middle of a BUS_EVENTS payload, and words inserted there
// are read by the host as event data.  The frame does not break loudly - the
// parser has no sync word and deliberately cannot resynchronise (see
// docs/PROTOCOL.md) - so the link would carry on producing plausible nonsense.
//
// So this tracks message boundaries in the stream it is forwarding, by snooping
// the length out of each header and counting down.  Same technique
// ft601_msg_tx uses on the same words a stage later, and for a related reason.
//
// MAKING THE GAP, rather than waiting for one.  With a reply pending at a
// boundary this asserts `src_full` upstream, so capture stops offering words and
// the gap is manufactured.  Waiting for one to occur naturally would work almost
// always on this link and starve on a busy one, which is the worst shape of bug
// to leave in: it appears only under load and looks like a lost reply.
//
// The reply is three words - header, address, data - and once started it is
// emitted to completion.  Nothing can preempt it, so no boundary check is needed
// on the way out.
//
// A NOTICE takes the same slot.  The card has one thing to say unasked - that
// the boot hold engaged or released (docs/BOOT_MENU.md) - and it is a single
// header-only word, injected at a boundary exactly as a reply is.  A reply
// wins when both are waiting: the host is blocked on a reply and merely
// listening for a notice.  The notice word is read at the moment it goes out,
// so a level that changed while waiting is reported as it is, not as it was.
//
// AN APPLICATION MESSAGE takes it too, and is the general case of the other
// two: a whole message of any length, streamed a word at a time from a source
// that holds each word until it is taken.  The first word is its header, and
// the length is snooped out of it the same way it is snooped out of the
// capture's - so this module needs to know nothing about the type.  Today
// that source is the hard disk sending a block to the host (rtl/hd_card.sv,
// HD_DATA); anything else the card ever has to say at length takes the same
// port.  Lowest priority of the three: a reply first, then a notice, then
// this, since a 130-word block is the one that can make the others wait.
// Once started it is emitted to completion; a source that stalls mid-message
// stalls the link, which is bounded by definition (docs/PROTOCOL.md case 8).
//////////////////////////////////////////////////////////////////////////////////
module tx_arb #(
    parameter [7:0] T_REG_VALUE = 8'h16
) (
    input  wire        clk,
    input  wire        rst,

    // FROM bus_event_capture.  src_full is its back pressure, and this module
    // drives it high to open a slot for a reply.
    input  wire [31:0] src_data,
    input  wire        src_push,
    output wire        src_full,

    // FROM reg_bridge.  rsp_valid is held until rsp_take.
    input  wire [31:0] rsp_addr,
    input  wire [31:0] rsp_data,
    input  wire        rsp_valid,
    output logic       rsp_take,

    // FROM the top: an unsolicited one-word message.  note_valid is held until
    // note_take; note_word is sampled when it is emitted.
    input  wire [31:0] note_word,
    input  wire        note_valid,
    output logic       note_take,

    // FROM an application source: a whole message, one word at a time.
    // aux_valid says aux_word is the next word of it (the first is a header);
    // aux_take, the same cycle, says it was pushed and the source must offer
    // the next.  Combinational, unlike rsp_take - a stream cannot afford the
    // cycle of lag a level-and-acknowledge handshake has.
    input  wire [31:0] aux_word,
    input  wire        aux_valid,
    output wire        aux_take,

    // TO the TX FIFO
    output logic [31:0] tx_data,
    output logic        tx_push,
    input  wire         tx_full
);

    // 0 = forwarding, 1..3 = emitting word N of the reply, 4 = the notice,
    // 5 = streaming an application message.
    logic [2:0] inj = 3'd0;
    wire injecting = (inj != 3'd0);
    wire in_aux    = (inj == 3'd5);

    // Payload blocks still owed by the header last forwarded.  Zero means the
    // next word out of the source is a header, which is the only safe moment.
    logic [7:0] blocks_left = 8'd0;
    wire at_boundary = (blocks_left == 8'd0);

    // The application message's own countdown: its header's len, then down
    // to zero.  aux_hdr says the next word taken is the header.
    logic [7:0] aux_left = 8'd0;
    logic       aux_hdr  = 1'b1;

    wire want_rsp  = rsp_valid  && at_boundary && !injecting;
    wire want_note = note_valid && at_boundary && !injecting && !rsp_valid;
    wire want_aux  = aux_valid  && at_boundary && !injecting && !rsp_valid && !note_valid;
    wire want      = want_rsp || want_note || want_aux;

    // Hold capture off while a reply is pending or in flight.  It already
    // handles a full FIFO, so this needs no new behaviour from it.
    assign src_full = tx_full || injecting || want;

    assign aux_take = in_aux && aux_valid && !tx_full;

    always_comb begin
        if (injecting) begin
            tx_push = in_aux ? aux_take : !tx_full;
            case (inj)
                3'd1:    tx_data = {16'd0, T_REG_VALUE, 8'd2};  // free, type, len
                3'd2:    tx_data = rsp_addr;
                3'd3:    tx_data = rsp_data;
                3'd5:    tx_data = aux_word;
                default: tx_data = note_word;
            endcase
        end else begin
            tx_push = src_push && !tx_full;
            tx_data = src_data;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            inj         <= 3'd0;
            blocks_left <= 8'd0;
            rsp_take    <= 1'b0;
            note_take   <= 1'b0;
            aux_left    <= 8'd0;
            aux_hdr     <= 1'b1;
        end else begin
            rsp_take  <= 1'b0;
            note_take <= 1'b0;

            if (in_aux) begin
                // One word per take.  The header sets the count; the last
                // payload word - or a header owing none - ends the message.
                if (aux_take) begin
                    if (aux_hdr) begin
                        aux_hdr  <= 1'b0;
                        aux_left <= aux_word[7:0];
                        if (aux_word[7:0] == 8'd0) begin
                            inj     <= 3'd0;
                            aux_hdr <= 1'b1;
                        end
                    end else begin
                        aux_left <= aux_left - 8'd1;
                        if (aux_left == 8'd1) begin
                            inj     <= 3'd0;
                            aux_hdr <= 1'b1;
                        end
                    end
                end
            end else if (injecting) begin
                if (!tx_full) begin
                    if (inj == 3'd3) begin
                        inj      <= 3'd0;
                        rsp_take <= 1'b1;
                    end else if (inj == 3'd4) begin
                        inj       <= 3'd0;
                        note_take <= 1'b1;
                    end else begin
                        inj <= inj + 3'd1;
                    end
                end
            end else begin
                // Track the boundary on words actually forwarded.
                if (src_push && !tx_full) begin
                    blocks_left <= at_boundary ? src_data[7:0] : (blocks_left - 8'd1);
                end
                // Start only in a cycle where nothing is being forwarded, so a
                // reply can never land between a header and its payload.
                // src_full above guarantees this cycle arrives.
                //
                // !rsp_take is what stops the reply going out twice.  rsp_take
                // is registered, so for the one cycle it is high the bridge has
                // not yet seen it and rsp_valid is still asserted - which looks
                // exactly like a fresh request.  Without this guard every reply
                // is emitted twice, and the host reads the duplicate as the
                // answer to whatever it asks next.  note_take, the same.
                if (want && !src_push && !tx_full && !rsp_take && !note_take)
                    inj <= want_rsp ? 3'd1 : (want_note ? 3'd4 : 3'd5);
            end
        end
    end

endmodule
