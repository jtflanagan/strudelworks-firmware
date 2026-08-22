`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// bus_event_capture - buffer Apple bus events and hand them to the message layer
// as whole BUS_EVENTS frames.
//
// Ported in behaviour from AppleTini v5 bus_event_manager.sv: an event FIFO held
// in reset while capture is disabled (so disabling discards, which is what a
// clean stop and a watchdog reset both need), and an overflow path that STOPS
// capturing rather than dropping quietly.
//
// WHY OVERFLOW STOPS EVERYTHING.  The link runs 30-80x faster than the bus, so a
// full FIFO does not mean the bus outran USB - it means the host stopped reading.
// Carrying on would put a hole in the middle of the dump, and a dump with a
// silent hole claims the machine did something it did not.  Stopping makes the
// gap explicit and terminal: the host gets a BUS_STATUS saying so, and its file
// ends at a frame boundary.
//
// STORE AND FORWARD.  A header is only emitted once the events behind it are
// already queued, so the message layer's blocks_left tracking always sees whole
// frames.  That matters because a frame left half-pushed blocks heartbeat
// insertion (docs/PROTOCOL.md case 8), and a half-pushed frame that never
// completes would hold the link on a 1 KB boundary indefinitely.
//////////////////////////////////////////////////////////////////////////////////

module bus_event_capture #(
    parameter integer DEPTH        = 2048,
    // 255 payload blocks + 1 header = 256 blocks = exactly one FT601 buffer.
    parameter integer FRAME_EVENTS = 255,
    // Flush a partial frame after this long with no new event, so a quiet bus
    // does not strand events.  ~1 ms at 100 MHz.
    parameter integer FLUSH_TICKS  = 100_000
) (
    input  wire        clk,
    input  wire        rst,

    // control
    input  wire        enable,          // capture on/off (BUS_ENABLE)
    input  wire        status_req,      // send a BUS_STATUS frame

    // event source
    input  wire [31:0] ev_data,
    input  wire        ev_valid,

    // to the TX async FIFO
    output logic [31:0] tx_data,
    output logic        tx_push,
    input  wire         tx_full,

    // status
    output logic        overflow,
    output logic [31:0] captured
);

    localparam [7:0] T_BUS_EVENTS = 8'h12;
    localparam [7:0] T_BUS_STATUS = 8'h13;

    localparam integer CW = $clog2(DEPTH + 1);

    logic enable_d = 1'b0;
    wire  enable_rise = enable && !enable_d;
    wire  enable_fall = !enable && enable_d;

    // ---- event FIFO ---------------------------------------------------------
    // A clean stop DRAINS, a reset DISCARDS, and the difference is the whole
    // point of having both.  When `enable` falls we stop accepting new events but
    // keep the FIFO alive and flush what is already in it, then report; only then
    // does the FIFO go back into reset.  Without this the last partial frame -
    // up to FRAME_EVENTS, a quarter of a millisecond of bus time - is dropped at
    // the end of every capture.  Measured as the card counting 58 more events
    // than reached the host.
    //
    // A watchdog expiry is a different matter: it drives `rst`, which clears
    // everything immediately, because by then the host is gone and there is
    // nobody to flush to.
    // enable_fall is in the term deliberately: `draining` is a flop, so between
    // enable going low and draining going high there is one cycle where neither
    // is set - and the FIFO would be reset in it, wiping the very events the
    // drain exists to flush.
    logic draining = 1'b0;
    wire  fifo_active = enable || draining || enable_fall;
    wire  fifo_rst    = rst || !fifo_active;

    wire [31:0]    fq_dout;
    wire           fq_full, fq_empty;
    wire [CW-1:0]  fq_count;
    logic          fq_rd_en;

    sync_fifo #(.WIDTH (32), .DEPTH (DEPTH)) fq (
        .clk (clk), .rst (fifo_rst),
        .din (ev_data), .wr_en (ev_valid && enable && !overflow), .full (fq_full),
        .dout (fq_dout), .rd_en (fq_rd_en), .empty (fq_empty),
        .count (fq_count)
    );

    // ---- framer state -------------------------------------------------------
    localparam [2:0] S_IDLE    = 3'd0,
                     S_HDR     = 3'd1,
                     S_PAY     = 3'd2,
                     S_ST_HDR  = 3'd3,
                     S_ST_PAY  = 3'd4;

    logic [2:0] state = S_IDLE;
    logic [7:0] left  = 8'd0;
    logic       status_pending = 1'b0;

    // Counters reset when a capture STARTS, not when it stops.  Clearing them on
    // disable would be the obvious thing and is wrong: the disable acknowledgement
    // is what carries the final count to the host, and it is emitted after the
    // disable - so clearing there reports zero every time.  Measured that way.

    wire status_done = (state == S_ST_PAY) && !tx_full;

    // ---- overflow and counters ----------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            overflow       <= 1'b0;
            captured       <= 32'd0;
            status_pending <= 1'b0;
            enable_d       <= 1'b0;
        end else begin
            enable_d <= enable;

            if (enable_rise) begin
                // A re-enable is a fresh start, not a resumption.
                overflow <= 1'b0;
                captured <= 32'd0;
            end else if (enable && ev_valid && !overflow) begin
                if (fq_full) begin
                    overflow       <= 1'b1;    // this event had nowhere to go
                    status_pending <= 1'b1;
                end else begin
                    captured <= captured + 32'd1;
                end
            end

            if (status_req)  status_pending <= 1'b1;
            if (status_done) status_pending <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (rst)                                              draining <= 1'b0;
        else if (enable_fall)                                 draining <= 1'b1;
        else if (draining && (fq_count == 0) && (state == S_IDLE)) draining <= 1'b0;
    end

    // ---- flush timer --------------------------------------------------------
    localparam integer FW = $clog2(FLUSH_TICKS + 1);
    logic [FW-1:0] flush_cnt = '0;
    wire flush_due = (flush_cnt == FLUSH_TICKS[FW-1:0]);

    always_ff @(posedge clk) begin
        if (rst || !enable || ev_valid || (fq_count == 0)) flush_cnt <= '0;
        else if (!flush_due)                               flush_cnt <= flush_cnt + 1'b1;
    end

    wire have_full_frame = (fq_count >= FRAME_EVENTS[CW-1:0]);
    // While draining there is nothing more coming, so do not wait out the timer.
    wire have_partial    = (fq_count != 0) && (flush_due || draining);

    // Zero-extend before slicing.  fq_count is $clog2(DEPTH+1) bits, which is 12
    // at the default DEPTH but only 7 at the small DEPTH the testbench uses - so
    // fq_count[7:0] is an out-of-range part-select there and yields X in the
    // frame length.  The real parameters hide it; the testbench found it.  This
    // is the same class of bug sim/lint.sh was written for.
    //
    // Safe to truncate to 8 bits: have_partial only wins when the count is below
    // FRAME_EVENTS, which is 255.
    wire [31:0] fq_count_x = {{(32 - CW){1'b0}}, fq_count};

    // ---- outputs ------------------------------------------------------------
    always_comb begin
        tx_data  = 32'd0;
        tx_push  = 1'b0;
        fq_rd_en = 1'b0;

        case (state)
            S_HDR: begin
                tx_data = {16'h0000, T_BUS_EVENTS, left};
                tx_push = !tx_full;
            end
            S_PAY: begin
                tx_data  = fq_dout;
                tx_push  = !tx_full && !fq_empty;
                fq_rd_en = !tx_full && !fq_empty;
            end
            S_ST_HDR: begin
                tx_data = {14'd0, enable, overflow, T_BUS_STATUS, 8'd1};
                tx_push = !tx_full;
            end
            S_ST_PAY: begin
                // The captured count, so the host can check its file is complete
                // rather than merely non-empty.
                tx_data = captured;
                tx_push = !tx_full;
            end
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            left  <= 8'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    // Status first: an overflow has to reach the host, and it
                    // must not be queued behind events it invalidates.
                    // Events before status: the status frame marks the end of
                    // the capture, so anything still queued has to precede it.
                    if (fifo_active && (have_full_frame || have_partial)) begin
                        left  <= have_full_frame ? FRAME_EVENTS[7:0] : fq_count_x[7:0];
                        state <= S_HDR;
                    end else if (status_pending && !draining) begin
                        state <= S_ST_HDR;
                    end
                end

                S_HDR: if (!tx_full) state <= S_PAY;

                S_PAY: if (!tx_full && !fq_empty) begin
                    if (left == 8'd1) state <= S_IDLE;
                    else              left  <= left - 8'd1;
                end

                S_ST_HDR: if (!tx_full) state <= S_ST_PAY;
                S_ST_PAY: if (!tx_full) state <= S_IDLE;
                default:  state <= S_IDLE;
            endcase
        end
    end

endmodule
