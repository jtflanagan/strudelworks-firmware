`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// start_hold_tb - rtl/start_hold.sv against a modelled RES' line.
//
// The line is a wired-OR of three pull-downs - the hold's drive, the host's
// RESET pulse, a finger on Ctrl-Reset - read back through a 3-clock
// synchroniser, and it RISES SLOWLY: after the last pull-down lets go it
// reads low for RISE clocks and bounces once on the way up, which is what an
// RC through a synchroniser can do.  The checks:
//   1. the card's reset holds, drives the line, cause card, count 1, and the
//      line falling under its own drive is not a second hold;
//   2. a release stops the drive; the slow rise and its bounce are masked;
//   3. the host's RESET pulse holds once (cause RES'), and a release while the
//      pulse still drives does not re-hold when it ends;
//   4. a finger on Ctrl-Reset holds once; a release with the finger still
//      down lets the machine start when it lifts, with no second hold;
//   5. a one-clock glitch never counts;
//   6. an assertion after the mask counts again;
//   7. a build that cannot drive never holds.
//////////////////////////////////////////////////////////////////////////////////
module start_hold_tb;
    localparam integer DEB  = 16;
    localparam integer MASK = 10;     // 2^10 clocks
    localparam integer RISE = 400;    // < 2^10: inside the mask

    reg clk = 1'b0;
    always #5 clk = ~clk;

    integer errors = 0;
    task check(input bit ok, input [1023:0] what);
        begin
            if (!ok) begin
                $display("FAIL: %0s", what);
                errors = errors + 1;
            end else begin
                $display("  ok: %0s", what);
            end
        end
    endtask

    // ---- the DUT, and a second one that cannot drive -----------------------
    reg  rst = 1'b1, rel = 1'b0, pulse = 1'b0, finger = 1'b0, glitch = 1'b0;
    wire pending, cause_card, cause_res, drive;
    wire [7:0] count;
    wire res_sync;
    start_hold #(.CAN_MASTER (1'b1), .DEBOUNCE (DEB), .MASK_LOG2 (MASK)) dut (
        .clk (clk), .rst (rst), .apple_res_sync (res_sync), .release_w1 (rel),
        .pending (pending), .cause_card (cause_card), .cause_res (cause_res),
        .count (count), .hold_drive (drive)
    );
    wire snoop_pending, snoop_drive;
    start_hold #(.CAN_MASTER (1'b0), .DEBOUNCE (DEB), .MASK_LOG2 (MASK)) snoop (
        .clk (clk), .rst (rst), .apple_res_sync (res_sync), .release_w1 (1'b0),
        .pending (snoop_pending), .cause_card (), .cause_res (), .count (),
        .hold_drive (snoop_drive)
    );

    // ---- the line: wired-OR pull-downs, a slow bouncy rise, a synchroniser --
    wire pulled = drive || pulse || finger;
    integer rise_left = 0;
    reg line = 1'b1;
    always @(posedge clk) begin
        if (pulled) begin
            line      <= 1'b0;
            rise_left <= RISE;
        end else if (rise_left != 0) begin
            rise_left <= rise_left - 1;
            // One bounce on the way up: high for 40 clocks, low again, then high.
            line <= (rise_left < RISE / 2 && rise_left > RISE / 2 - 40) ? 1'b1 : (rise_left == 1);
        end else begin
            line <= 1'b1;
        end
    end
    reg [2:0] sync = 3'b111;
    always @(posedge clk) sync <= {sync[1:0], line && !glitch};
    assign res_sync = sync[2];

    task wait_clocks(input integer n);
        repeat (n) @(posedge clk);
    endtask

    initial begin
        $display("start_hold_tb: DEBOUNCE %0d, MASK 2^%0d, RISE %0d", DEB, MASK, RISE);
        wait_clocks(4);
        rst <= 1'b0;

        // 1. the card's reset
        wait_clocks(200);
        check(pending && cause_card && !cause_res && count == 8'd1, "a card reset holds: pending, cause card, count 1");
        check(drive && !res_sync, "...driving RES' low, and the line reads low");
        check(count == 8'd1, "...and the line falling under its own drive is not a second hold");

        // 2. release: the drive stops, the slow rise and its bounce are masked
        @(negedge clk) rel = 1'b1; @(negedge clk) rel = 1'b0;
        check(!pending && !drive && !cause_card, "release: not pending, not driving, causes cleared");
        wait_clocks(RISE + 50);
        check(res_sync && !pending && count == 8'd1, "the slow rise and its bounce inside the mask do not re-hold");
        wait_clocks(1 << MASK);

        // 3. the host's RESET pulse
        @(negedge clk) pulse = 1'b1;
        wait_clocks(DEB + 10);
        check(pending && cause_res && !cause_card && count == 8'd2, "the host's RESET pulse holds once: cause RES', count 2");
        @(negedge clk) rel = 1'b1; @(negedge clk) rel = 1'b0;
        check(!pending, "a release while the pulse still drives clears pending");
        wait_clocks(200);
        @(negedge clk) pulse = 1'b0;
        wait_clocks(RISE + 50 + (1 << MASK));
        check(!pending && count == 8'd2, "...and the pulse ending does not re-hold");

        // 4. a finger on Ctrl-Reset, released early
        @(negedge clk) finger = 1'b1;
        wait_clocks(DEB + 10);
        check(pending && cause_res && count == 8'd3, "Ctrl-Reset holds once: count 3");
        wait_clocks(500);
        check(count == 8'd3, "...once for as long as the key is down");
        @(negedge clk) rel = 1'b1; @(negedge clk) rel = 1'b0;
        wait_clocks(300);
        check(!pending && !drive && !res_sync, "a release with the finger down: not driving, the line still low");
        @(negedge clk) finger = 1'b0;
        wait_clocks(RISE + 50 + (1 << MASK));
        check(!pending && res_sync && count == 8'd3, "...the finger lifts, the machine starts, no second hold");

        // 5. a one-clock glitch (and a short one under DEBOUNCE)
        @(negedge clk) glitch = 1'b1; @(negedge clk) glitch = 1'b0;
        wait_clocks(40);
        @(negedge clk) glitch = 1'b1; repeat (DEB - 6) @(negedge clk); glitch = 1'b0;
        wait_clocks(40);
        check(!pending && count == 8'd3, "glitches shorter than the debounce never count");

        // 6. after the mask, an assertion counts again
        @(negedge clk) finger = 1'b1;
        wait_clocks(DEB + 10);
        @(negedge clk) finger = 1'b0;
        check(pending && count == 8'd4, "an assertion after the mask holds again: count 4");

        // 7. a build that cannot drive
        check(!snoop_pending && !snoop_drive, "CAN_MASTER = 0 never holds and never drives");

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d error(s)", errors);
        $finish;
    end
endmodule
