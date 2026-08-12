`timescale 1ns / 1ps
// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// report_tx - format the latency statistics as text and stream them out a UART.
//
// Prints, once a second:
//
//   -- strudelworks latency  win=00000042  1 cy = 10 ns --
//   SEQ min=010 mean=010.4 max=037 gt18=000071 gt49=000000
//   RND min=012 mean=012.1 max=037 gt18=000069 gt49=000000
//   errors=0
//
// 180 bytes, about 16 ms at 115200 baud, so a 1 Hz report uses under 2 % of the
// link and never backs up.
//
// Fields are fixed-width with leading zeros.  Suppressing them would need a
// per-field "seen a non-zero yet" pass; fixed columns are easier to read down a
// scrolling terminal anyway, and unambiguous.
//
// The report text lives in one packed string constant with single-character
// placeholders marking where numbers go.  Walking a string is far easier to
// check by eye than a hand-written character ROM, and the placeholders are
// asserted unique at build time by the same script that sized this file.
//
// LINE ENDINGS ARE "\015\n", NOT "\r\n".  Verilog string literals do not define
// \r as an escape - "\r" yields the literal character 'r' (114), not CR (13).
// The first version of this file used "\r\n" and printed a stray 'r' with no
// carriage return, so every line overwrote the last on a real terminal.  Use the
// octal escape, which IS standard.  sim/report_tb.sv asserts the numeric byte
// values rather than diffing against another string literal, because the
// original string-vs-string test compared the bug against itself and passed.
//////////////////////////////////////////////////////////////////////////////////

module report_tx #(
    parameter integer CLK_HZ        = 100_000_000,
    parameter integer REPORT_PERIOD = 100_000_000   // 1 s at 100 MHz
) (
    input  wire clk,
    input  wire rst,
    input  wire enable,             // hold low until calibration completes

    // Statistics, latched by this module when a report starts.
    input  wire [31:0] win_count,
    input  wire [15:0] seq_min,
    input  wire [31:0] seq_mean_x10,
    input  wire [15:0] seq_max,
    input  wire [31:0] seq_gt_gs,
    input  wire [31:0] seq_gt_leg,
    input  wire [15:0] rnd_min,
    input  wire [31:0] rnd_mean_x10,
    input  wire [15:0] rnd_max,
    input  wire [31:0] rnd_gt_gs,
    input  wire [31:0] rnd_gt_leg,
    input  wire [31:0] err_count,

    // UART
    output reg  [7:0] tx_data,
    output reg        tx_valid,
    input  wire       tx_ready
);

    localparam integer NFIELD = 12;
    localparam integer LEN    = 137;   // bytes in TEMPLATE, checked when authored
    localparam [7:0]   LEN8   = LEN[7:0];   // sized, so index maths stays 8-bit

    localparam [LEN*8-1:0] TEMPLATE = {
        "\015\n-- strudelworks latency  win=!  1 cy = 10 ns --\015\n",
        "SEQ min=@ mean=# max=$ gt18=% gt49=^\015\n",
        "RND min=& mean=* max=( gt18=) gt49=[\015\n",
        "errors=]\015\n"
    };

    // Placeholder -> field index.  Returns NFIELD when the byte is literal text.
    function [3:0] field_of(input [7:0] ch);
        begin
            case (ch)
                "!": field_of = 4'd0;   "@": field_of = 4'd1;
                "#": field_of = 4'd2;   "$": field_of = 4'd3;
                "%": field_of = 4'd4;   "^": field_of = 4'd5;
                "&": field_of = 4'd6;   "*": field_of = 4'd7;
                "(": field_of = 4'd8;   ")": field_of = 4'd9;
                "[": field_of = 4'd10;  "]": field_of = 4'd11;
                default: field_of = NFIELD[3:0];
            endcase
        end
    endfunction

    function [3:0] digits_of(input [3:0] f);
        begin
            case (f)
                4'd0:    digits_of = 4'd8;   // win
                4'd1:    digits_of = 4'd3;   // seq min
                4'd2:    digits_of = 4'd4;   // seq mean x10
                4'd3:    digits_of = 4'd3;   // seq max
                4'd4:    digits_of = 4'd6;   // seq gt18
                4'd5:    digits_of = 4'd6;   // seq gt49
                4'd6:    digits_of = 4'd3;   // rnd min
                4'd7:    digits_of = 4'd4;   // rnd mean x10
                4'd8:    digits_of = 4'd3;   // rnd max
                4'd9:    digits_of = 4'd6;   // rnd gt18
                4'd10:   digits_of = 4'd6;   // rnd gt49
                default: digits_of = 4'd1;   // errors
            endcase
        end
    endfunction

    // The two mean fields print as NNN.N.
    function is_mean(input [3:0] f);
        begin is_mean = (f == 4'd2) || (f == 4'd7); end
    endfunction

    function [31:0] value_of(input [3:0] f);
        begin
            case (f)
                4'd0:    value_of = win_count;
                4'd1:    value_of = {16'd0, seq_min};
                4'd2:    value_of = seq_mean_x10;
                4'd3:    value_of = {16'd0, seq_max};
                4'd4:    value_of = seq_gt_gs;
                4'd5:    value_of = seq_gt_leg;
                4'd6:    value_of = {16'd0, rnd_min};
                4'd7:    value_of = rnd_mean_x10;
                4'd8:    value_of = {16'd0, rnd_max};
                4'd9:    value_of = rnd_gt_gs;
                4'd10:   value_of = rnd_gt_leg;
                default: value_of = err_count;
            endcase
        end
    endfunction

    // ---- binary to decimal -------------------------------------------------
    reg         b2b_start;
    reg  [31:0] b2b_bin;
    wire [31:0] b2b_bcd;
    wire        b2b_busy, b2b_done;

    bin_to_bcd u_b2b (
        .clk(clk), .rst(rst),
        .start(b2b_start), .bin(b2b_bin),
        .bcd(b2b_bcd), .busy(b2b_busy), .done(b2b_done)
    );

    reg [31:0] bcd [0:NFIELD-1];

    // ---- control -----------------------------------------------------------
    localparam [2:0] S_WAIT  = 3'd0,
                     S_CONV  = 3'd1,
                     S_CONVW = 3'd2,
                     S_TEXT  = 3'd3,
                     S_EMIT  = 3'd4,
                     S_DIGIT = 3'd5;

    reg [2:0]  state;
    reg [31:0] timer;
    reg [3:0]  fidx;         // field being converted
    reg [7:0]  ti;           // index into TEMPLATE
    reg [3:0]  cur_field;
    reg [3:0]  dleft;        // digits still to emit
    reg        dp_done;

    // Both part-selects are guarded: ti reaches LEN on the last byte and dleft
    // reaches 0 on the last digit, and an unguarded select there is out of range.
    // Only the guard's timing is affected - these are read solely in states where
    // the index is valid - but an out-of-range select is a synthesis warning
    // worth not having.
    wire [7:0] tmpl_ch   = (ti >= LEN8)   ? 8'h20 : TEMPLATE[(LEN8-8'd1-ti)*8 +: 8];
    wire [3:0] cur_digit = (dleft == 0)  ? 4'd0  : bcd[cur_field][(dleft-1)*4 +: 4];

    always @(posedge clk) begin
        if (rst) begin
            state     <= S_WAIT;
            timer     <= 32'd0;
            tx_valid  <= 1'b0;
            tx_data   <= 8'd0;
            b2b_start <= 1'b0;
            fidx      <= 4'd0;
            ti        <= 8'd0;
            cur_field <= 4'd0;
            dleft     <= 4'd0;
            dp_done   <= 1'b0;
        end else begin
            b2b_start <= 1'b0;

            case (state)

                S_WAIT: begin
                    tx_valid <= 1'b0;
                    if (!enable) begin
                        timer <= 32'd0;
                    end else if (timer >= REPORT_PERIOD - 1) begin
                        timer <= 32'd0;
                        fidx  <= 4'd0;
                        state <= S_CONV;
                    end else begin
                        timer <= timer + 1'b1;
                    end
                end

                // Convert all 12 values up front, so the text walk never has to
                // stop and wait for the converter.
                S_CONV: begin
                    b2b_bin   <= value_of(fidx);
                    b2b_start <= 1'b1;
                    state     <= S_CONVW;
                end

                S_CONVW: begin
                    if (b2b_done) begin
                        bcd[fidx] <= b2b_bcd;
                        if (fidx == NFIELD[3:0]-4'd1) begin
                            ti    <= 8'd0;
                            state <= S_TEXT;
                        end else begin
                            fidx  <= fidx + 1'b1;
                            state <= S_CONV;
                        end
                    end
                end

                S_TEXT: begin
                    if (ti >= LEN8) begin
                        state <= S_WAIT;
                    end else if (field_of(tmpl_ch) != NFIELD[3:0]) begin
                        cur_field <= field_of(tmpl_ch);
                        dleft     <= digits_of(field_of(tmpl_ch));
                        dp_done   <= 1'b0;
                        ti        <= ti + 1'b1;
                        state     <= S_DIGIT;
                    end else begin
                        tx_data  <= tmpl_ch;
                        tx_valid <= 1'b1;
                        ti       <= ti + 1'b1;
                        state    <= S_EMIT;
                    end
                end

                // Hold data/valid until the UART takes the byte.
                S_EMIT: begin
                    if (tx_ready && tx_valid) begin
                        tx_valid <= 1'b0;
                        state    <= (dleft != 0) ? S_DIGIT : S_TEXT;
                    end
                end

                S_DIGIT: begin
                    if (is_mean(cur_field) && dleft == 4'd1 && !dp_done) begin
                        tx_data  <= ".";
                        dp_done  <= 1'b1;
                    end else begin
                        tx_data <= 8'h30 + {4'd0, cur_digit};
                        dleft   <= dleft - 1'b1;
                    end
                    tx_valid <= 1'b1;
                    state    <= S_EMIT;
                end

                default: state <= S_WAIT;
            endcase
        end
    end

endmodule
