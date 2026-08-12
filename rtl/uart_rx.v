`timescale 1ns / 1ps
// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 jtflanagan
//////////////////////////////////////////////////////////////////////////////////
// uart_rx - 8N1 receiver, strobe output.  The counterpart to uart_tx.v.
//
// Exists so the host can reach the FPGA over the Alchitry Au's own USB-serial
// bridge, which is a path completely independent of the FT601.  That matters:
// it is the channel that still works when the FT601 is the thing that is stuck,
// and so it is the one a recovery command has to arrive on.
//
// rx_data is valid for exactly one cycle when rx_valid is high.  There is no
// ready handshake - a consumer that is not looking will miss the byte, which is
// fine for single-character commands.
//
// Mid-bit sampling: the start edge arms a counter, and each bit is sampled half
// a bit time later, so a slightly-off baud rate still lands inside the eye.
//////////////////////////////////////////////////////////////////////////////////

module uart_rx #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,          // asynchronous, from the pin
    output reg [7:0]  rx_data,
    output reg        rx_valid
);

    localparam integer DIVISOR  = (CLK_HZ + BAUD/2) / BAUD;
    localparam integer HALF_DIV = DIVISOR / 2;

    // Two-flop synchroniser: rx is asynchronous to clk and would otherwise be a
    // metastability source on every edge.
    reg [2:0] rx_sync = 3'b111;
    always @(posedge clk) rx_sync <= {rx_sync[1:0], rx};
    wire rx_s = rx_sync[2];

    localparam [1:0] IDLE = 2'd0, START = 2'd1, DATA = 2'd2, STOP = 2'd3;

    reg [1:0]  state    = IDLE;
    reg [15:0] cnt      = 16'd0;
    reg [2:0]  bit_idx  = 3'd0;
    reg [7:0]  shifter  = 8'd0;

    always @(posedge clk) begin
        rx_valid <= 1'b0;

        if (rst) begin
            state <= IDLE;
            cnt   <= 16'd0;
        end else begin
            case (state)
                IDLE: begin
                    // Falling edge = start bit.
                    if (!rx_s) begin
                        state <= START;
                        cnt   <= 16'd0;
                    end
                end

                START: begin
                    // Sample at the middle of the start bit.  If it is no longer
                    // low it was a glitch, so go back to idle rather than framing
                    // a byte out of noise.
                    if (cnt == HALF_DIV[15:0]) begin
                        cnt <= 16'd0;
                        if (!rx_s) begin
                            state   <= DATA;
                            bit_idx <= 3'd0;
                        end else begin
                            state <= IDLE;
                        end
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                DATA: begin
                    if (cnt == DIVISOR[15:0] - 16'd1) begin
                        cnt     <= 16'd0;
                        shifter <= {rx_s, shifter[7:1]};   // LSB first
                        if (bit_idx == 3'd7) state <= STOP;
                        else                 bit_idx <= bit_idx + 3'd1;
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                STOP: begin
                    if (cnt == DIVISOR[15:0] - 16'd1) begin
                        cnt   <= 16'd0;
                        state <= IDLE;
                        // Only accept the byte if the stop bit is really there;
                        // a framing error usually means the baud rate is wrong
                        // and the "byte" is meaningless.
                        if (rx_s) begin
                            rx_data  <= shifter;
                            rx_valid <= 1'b1;
                        end
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
