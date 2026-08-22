`timescale 1ns / 1ps
// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// uart_tx - 8N1 transmitter, ready/valid handshake.
//
// Feeds the Alchitry Au's on-board USB-serial bridge (usb_tx, pin P16), which
// enumerates on the host as an ordinary COM port / ttyUSB.  Nothing here is
// specific to this project.
//
// A byte is accepted on any cycle where tx_valid && tx_ready.  tx_ready falls for
// the duration of the frame (10 bit times) and rises again when idle.
//////////////////////////////////////////////////////////////////////////////////

module uart_tx #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] tx_data,
    input  wire       tx_valid,
    output wire       tx_ready,
    output reg        tx
);

    // Nearest-integer divisor.  At 100 MHz / 115200 this is 868, giving 115207
    // baud - 0.006 % error, which is nothing next to the 2 % a UART tolerates.
    localparam integer DIVISOR = (CLK_HZ + BAUD/2) / BAUD;
    /* verilator lint_off WIDTHTRUNC */
    // Deliberate truncation: DIVISOR-1 is an integer expression being narrowed
    // to the counter's width, which is exactly wide enough to hold it.
    localparam [$clog2(DIVISOR)-1:0] DIV_MAX = DIVISOR - 1;
    /* verilator lint_on WIDTHTRUNC */

    reg [$clog2(DIVISOR)-1:0] baud_cnt;
    reg [3:0]                 bit_idx;
    reg [9:0]                 shifter;   // {stop, data[7:0], start}
    reg                       busy;

    assign tx_ready = !busy;

    always @(posedge clk) begin
        if (rst) begin
            busy     <= 1'b0;
            tx       <= 1'b1;            // idle high
            baud_cnt <= 0;
            bit_idx  <= 4'd0;
            shifter  <= 10'h3FF;
        end else if (!busy) begin
            tx <= 1'b1;
            if (tx_valid) begin
                shifter  <= {1'b1, tx_data, 1'b0};
                busy     <= 1'b1;
                bit_idx  <= 4'd0;
                baud_cnt <= 0;
                tx       <= 1'b0;        // start bit begins now
            end
        end else if (baud_cnt == DIV_MAX) begin
            baud_cnt <= 0;
            if (bit_idx == 4'd9) begin
                busy <= 1'b0;
                tx   <= 1'b1;
            end else begin
                bit_idx <= bit_idx + 1'b1;
                tx      <= shifter[bit_idx + 1];
            end
        end else begin
            baud_cnt <= baud_cnt + 1'b1;
        end
    end

endmodule
