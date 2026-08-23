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

    // TO the TX FIFO
    output logic [31:0] tx_data,
    output logic        tx_push,
    input  wire         tx_full
);

    // 0 = forwarding, 1..3 = emitting word N of the reply.
    logic [1:0] inj = 2'd0;
    wire injecting = (inj != 2'd0);

    // Payload blocks still owed by the header last forwarded.  Zero means the
    // next word out of the source is a header, which is the only safe moment.
    logic [7:0] blocks_left = 8'd0;
    wire at_boundary = (blocks_left == 8'd0);

    wire want = rsp_valid && at_boundary && !injecting;

    // Hold capture off while a reply is pending or in flight.  It already
    // handles a full FIFO, so this needs no new behaviour from it.
    assign src_full = tx_full || injecting || want;

    always_comb begin
        if (injecting) begin
            tx_push = !tx_full;
            case (inj)
                2'd1:    tx_data = {16'd0, T_REG_VALUE, 8'd2};  // free, type, len
                2'd2:    tx_data = rsp_addr;
                default: tx_data = rsp_data;
            endcase
        end else begin
            tx_push = src_push && !tx_full;
            tx_data = src_data;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            inj         <= 2'd0;
            blocks_left <= 8'd0;
            rsp_take    <= 1'b0;
        end else begin
            rsp_take <= 1'b0;

            if (injecting) begin
                if (!tx_full) begin
                    if (inj == 2'd3) begin
                        inj      <= 2'd0;
                        rsp_take <= 1'b1;
                    end else begin
                        inj <= inj + 2'd1;
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
                // answer to whatever it asks next.
                if (want && !src_push && !tx_full && !rsp_take) inj <= 2'd1;
            end
        end
    end

endmodule
