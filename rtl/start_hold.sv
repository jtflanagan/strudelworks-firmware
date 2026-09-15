`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// start_hold - every start is a clean start (docs/CLEAN_START.md, rung CS1).
//
// THE RULE (the user's, 2026-09-15): every card reset and every Apple reset
// runs the host's startup checklist from a known place of control, and the
// machine does not run until it is done.  RES' is the one blessed place to
// hold a machine: in reset nothing is running, so nothing can be interrupted.
//
// A FULL HOLD.  While `pending`, the card drives the Apple's RES' line low
// through the same open-drain driver as the host's RESET pulse: the
// motherboard's CPU, the slot cards and the soft core are held together.  The
// board this is for keeps a vestigial path that lets the motherboard CPU run;
// the one it leads to has no CPU at all (a plug in the CPU socket), so no
// exception is made for it.  The host releases the hold with START_RELEASE
// once its checklist is done, and the machine starts on the ordinary rising
// edge of RES'.
//
// WHAT SETS IT:
//   - the card's own reset (`rst`: power-on, a bitstream load, the link's 'R',
//     its watchdog) - cause CARD;
//   - a RES' assertion the hold did not cause - an external Ctrl-Reset or
//     power-on, or the host's RESET pulse (an Apple reset the host asked for
//     runs the checklist too) - cause RES'.
// WHAT DOES NOT:
//   - the hold's own drive.  RES' falls a few clocks after the drive rises
//     (the reader's synchroniser); an assertion that arrives while the hold is
//     already driving is its own.
//   - a glitch: RES' must stay low for DEBOUNCE clocks to count.
//   - the release's own rising edge.  The motherboard's RES' line rises
//     through an RC, and a slow edge through a synchroniser can read as a
//     bounce; assertions are ignored for MASK clocks after a release (~10 ms
//     at 100 MHz by default).
//
// A release while RES' is still held low by someone else (a finger on
// Ctrl-Reset) clears `pending` and stops the drive; the line stays low until
// the finger lifts, and no new assertion is seen - the machine starts then.
//////////////////////////////////////////////////////////////////////////////////
module start_hold #(
    parameter bit     CAN_MASTER = 1'b1,
    parameter integer DEBOUNCE   = 16,
    parameter integer MASK_LOG2  = 20      // 2^20 clocks after a release
) (
    input  wire        clk,
    input  wire        rst,             // the card's reset (the link's)
    input  wire        apple_res_sync,  // RES' as the bus reader sees it, active low
    input  wire        release_w1,      // START_RELEASE: the host's checklist is done
    output logic       pending,
    output logic       cause_card,
    output logic       cause_res,
    output logic [7:0] count,           // holds since the card's reset
    output wire        hold_drive       // drive RES' low
);
    logic [$clog2(DEBOUNCE + 1)-1:0] low_cnt;
    logic                           res_counted;   // this low stretch already counted
    logic [MASK_LOG2:0]             mask_cnt;      // counts down after a release
    wire                            masked = (mask_cnt != '0);

    assign hold_drive = CAN_MASTER && pending;

    always_ff @(posedge clk) begin
        if (rst) begin
            pending     <= CAN_MASTER;
            cause_card  <= CAN_MASTER;
            cause_res   <= 1'b0;
            count       <= CAN_MASTER ? 8'd1 : 8'd0;
            low_cnt     <= '0;
            // The card-reset hold is already driving the line down: its
            // assertion is this hold's own.
            res_counted <= 1'b1;
            mask_cnt    <= '0;
        end else begin
            if (mask_cnt != '0) mask_cnt <= mask_cnt - 1'b1;

            if (apple_res_sync) begin
                low_cnt     <= '0;
                res_counted <= 1'b0;
            end else if (low_cnt != DEBOUNCE[$bits(low_cnt)-1:0]) begin
                low_cnt <= low_cnt + 1'b1;
            end

            // A debounced assertion, counted once per low stretch: a new hold,
            // unless the hold is what is holding the line or a release has
            // just let it go.
            if (!apple_res_sync && low_cnt == DEBOUNCE[$bits(low_cnt)-1:0] - 1 && !res_counted) begin
                res_counted <= 1'b1;
                if (CAN_MASTER && !pending && !masked) begin
                    pending   <= 1'b1;
                    cause_res <= 1'b1;
                    count     <= count + 8'd1;
                end
            end

            if (release_w1 && pending) begin
                pending    <= 1'b0;
                cause_card <= 1'b0;
                cause_res  <= 1'b0;
                mask_cnt   <= {1'b1, {MASK_LOG2{1'b0}}};
                // The stretch the hold was driving is not a new assertion.
                res_counted <= 1'b1;
            end
        end
    end
endmodule
