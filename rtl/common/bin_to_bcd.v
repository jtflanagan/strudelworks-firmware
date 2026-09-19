`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// bin_to_bcd - 32-bit binary to 8 packed BCD digits, by double dabble.
//
// Shift-and-add-3 only: no divider, no DSP.  Takes 32 clocks, which is nothing
// against a UART frame at 115200 baud (about 8700 clocks per byte at 100 MHz).
//
// Result is 8 nibbles, digit 0 in bcd[3:0] (least significant).  Values above
// 99,999,999 wrap; nothing here reports numbers that large.
//////////////////////////////////////////////////////////////////////////////////

module bin_to_bcd (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [31:0] bin,
    output reg  [31:0] bcd,      // 8 BCD digits
    output reg         busy,
    output reg         done      // one-cycle pulse
);

    reg [31:0] shift_in;
    reg [5:0]  count;
    reg [31:0] bcd_corrected;   // add3_all(bcd), held in a temp rather than
                                // called inline: a function call inside a
                                // shifted concatenation trips Verilator's
                                // SIDEEFFECT check, and the temp reads better.

    // The add-3 correction, applied to every digit before each shift.
    function [31:0] add3_all(input [31:0] v);
        integer i;
        begin
            add3_all = v;
            for (i = 0; i < 8; i = i + 1)
                if (add3_all[i*4 +: 4] >= 4'd5)
                    add3_all[i*4 +: 4] = add3_all[i*4 +: 4] + 4'd3;
        end
    endfunction

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy     <= 1'b0;
            bcd      <= 32'd0;
            shift_in <= 32'd0;
            count    <= 6'd0;
        end else if (!busy) begin
            if (start) begin
                busy     <= 1'b1;
                shift_in <= bin;
                bcd      <= 32'd0;
                count    <= 6'd0;
            end
        end else begin
            // Correct, then shift the next MSB of the binary value in.
            /* verilator lint_off BLKSEQ */
            // Blocking on purpose: a temp consumed later in this same cycle.
            bcd_corrected    = add3_all(bcd);
            /* verilator lint_on BLKSEQ */
            {bcd, shift_in} <= {bcd_corrected, shift_in} << 1;
            count           <= count + 1'b1;
            if (count == 6'd31) begin
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end

endmodule
