`timescale 1ns / 1ps
// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// ft601_msg_tx - the transmit half of the FT601 message protocol.
//
// Sits between the async TX FIFO and the FT601 controller, passes message blocks
// through untouched, and inserts a heartbeat frame when - and only when - leaving
// the link idle would hang the host's read.  docs/PROTOCOL.md is the spec; this
// is the implementation of its transmit rule.
//
// THE ERRATA, in one paragraph.  The FT601 buffers internally in 1 KB units and
// dispatches a buffer when it FILLS or when TX goes idle.  Stop sending with a
// partial buffer and it dispatches a short packet, which terminates the host's
// read.  Stop sending with an EMPTY buffer - which is what happens after sending
// an exact multiple of 256 blocks - and there is nothing to dispatch, no short
// packet, and a host reading for more than it got waits until it times out.  One
// extra block moves the chip off that boundary and the read completes.
//
// So the tracked quantity is the fill level of the CHIP's current buffer, not the
// length of our own bursts.  Bursts end for reasons that have nothing to do with
// whether the chip dispatched - TXE# backpressure is "chip busy", not "TX idle" -
// and a counter reset on those would stop describing the chip at all.  The counter
// is 8 bits and wraps at 256 all by itself, which is exactly where the chip
// dispatches on fill, so a fill needs no special case.
//////////////////////////////////////////////////////////////////////////////////

module ft601_msg_tx #(
    // Unconditional heartbeat after this many idle cycles.  100 us at 100 MHz.
    // Costs ~40 KB/s on a dead link and buys three things: a backstop if any
    // dispatch-detection assumption below is wrong, a liveness signal the host
    // can watch, and - the practical one - a bound on speculative-read latency.
    // A heartbeat leaves a one-block buffer that dispatches as a 4-byte short
    // packet, so an oversized host read completes in microseconds instead of
    // waiting out its libusb timeout.
    parameter integer IDLE_TICKS = 10_000
) (
    input  wire        clk,             // ft_clk
    input  wire        rst,

    // FROM the async TX FIFO (FWFT, zero read latency)
    input  wire [31:0] fifo_dout,
    input  wire        fifo_empty,
    output wire        fifo_rd_en,

    // TO/FROM the FT601 controller
    output wire [31:0] din,
    output wire        din_wr_en,
    input  wire        din_req_data,
    input  wire        fwd,
    input  wire        q_empty,
    input  wire        in_rx,

    // status
    output wire        hb_sent          // one pulse per heartbeat forwarded
);

    // ---- message boundary, tracked on the PUSH side -------------------------
    // Snoop the length out of each header as it goes by and count down.  Zero
    // means the next block pushed is a header, which is the only point at which
    // a heartbeat may be inserted - injecting mid-message would corrupt the
    // frame.  A heartbeat is itself a header with len 0, so it leaves this at 0.
    logic [7:0] blocks_left = 8'd0;

    // ---- the chip's current buffer ------------------------------------------
    logic [7:0] buf_blocks = 8'd0;   // wraps at 256 = one 1 KB buffer
    logic       sent       = 1'b0;   // anything forwarded since the last dispatch

    // ---- heartbeat request --------------------------------------------------
    logic       hb_pending = 1'b0;

    // A dispatch is the chip flushing its buffer, which it does when TX goes
    // idle.  "TX idle" means we stopped writing while the chip was willing to
    // take more - the skid buffer drained AND the FIFO behind it is dry - or the
    // bus turned around for RX.  It deliberately does NOT include TXE#
    // backpressure: during a stall the skid buffer still holds data, so q_empty
    // is false and this stays low, which is the whole point.
    //
    // Over-detecting is the safe direction.  A dispatch we imagine resets the
    // count early and at worst costs one unnecessary 4-byte heartbeat; a
    // dispatch we miss leaves the count describing a buffer the chip no longer
    // has, and the read stalls until the idle timer fires.  in_rx is included on
    // those grounds - the chip has almost certainly dispatched by the time the
    // bus comes back.
    wire dispatch = (q_empty && fifo_empty) || in_rx;

    logic dispatch_d = 1'b0;
    wire  dispatch_now = dispatch && !dispatch_d;

    // ---- idle timer ---------------------------------------------------------
    localparam integer IDLE_W = $clog2(IDLE_TICKS + 1);
    logic [IDLE_W-1:0] idle_cnt = '0;
    wire idle_expired = (idle_cnt == IDLE_TICKS[IDLE_W-1:0]);

    always_ff @(posedge clk) begin
        if (rst || fwd || !fifo_empty) idle_cnt <= '0;
        else if (!idle_expired)        idle_cnt <= idle_cnt + 1'b1;
    end

    logic idle_expired_d = 1'b0;
    always_ff @(posedge clk) idle_expired_d <= !rst && idle_expired;
    wire idle_fire = idle_expired && !idle_expired_d;

    // ---- push path ----------------------------------------------------------
    // Real data always wins; a heartbeat only goes out when there is genuinely
    // nothing else to send, so the two are mutually exclusive by construction.
    wire send_hb   = hb_pending && (blocks_left == 8'd0) && fifo_empty;
    wire push_data = din_req_data && !fifo_empty;
    wire push_hb   = din_req_data && send_hb;

    assign fifo_rd_en = push_data;
    assign din        = push_data ? fifo_dout : 32'h00000000;   // heartbeat
    assign din_wr_en  = push_data || push_hb;

    // A heartbeat is only truly "sent" once the chip takes it, not when it is
    // pushed into the skid buffer.
    logic hb_in_flight = 1'b0;
    always_ff @(posedge clk) begin
        if (rst)          hb_in_flight <= 1'b0;
        else if (push_hb) hb_in_flight <= 1'b1;
        else if (fwd)     hb_in_flight <= 1'b0;
    end
    assign hb_sent = fwd && hb_in_flight;

    // ---- state --------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            blocks_left  <= 8'd0;
            buf_blocks   <= 8'd0;
            sent         <= 1'b0;
            hb_pending   <= 1'b0;
            dispatch_d   <= 1'b0;
        end else begin
            dispatch_d <= dispatch;

            // Message boundary follows what we push.
            if (din_wr_en) begin
                if (blocks_left == 8'd0) blocks_left <= din[7:0];
                else                     blocks_left <= blocks_left - 8'd1;
            end

            // Chip buffer fill follows what the chip actually takes.  fwd and
            // dispatch cannot coincide: fwd needs a non-empty skid buffer and
            // the TX_ACTIVE state, dispatch needs an empty one or RX.
            if (dispatch_now) begin
                buf_blocks <= 8'd0;
                sent       <= 1'b0;
            end else if (fwd) begin
                buf_blocks <= buf_blocks + 8'd1;
                sent       <= 1'b1;
            end

            // Owe a heartbeat when the chip is being left with an EMPTY buffer
            // after having been given something - i.e. we stopped on an exact
            // 256-block boundary and nothing will flush.  buf_blocks != 0 is the
            // harmless case: that partial buffer dispatches on its own.
            //
            // The debt is also discharged by real data arriving.  When a stall
            // lands on a boundary MID-MESSAGE the heartbeat cannot be inserted -
            // it would corrupt the frame - so the debt is carried; but if the
            // producer then resumes, its blocks refill the chip's buffer and it
            // will dispatch on its own.  Without this clear, that deferred debt
            // fires a heartbeat nobody needed.
            if (push_hb)                                          hb_pending <= 1'b0;
            else if (fwd && (buf_blocks == 8'd0))                 hb_pending <= 1'b0;
            else if (dispatch_now && (buf_blocks == 8'd0) && sent) hb_pending <= 1'b1;
            else if (idle_fire)                                   hb_pending <= 1'b1;
        end
    end

endmodule
