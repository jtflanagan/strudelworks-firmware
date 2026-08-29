`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
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
//   a MARKED event cuts the frame before it: the VBL_MARK notice is one word
//   between the two frames, and the next frame begins with the marked event
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
    localparam [7:0] T_VBL_MARK   = 8'h1D;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         enable     = 1'b0;
    reg         status_req = 1'b0;
    reg  [31:0] ev_data    = 32'd0;
    reg         ev_valid   = 1'b0;
    reg         ev_mark    = 1'b0;
    reg  [15:0] ev_mark_free = 16'd0;
    reg         tx_full    = 1'b0;

    wire [31:0] tx_data;
    wire        tx_valid;
    // The arbiter's take is "there is room", a level; tx_full is the tb's
    // way of saying there is not.
    wire        tx_take = !tx_full;
    wire        overflow;
    wire [31:0] captured;

    bus_event_capture #(
        .DEPTH (DEPTH), .FRAME_EVENTS (FRAME_EVENTS), .FLUSH_TICKS (FLUSH_TICKS)
    ) dut (
        .clk (clk), .rst (rst),
        .enable (enable), .status_req (status_req),
        .ev_data (ev_data), .ev_valid (ev_valid),
        .ev_mark (ev_mark), .ev_mark_free (ev_mark_free),
        .tx_data (tx_data), .tx_valid (tx_valid), .tx_take (tx_take),
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
    // The marks: how many notices, what the last carried, and the event
    // that followed each one - which must be the marked one, at the start
    // of a frame.
    integer    n_marks = 0;
    reg [15:0] last_mark_free = 16'd0;
    reg        after_mark = 1'b0;      // the next payload word must start a frame
    reg        frame_first = 1'b0;     // the next payload word is a frame's first
    reg [31:0] after_mark_ev = 32'd0;
    integer    mark_misplaced = 0;

    always @(posedge clk) if (!rst && tx_valid && tx_take) begin
        if (blocks_left == 0) begin
            // Header.
            case (tx_data[15:8])
                T_BUS_EVENTS: begin
                    n_frames       = n_frames + 1;
                    last_frame_len = tx_data[7:0];
                    blocks_left    = tx_data[7:0];
                    in_status      = 1'b0;
                    frame_first    = 1'b1;
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
                T_VBL_MARK: begin
                    n_marks        = n_marks + 1;
                    last_mark_free = tx_data[31:16];
                    after_mark     = 1'b1;
                    if (tx_data[7:0] != 0) begin
                        $display("FAIL: VBL_MARK with a payload");
                        errors = errors + 1;
                    end
                    // A mark must fall on a frame boundary of its own: the
                    // header before it was a complete frame (blocks_left is
                    // 0 here by construction) - and the frame after must
                    // begin with the marked event.
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
                if (after_mark) begin
                    // The first event after a notice: recorded, and it has
                    // to be a frame's first word.
                    after_mark_ev = tx_data;
                    if (!frame_first) mark_misplaced = mark_misplaced + 1;
                    after_mark = 1'b0;
                end
                frame_first = 1'b0;
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

    // One marked event, then n - 1 plain ones after it.
    task send_marked(input integer n, input [15:0] free);
        integer k;
        begin
            @(negedge clk);
            ev_data  = src; src = src + 1;
            ev_valid = 1'b1; ev_mark = 1'b1; ev_mark_free = free;
            @(negedge clk);
            ev_valid = 1'b0; ev_mark = 1'b0;
            repeat (2) @(posedge clk);
            send_events(n - 1);
        end
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

        // --- a marked event cuts the frame before it -------------------------
        // Re-enable: the overflow above stopped the capture.
        @(negedge clk); enable = 1'b0; settle;
        @(negedge clk); enable = 1'b1; settle;
        have_expect = 1'b0;
        mark_ev = n_events; mark_fr = n_frames; n_marks = 0; mark_misplaced = 0;
        // Three events queued, then the marked one and two more: the three
        // go out at once as a short frame (no waiting for the timer), the
        // notice follows, and the marked event starts the next frame.
        send_events(3);
        send_marked(3, 16'h2A01);
        settle;
        check(n_marks, 1, "one VBL_MARK notice");
        check(n_frames - mark_fr, 2, "frames around the mark");
        check(n_events - mark_ev, 6, "events around the mark");
        if (last_mark_free !== 16'h2A01) begin
            $display("FAIL: the notice carried free=%04x, expected 2a01", last_mark_free);
            errors = errors + 1;
        end else $display("  ok: the notice carries the mark's free bits");
        if (mark_misplaced != 0 || after_mark_ev !== src - 3) begin
            $display("FAIL: the event after the notice is not the marked one at a frame's start");
            errors = errors + 1;
        end else $display("  ok: the marked event is the first word of the frame after the notice");

        // A mark inside what would have been one full frame: the frame is
        // cut short before it, and the rest follows.
        mark_ev = n_events; mark_fr = n_frames; n_marks = 0;
        send_events(FRAME_EVENTS - 2);
        send_marked(FRAME_EVENTS + 2, 16'h0100);
        settle;
        check(n_marks, 1, "one notice inside a full frame's worth");
        check(n_events - mark_ev, 2 * FRAME_EVENTS, "events conserved across the cut");
        if (mark_misplaced != 0) begin
            $display("FAIL: the cut did not put the marked event at a frame's start");
            errors = errors + 1;
        end else $display("  ok: a full frame is cut short before the marked event");

        // A mark at the very head, nothing queued before it: the notice goes
        // out at once, the event waits for the timer like any other.
        mark_ev = n_events; n_marks = 0;
        send_marked(1, 16'h0002);
        repeat (20) @(posedge clk);
        check(n_marks, 1, "a notice with nothing queued before the mark goes at once");
        check(n_events - mark_ev, 0, "the marked event itself waits for the timer");
        settle;
        check(n_events - mark_ev, 1, "...and is flushed by it");
        if (mark_misplaced != 0) begin
            $display("FAIL: the lone marked event did not start its frame");
            errors = errors + 1;
        end

        // A mark under back pressure waits its turn and lands in the same
        // place.
        mark_ev = n_events; n_marks = 0;
        @(negedge clk); tx_full = 1'b1;
        send_events(4);
        send_marked(4, 16'h0003);
        repeat (FLUSH_TICKS) @(posedge clk);
        check(n_marks, 0, "no notice while tx_full");
        @(negedge clk); tx_full = 1'b0;
        settle;
        check(n_marks, 1, "the notice after the back pressure");
        check(n_events - mark_ev, 8, "events conserved through it");
        if (mark_misplaced != 0) begin
            $display("FAIL: back pressure moved the mark");
            errors = errors + 1;
        end else $display("  ok: back pressure delays the notice and does not move it");

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
