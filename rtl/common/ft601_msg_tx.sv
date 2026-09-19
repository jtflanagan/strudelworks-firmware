`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
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
    // Unconditional heartbeat after this many cycles WITHOUT A DISPATCH.  100 us
    // at 100 MHz.  Costs ~40 KB/s on a dead link and buys three things: a
    // backstop if any dispatch-detection assumption below is wrong, a liveness
    // signal the host can watch, and - the practical one - a bound on
    // speculative-read latency.
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

    // Heartbeat period select, from BUS_ENABLE free[7:4] via the host.  The
    // period is IDLE_TICKS >> idle_shift, so ZERO IS THE BUILT-IN DEFAULT and
    // each step halves it.  Synchronous to clk; the crossing is done outside.
    input  wire  [3:0] idle_shift,

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
    // What this measures is "the HOST has had nothing for IDLE_TICKS", not "our
    // FIFO is empty".  The two coincide on a quiet link and diverge on a busy
    // one, which is precisely when the backstop is needed: it exists to cover a
    // dispatch this module failed to detect, and a missed dispatch happens while
    // data is flowing.  Resetting on our own FIFO occupancy held the timer down
    // with the very traffic that caused the miss, so the 100 us bound became
    // however long it took the chip's buffer to fill by other means -
    // milliseconds, measured on hardware.  Nothing is ever lost that way; it is
    // queued behind a read that will not terminate, which looks identical to a
    // host-side hiccup and is why this hid behind every host-side experiment.
    //
    // The host receives when the chip DISPATCHES, and the chip dispatches for
    // exactly two reasons: its buffer fills, or TX goes idle.  So those two are
    // the only events allowed to restart the timer.  Both are already tracked -
    // the fill is the wrap of buf_blocks, the idle dispatch is dispatch_now.
    //
    // Note the asymmetry with buf_blocks, which is deliberately conservative
    // about calling a dispatch.  Here the mis-tracking direction that hurts is
    // reversed: a delivery we imagine merely delays the backstop by one window,
    // and a delivery we miss costs one unneeded 4-byte heartbeat.  Both are far
    // cheaper than the stall, so this side gets the cheap, optimistic test.
    localparam integer IDLE_W = $clog2(IDLE_TICKS + 1);
    logic [IDLE_W-1:0] idle_cnt = '0;

    // The chip's buffer fills on the 256th block into it, which is the block
    // that wraps the counter.
    wire buf_wrap  = fwd && (buf_blocks == 8'hff);
    wire delivered = dispatch_now || buf_wrap;

    // Free-running tick rather than a one-shot: expiry restarts the count, so a
    // link that stays undelivered is poked once per window instead of once ever.
    // A one-shot would be re-armed only by a delivery - the thing whose absence
    // it is there to report.
    // The heartbeat is the link's latency floor - the host cannot learn about
    // data sooner than the dispatch that terminates its read - so this is worth
    // being able to move without a rebuild.  Floored, because a shift large
    // enough to reach zero would fire every cycle and bury the link in 4-byte
    // frames, each of which also consumes one of the host's posted transfers.
    localparam integer MIN_IDLE_TICKS = 100;   // 1 us at 100 MHz
    wire [IDLE_W-1:0] idle_shifted = IDLE_TICKS[IDLE_W-1:0] >> idle_shift;
    wire [IDLE_W-1:0] idle_limit =
        (idle_shifted < MIN_IDLE_TICKS[IDLE_W-1:0]) ? MIN_IDLE_TICKS[IDLE_W-1:0]
                                                    : idle_shifted;
    // >= and not ==: idle_limit can DROP while idle_cnt is already past it, and
    // an equality test would miss and let the counter run all the way around
    // before firing.  That is not hypothetical - the host sets this at
    // BUS_ENABLE, which can arrive with the counter anywhere.
    wire idle_fire = (idle_cnt >= idle_limit);

    always_ff @(posedge clk) begin
        if (rst || delivered || idle_fire) idle_cnt <= '0;
        else                               idle_cnt <= idle_cnt + 1'b1;
    end

    // ---- push path ----------------------------------------------------------
    // A heartbeat needs only a message boundary: blocks_left == 0 means the next
    // block pushed is a header, and a heartbeat IS a header, so inserting one
    // there is well formed.  It deliberately does NOT wait for fifo_empty.  That
    // was the same mistake as the old idle-timer gate - deferring the fix until
    // the link is quiet, when the debt that matters is the one raised while it
    // is busy - and it could silently drop the debt: with both push terms live,
    // real data won the din mux while push_hb still cleared hb_pending, so the
    // heartbeat was accounted for and never sent.
    //
    // So the two are now made exclusive explicitly, and the heartbeat wins.  It
    // costs real data a single cycle, at most once per idle window.
    wire send_hb   = hb_pending && (blocks_left == 8'd0);
    wire push_data = din_req_data && !fifo_empty && !send_hb;
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
            //
            // A timer debt can be swallowed by that same clear, since nothing
            // here distinguishes the two.  That is left alone rather than given
            // its own bit: the block that discharged it did the heartbeat's job,
            // and if it turns out not to have, the timer free-runs and raises
            // the debt again one window later.  The bound becomes 2*IDLE_TICKS
            // in that corner, not unbounded, which is the property that matters.
            if (push_hb)                                          hb_pending <= 1'b0;
            else if (fwd && (buf_blocks == 8'd0))                 hb_pending <= 1'b0;
            else if (dispatch_now && (buf_blocks == 8'd0) && sent) hb_pending <= 1'b1;
            else if (idle_fire)                                   hb_pending <= 1'b1;
        end
    end

endmodule
