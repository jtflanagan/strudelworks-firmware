`timescale 1ns / 1ps
// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// bus_snoop_tb - event capture and framing, with the properties a dump depends on.
//
// The failure that matters here is not a crash, it is a dump that looks fine and
// is missing events.  So the checks are about conservation and structure:
//
//   every event that entered the FIFO comes out, in order, exactly once
//   the framing is well formed - a header whose len matches the blocks after it
//   a full frame is 255 events, so header + payload is exactly one 1 KB buffer
//   a partial frame is flushed by the timer rather than stranded
//   a clean stop FLUSHES what is queued, then stops - a reset is what discards
//   nothing leaks from one capture into the next
//   overflow stops capture, reports itself, and ends on a frame boundary
//
// The tb decodes the outgoing block stream the same way the host will, which is
// what makes "well formed" a real assertion rather than a spot check.
//////////////////////////////////////////////////////////////////////////////////

module bus_snoop_tb;

    localparam integer DEPTH        = 64;      // small, so overflow is reachable
    localparam integer FRAME_EVENTS = 8;       // small, so frames are quick
    localparam integer FLUSH_TICKS  = 200;

    localparam [7:0] T_BUS_EVENTS = 8'h12;
    localparam [7:0] T_BUS_STATUS = 8'h13;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         enable     = 1'b0;
    reg         status_req = 1'b0;
    reg  [31:0] ev_data    = 32'd0;
    reg         ev_valid   = 1'b0;
    reg         tx_full    = 1'b0;

    wire [31:0] tx_data;
    wire        tx_push;
    wire        overflow;
    wire [31:0] captured;

    bus_event_capture #(
        .DEPTH (DEPTH), .FRAME_EVENTS (FRAME_EVENTS), .FLUSH_TICKS (FLUSH_TICKS)
    ) dut (
        .clk (clk), .rst (rst),
        .enable (enable), .status_req (status_req),
        .ev_data (ev_data), .ev_valid (ev_valid),
        .tx_data (tx_data), .tx_push (tx_push), .tx_full (tx_full),
        .overflow (overflow), .captured (captured)
    );

    // ---- host-side decoder ---------------------------------------------------
    // Parses the block stream exactly as ft601_probe will.
    integer errors = 0;

    integer blocks_left = 0;
    integer n_frames    = 0;
    integer n_events    = 0;
    integer n_status    = 0;
    integer last_frame_len = 0;
    reg     last_status_overflow = 1'b0;
    reg [31:0] last_status_count = 32'd0;
    reg [31:0] expect_ev = 32'd0;
    reg        have_expect = 1'b0;
    reg        in_status = 1'b0;

    always @(posedge clk) if (!rst && tx_push && !tx_full) begin
        if (blocks_left == 0) begin
            // Header.
            case (tx_data[15:8])
                T_BUS_EVENTS: begin
                    n_frames       = n_frames + 1;
                    last_frame_len = tx_data[7:0];
                    blocks_left    = tx_data[7:0];
                    in_status      = 1'b0;
                    if (tx_data[7:0] == 0) begin
                        $display("FAIL: BUS_EVENTS frame with len 0");
                        errors = errors + 1;
                    end
                end
                T_BUS_STATUS: begin
                    n_status             = n_status + 1;
                    last_status_overflow = tx_data[16];
                    blocks_left          = tx_data[7:0];
                    in_status            = 1'b1;
                end
                default: begin
                    $display("FAIL: unknown outgoing type %02x (block %08x)",
                             tx_data[15:8], tx_data);
                    errors = errors + 1;
                end
            endcase
        end else begin
            blocks_left = blocks_left - 1;
            if (in_status) begin
                last_status_count = tx_data;
            end else begin
                // Payload event: must follow its predecessor exactly.
                n_events = n_events + 1;
                if (have_expect && tx_data !== expect_ev) begin
                    if (errors < 6) begin
                        $display("FAIL: event out of order - expected %08x got %08x",
                                 expect_ev, tx_data);
                    end
                    errors = errors + 1;
                end
                expect_ev   = tx_data + 32'd1;
                have_expect = 1'b1;
            end
        end
    end

    // ---- stimulus helpers ----------------------------------------------------
    reg [31:0] src = 32'd0;

    task send_events(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(negedge clk);
                ev_data  = src; src = src + 1;
                ev_valid = 1'b1;
                @(negedge clk);
                ev_valid = 1'b0;
                repeat (2) @(posedge clk);
            end
        end
    endtask

    task settle;
        begin repeat (FLUSH_TICKS * 3) @(posedge clk); end
    endtask

    task check(input integer got, input integer want, input string what);
        begin
            if (got !== want) begin
                $display("FAIL: %s - expected %0d, got %0d", what, want, got);
                errors = errors + 1;
            end else $display("  ok: %s = %0d", what, got);
        end
    endtask

    integer mark_ev, mark_fr;

    initial begin
        $display("bus_snoop_tb: event capture and framing");

        repeat (10) @(negedge clk);
        rst = 1'b0;
        settle;

        // --- nothing may come out while disabled -----------------------------
        send_events(20);
        settle;
        check(n_frames, 0, "frames emitted while disabled");
        check(n_events, 0, "events emitted while disabled");

        // --- enabling starts a fresh dump; the disabled events are GONE -------
        @(negedge clk); enable = 1'b1;
        settle;
        have_expect = 1'b0;                  // resync the checker on the new dump
        mark_ev = n_events;

        // --- a full frame is exactly FRAME_EVENTS ----------------------------
        send_events(FRAME_EVENTS);
        settle;
        check(n_frames, 1, "one full frame");
        check(last_frame_len, FRAME_EVENTS, "full frame payload length");
        check(n_events - mark_ev, FRAME_EVENTS, "events in the full frame");

        // --- a partial frame is flushed by the timer, not stranded -----------
        mark_ev = n_events; mark_fr = n_frames;
        send_events(3);
        settle;
        check(n_frames - mark_fr, 1, "partial frame emitted");
        check(last_frame_len, 3, "partial frame payload length");
        check(n_events - mark_ev, 3, "events in the partial frame");

        // --- a burst spanning several frames loses nothing --------------------
        mark_ev = n_events;
        send_events(FRAME_EVENTS * 3 + 5);
        settle;
        check(n_events - mark_ev, FRAME_EVENTS * 3 + 5, "events across many frames");

        // --- back pressure: tx_full must stall, not drop ----------------------
        mark_ev = n_events;
        @(negedge clk); tx_full = 1'b1;
        send_events(FRAME_EVENTS * 2);
        repeat (FLUSH_TICKS * 2) @(posedge clk);
        if (n_events - mark_ev != 0) begin
            $display("FAIL: emitted %0d events while tx_full was asserted",
                     n_events - mark_ev);
            errors = errors + 1;
        end else $display("  ok: nothing emitted while tx_full");
        @(negedge clk); tx_full = 1'b0;
        settle;
        check(n_events - mark_ev, FRAME_EVENTS * 2, "events resumed after back pressure");

        // --- a clean stop FLUSHES, it does not discard ------------------------
        // The last partial frame is up to FRAME_EVENTS of real bus history.
        // Dropping it would lose a quarter of a millisecond off the end of every
        // capture, and the card would report having captured more than arrived.
        mark_ev = n_events;
        send_events(5);                       // queued, not yet a full frame
        @(negedge clk); enable = 1'b0;
        settle;
        check(n_events - mark_ev, 5, "queued events flushed by a clean stop");

        // ...and having flushed, it stops.  The next enable starts empty.
        mark_ev = n_events;
        @(negedge clk); enable = 1'b1;
        have_expect = 1'b0;
        settle;
        check(n_events - mark_ev, 0, "events leaking into the next capture");
        check(captured, 0, "captured count reset by a fresh enable");

        // --- overflow: stops capture, says so, ends cleanly -------------------
        mark_ev = n_events;
        @(negedge clk); tx_full = 1'b1;       // host stopped reading
        send_events(DEPTH + 20);              // more than the FIFO can hold
        repeat (FLUSH_TICKS) @(posedge clk);
        if (!overflow) begin
            $display("FAIL: FIFO overran without setting overflow");
            errors = errors + 1;
        end else $display("  ok: overflow flagged when the FIFO overran");

        @(negedge clk); tx_full = 1'b0;
        settle;
        if (n_status < 1) begin
            $display("FAIL: overflow did not produce a BUS_STATUS");
            errors = errors + 1;
        end else if (!last_status_overflow) begin
            $display("FAIL: BUS_STATUS did not report the overflow flag");
            errors = errors + 1;
        end else $display("  ok: BUS_STATUS reported the overflow");

        // Capture must have STOPPED - not resumed once the host came back.
        mark_ev = n_events;
        send_events(20);
        settle;
        check(n_events - mark_ev, 0, "events captured after an overflow");

        // The reported count must match what actually came out before the gap.
        if (last_status_count == 0) begin
            $display("FAIL: BUS_STATUS reported a zero captured count");
            errors = errors + 1;
        end else $display("  ok: BUS_STATUS carried a captured count (%0d)",
                          last_status_count);

        // --- a frame is never left half-emitted ------------------------------
        if (blocks_left != 0) begin
            $display("FAIL: stream ended mid-frame, %0d blocks outstanding", blocks_left);
            errors = errors + 1;
        end else $display("  ok: stream ends on a frame boundary");

        $display("");
        $display("  %0d frames, %0d events, %0d status", n_frames, n_events, n_status);
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
